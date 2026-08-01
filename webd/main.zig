//! termwire-webd — the web bridge.
//!
//! A deliberately separate process from the daemon: it serves the
//! built web client (static files) and bridges WebSockets to the
//! daemon's Unix sockets. The daemon never learns HTTP; the browser
//! never learns Unix sockets.
//!
//!   GET  /...              static files from --root (default web/dist)
//!   WS   /ws/control       text frames <-> JSON lines on control.sock
//!   WS   /ws/session/{id}  binary frames <-> the session's data socket
//!
//! Session WS semantics (protocol knowledge lives here, not in JS):
//!   browser -> webd: binary message  = raw keyboard bytes
//!                    text message    = {"resize":{"cols":N,"rows":N}}
//!   webd -> browser: binary message  = raw PTY output
//!
//! Binds 127.0.0.1 only. There is no authentication yet; do not point
//! this at anything but localhost.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const protocol = @import("protocol");

const log = std.log.scoped(.webd);

pub const std_options: std.Options = .{ .logFn = protocol.logging.logFn };

const default_port: u16 = 7181;
const max_http_request = 16 * 1024;
const max_ws_message = 1024 * 1024;
const ws_magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleStop(_: posix.SIG) callconv(.c) void {
    stop_flag.store(true, .monotonic);
}

const Kind = enum { http, ws_control, ws_session };

const Conn = struct {
    fd: posix.fd_t,
    kind: Kind = .http,
    /// Bytes read from the browser, not yet consumed.
    rbuf: std.ArrayList(u8) = .empty,
    /// Reassembly buffer for fragmented WS messages.
    frag: std.ArrayList(u8) = .empty,
    frag_opcode: u8 = 0,
    /// Connected Unix socket to the daemon (WS states only).
    unix_fd: posix.fd_t = -1,
    /// Line buffer for control-plane output.
    line: std.ArrayList(u8) = .empty,

    fn deinit(self: *Conn, alloc: std.mem.Allocator) void {
        _ = c.close(self.fd);
        if (self.unix_fd >= 0) _ = c.close(self.unix_fd);
        self.rbuf.deinit(alloc);
        self.frag.deinit(alloc);
        self.line.deinit(alloc);
    }
};

const Server = struct {
    alloc: std.mem.Allocator,
    listen_fd: posix.fd_t,
    root: []const u8,
    conns: std.ArrayList(Conn) = .empty,

    fn findConn(self: *Server, fd: posix.fd_t) ?usize {
        for (self.conns.items, 0..) |*conn, i|
            if (conn.fd == fd) return i;
        return null;
    }

    fn findConnByUnix(self: *Server, fd: posix.fd_t) ?usize {
        for (self.conns.items, 0..) |*conn, i|
            if (conn.unix_fd == fd) return i;
        return null;
    }

    fn closeConn(self: *Server, idx: usize) void {
        self.conns.items[idx].deinit(self.alloc);
        _ = self.conns.swapRemove(idx);
    }
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var port: u16 = default_port;
    var root: []const u8 = "web/dist";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.debug.print("bad port: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            i += 1;
            root = args[i];
        } else {
            std.debug.print(
                "usage: termwire-webd [--port {d}] [--root web/dist]\n",
                .{default_port},
            );
            std.process.exit(1);
        }
    }

    posix.sigaction(.INT, &.{
        .handler = .{ .handler = handleStop },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);
    posix.sigaction(.TERM, &.{
        .handler = .{ .handler = handleStop },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    const listen_fd = try listenTcpLocalhost(port);
    defer _ = c.close(listen_fd);

    var self: Server = .{ .alloc = alloc, .listen_fd = listen_fd, .root = root };
    defer {
        while (self.conns.items.len > 0) self.closeConn(self.conns.items.len - 1);
        self.conns.deinit(alloc);
    }

    log.info("serving {s} on http://127.0.0.1:{d}", .{ root, port });

    var pollfds: std.ArrayList(posix.pollfd) = .empty;
    defer pollfds.deinit(alloc);

    while (!stop_flag.load(.monotonic)) {
        pollfds.clearRetainingCapacity();
        try pollfds.append(alloc, .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 });
        for (self.conns.items) |*conn| {
            try pollfds.append(alloc, .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 });
            if (conn.unix_fd >= 0)
                try pollfds.append(alloc, .{ .fd = conn.unix_fd, .events = posix.POLL.IN, .revents = 0 });
        }

        _ = posix.poll(pollfds.items, 500) catch continue;

        for (pollfds.items) |pfd| {
            if (pfd.revents == 0) continue;
            if (pfd.fd == listen_fd) {
                acceptConn(&self);
            } else if (self.findConn(pfd.fd)) |idx| {
                serviceConn(&self, idx);
            } else if (self.findConnByUnix(pfd.fd)) |idx| {
                serviceUnix(&self, idx);
            }
        }
    }

    log.info("shutting down", .{});
}

fn listenTcpLocalhost(port: u16) !posix.fd_t {
    const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    const one: c_int = 1;
    _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &one, @sizeOf(c_int));

    const addr: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) < 0)
        return error.BindFailed;
    if (c.listen(fd, 16) < 0) return error.ListenFailed;
    return fd;
}

fn acceptConn(self: *Server) void {
    const fd = c.accept4(self.listen_fd, null, null, posix.SOCK.CLOEXEC);
    if (fd < 0) return;
    self.conns.append(self.alloc, .{ .fd = fd }) catch {
        _ = c.close(fd);
    };
}

fn serviceConn(self: *Server, idx: usize) void {
    const conn = &self.conns.items[idx];
    var buf: [8192]u8 = undefined;
    const n = posix.read(conn.fd, &buf) catch 0;
    if (n == 0) {
        self.closeConn(idx);
        return;
    }
    conn.rbuf.appendSlice(self.alloc, buf[0..n]) catch {
        self.closeConn(idx);
        return;
    };

    const ok = switch (conn.kind) {
        .http => handleHttp(self, idx),
        .ws_control, .ws_session => handleWs(self, idx),
    };
    if (!ok) self.closeConn(idx);
}

// -- HTTP ------------------------------------------------------------

/// Returns false if the connection should be closed.
fn handleHttp(self: *Server, idx: usize) bool {
    const conn = &self.conns.items[idx];
    const head_end = std.mem.indexOf(u8, conn.rbuf.items, "\r\n\r\n") orelse {
        return conn.rbuf.items.len <= max_http_request;
    };
    const head = conn.rbuf.items[0..head_end];

    // Request line: METHOD SP target SP version
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return false;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return false;
    const target = parts.next() orelse return false;

    var ws_key: ?[]const u8 = null;
    var is_upgrade = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "upgrade") and
            std.ascii.indexOfIgnoreCase(value, "websocket") != null)
        {
            is_upgrade = true;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            ws_key = value;
        }
    }

    if (!std.mem.eql(u8, method, "GET")) {
        respondStatus(conn.fd, "405 Method Not Allowed");
        return false;
    }

    if (is_upgrade) {
        const key = ws_key orelse {
            respondStatus(conn.fd, "400 Bad Request");
            return false;
        };
        return upgradeWs(self, idx, target, key, head_end + 4);
    }

    serveStatic(self, conn.fd, target);
    return false; // Connection: close after each static response.
}

fn respondStatus(fd: posix.fd_t, comptime status: []const u8) void {
    _ = protocol.sendAll(fd, "HTTP/1.1 " ++ status ++
        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
}

fn upgradeWs(self: *Server, idx: usize, target: []const u8, key: []const u8, consumed: usize) bool {
    const conn = &self.conns.items[idx];

    // Resolve the target before answering the handshake.
    var path_buf: [108]u8 = undefined;
    var kind: Kind = undefined;
    var unix_path: []const u8 = undefined;
    if (std.mem.eql(u8, target, "/ws/control")) {
        kind = .ws_control;
        unix_path = protocol.controlSocketPath(&path_buf) catch return false;
    } else if (std.mem.startsWith(u8, target, "/ws/session/")) {
        const id = std.fmt.parseInt(u32, target["/ws/session/".len..], 10) catch {
            respondStatus(conn.fd, "404 Not Found");
            return false;
        };
        kind = .ws_session;
        unix_path = protocol.sessionSocketPath(&path_buf, id) catch return false;
    } else {
        respondStatus(conn.fd, "404 Not Found");
        return false;
    }

    const unix_fd = protocol.connectUnix(unix_path) catch {
        respondStatus(conn.fd, "502 Bad Gateway");
        return false;
    };

    // Sec-WebSocket-Accept = base64(sha1(key ++ magic))
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(ws_magic);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var accept_buf: [32]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var resp_buf: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch unreachable;
    if (!protocol.sendAll(conn.fd, resp)) {
        _ = c.close(unix_fd);
        return false;
    }

    conn.kind = kind;
    conn.unix_fd = unix_fd;
    // Log before compacting rbuf: `target` is a slice into it.
    log.info("ws {s} open ({s})", .{ target, @tagName(kind) });
    std.mem.copyForwards(u8, conn.rbuf.items, conn.rbuf.items[consumed..]);
    conn.rbuf.shrinkRetainingCapacity(conn.rbuf.items.len - consumed);

    // Bytes after the handshake may already contain frames.
    return handleWs(self, idx);
}

// -- Static files ----------------------------------------------------

const ContentType = struct { ext: []const u8, mime: []const u8 };
const content_types = [_]ContentType{
    .{ .ext = ".html", .mime = "text/html; charset=utf-8" },
    .{ .ext = ".js", .mime = "text/javascript" },
    .{ .ext = ".css", .mime = "text/css" },
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".svg", .mime = "image/svg+xml" },
    .{ .ext = ".ico", .mime = "image/x-icon" },
    .{ .ext = ".json", .mime = "application/json" },
    .{ .ext = ".map", .mime = "application/json" },
    .{ .ext = ".woff2", .mime = "font/woff2" },
    .{ .ext = ".woff", .mime = "font/woff" },
    .{ .ext = ".ttf", .mime = "font/ttf" },
};

fn serveStatic(self: *Server, fd: posix.fd_t, target_raw: []const u8) void {
    // Strip query string; map SPA routes (no extension) to index.html.
    var target = target_raw;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| target = target[0..q];
    if (std.mem.eql(u8, target, "/")) target = "/index.html";
    if (std.mem.indexOfScalar(u8, std.fs.path.basename(target), '.') == null)
        target = "/index.html";

    // Refuse path traversal.
    if (std.mem.indexOf(u8, target, "..") != null) {
        respondStatus(fd, "404 Not Found");
        return;
    }

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}{s}", .{ self.root, target }) catch {
        respondStatus(fd, "404 Not Found");
        return;
    };

    const file_fd = c.open(path, .{}); // O_RDONLY
    if (file_fd < 0) {
        respondStatus(fd, "404 Not Found");
        return;
    }
    defer _ = c.close(file_fd);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(self.alloc);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = posix.read(file_fd, &buf) catch break;
        if (n == 0) break;
        body.appendSlice(self.alloc, buf[0..n]) catch {
            respondStatus(fd, "500 Internal Server Error");
            return;
        };
    }

    var mime: []const u8 = "application/octet-stream";
    for (content_types) |ct| {
        if (std.mem.endsWith(u8, path, ct.ext)) {
            mime = ct.mime;
            break;
        }
    }

    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: {s}\r\nContent-Length: {d}\r\n" ++
        "Cache-Control: no-cache\r\nConnection: close\r\n\r\n", .{ mime, body.items.len }) catch return;
    if (protocol.sendAll(fd, head)) _ = protocol.sendAll(fd, body.items);
}

// -- WebSocket -------------------------------------------------------

fn sendWsFrame(fd: posix.fd_t, opcode: u8, payload: []const u8) bool {
    var header: [10]u8 = undefined;
    var header_len: usize = 2;
    header[0] = 0x80 | opcode; // FIN + opcode
    if (payload.len < 126) {
        header[1] = @intCast(payload.len);
    } else if (payload.len < 65536) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }
    if (!protocol.sendAll(fd, header[0..header_len])) return false;
    return protocol.sendAll(fd, payload);
}

/// Consume complete frames from conn.rbuf. Returns false to close.
fn handleWs(self: *Server, idx: usize) bool {
    const conn = &self.conns.items[idx];
    while (true) {
        const buf = conn.rbuf.items;
        if (buf.len < 2) break;

        const fin = buf[0] & 0x80 != 0;
        const opcode = buf[0] & 0x0F;
        const masked = buf[1] & 0x80 != 0;
        if (!masked) return false; // clients MUST mask (RFC 6455)

        var payload_len: u64 = buf[1] & 0x7F;
        var offset: usize = 2;
        if (payload_len == 126) {
            if (buf.len < 4) break;
            payload_len = std.mem.readInt(u16, buf[2..4], .big);
            offset = 4;
        } else if (payload_len == 127) {
            if (buf.len < 10) break;
            payload_len = std.mem.readInt(u64, buf[2..10], .big);
            offset = 10;
        }
        if (payload_len > max_ws_message) return false;

        const total = offset + 4 + payload_len;
        if (buf.len < total) break;

        const mask_key = buf[offset..][0..4];
        const payload = buf[offset + 4 ..][0..@intCast(payload_len)];
        for (payload, 0..) |*b, pi| b.* ^= mask_key[pi % 4];

        var keep_going = true;
        switch (opcode) {
            0x0, 0x1, 0x2 => {
                if (opcode != 0x0) conn.frag_opcode = opcode;
                if (fin and conn.frag.items.len == 0) {
                    keep_going = dispatchWsMessage(conn, conn.frag_opcode, payload);
                } else {
                    conn.frag.appendSlice(self.alloc, payload) catch return false;
                    if (conn.frag.items.len > max_ws_message) return false;
                    if (fin) {
                        keep_going = dispatchWsMessage(conn, conn.frag_opcode, conn.frag.items);
                        conn.frag.clearRetainingCapacity();
                    }
                }
            },
            0x8 => { // close
                _ = sendWsFrame(conn.fd, 0x8, payload);
                return false;
            },
            0x9 => { // ping -> pong
                keep_going = sendWsFrame(conn.fd, 0xA, payload);
            },
            0xA => {}, // pong
            else => return false,
        }

        std.mem.copyForwards(u8, conn.rbuf.items, conn.rbuf.items[total..]);
        conn.rbuf.shrinkRetainingCapacity(conn.rbuf.items.len - total);
        if (!keep_going) return false;
    }
    return true;
}

fn dispatchWsMessage(conn: *Conn, opcode: u8, payload: []const u8) bool {
    switch (conn.kind) {
        .ws_control => {
            // One JSON request per text message; forward as one line.
            if (opcode != 0x1) return true;
            if (!protocol.sendAll(conn.unix_fd, payload)) return false;
            return protocol.sendAll(conn.unix_fd, "\n");
        },
        .ws_session => switch (opcode) {
            0x2 => { // raw input bytes -> framed data
                var header: [protocol.frame_header_len]u8 = undefined;
                var off: usize = 0;
                while (off < payload.len) {
                    const chunk = @min(payload.len - off, protocol.max_frame_payload);
                    protocol.writeFrameHeader(&header, .data, @intCast(chunk));
                    if (!protocol.sendAll(conn.unix_fd, &header)) return false;
                    if (!protocol.sendAll(conn.unix_fd, payload[off..][0..chunk])) return false;
                    off += chunk;
                }
                return true;
            },
            0x1 => { // {"resize":{"cols":N,"rows":N}}
                const Resize = struct { resize: struct { cols: u16, rows: u16 } };
                var scratch: [256]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&scratch);
                const parsed = std.json.parseFromSliceLeaky(
                    Resize,
                    fba.allocator(),
                    payload,
                    .{},
                ) catch return true; // ignore malformed control text
                var msg: [protocol.frame_header_len + 4]u8 = undefined;
                protocol.writeFrameHeader(msg[0..protocol.frame_header_len], .resize, 4);
                std.mem.writeInt(u16, msg[5..7], parsed.resize.cols, .little);
                std.mem.writeInt(u16, msg[7..9], parsed.resize.rows, .little);
                return protocol.sendAll(conn.unix_fd, &msg);
            },
            else => return true,
        },
        .http => return false,
    }
}

// -- Unix side -------------------------------------------------------

fn serviceUnix(self: *Server, idx: usize) void {
    const conn = &self.conns.items[idx];
    var buf: [8192]u8 = undefined;
    const n = posix.read(conn.unix_fd, &buf) catch 0;
    if (n == 0) {
        // Daemon side closed (session ended / daemon gone).
        _ = sendWsFrame(conn.fd, 0x8, &.{ 0x03, 0xE8 }); // 1000 normal
        self.closeConn(idx);
        return;
    }

    switch (conn.kind) {
        .ws_session => {
            if (!sendWsFrame(conn.fd, 0x2, buf[0..n])) self.closeConn(idx);
        },
        .ws_control => {
            // Split into lines; one text frame per response line.
            conn.line.appendSlice(self.alloc, buf[0..n]) catch {
                self.closeConn(idx);
                return;
            };
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, conn.line.items, start, '\n')) |nl| {
                if (!sendWsFrame(conn.fd, 0x1, conn.line.items[start..nl])) {
                    self.closeConn(idx);
                    return;
                }
                start = nl + 1;
            }
            std.mem.copyForwards(u8, conn.line.items, conn.line.items[start..]);
            conn.line.shrinkRetainingCapacity(conn.line.items.len - start);
        },
        .http => self.closeConn(idx),
    }
}
