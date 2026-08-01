//! The TermWire runtime: a single-threaded poll loop that owns every
//! session PTY, the control socket, and the per-session data sockets.
//!
//! Control plane: newline-delimited JSON (see protocol.Request/Response).
//! Data plane: framed both ways — client sends data/resize, daemon
//! sends one snapshot on attach (VT reconstruction of the session's
//! canonical screen, maintained by ghostty-vt) followed by output.
//!
//! Known simplifications at this stage (deliberate, revisit later):
//! - A slow/stuck data client can block the loop on send(); no
//!   backpressure handling yet.
//! - No single-instance lock; a second daemon stomps the first's
//!   control socket.
//! - Snapshots cover the screen, not scrollback history; that comes
//!   with runtime-owned scrollback.

const Daemon = @This();

const std = @import("std");
const posix = std.posix;
const c = std.c;
const protocol = @import("protocol");
const ghostty = @import("ghostty-vt");
const Pty = @import("Pty.zig");
const vt_mod = @import("vt.zig");

const log = std.log.scoped(.daemon);

const max_line = 8192;

const Conn = struct {
    fd: posix.fd_t,
    buf: [max_line]u8 = undefined,
    len: usize = 0,
};

const Client = struct {
    fd: posix.fd_t,
    buf: [protocol.max_frame_payload + protocol.frame_header_len]u8 = undefined,
    len: usize = 0,
};

extern "c" fn time(tloc: ?*i64) i64;

/// Canonical VT state for a session: PTY output flows through the
/// stream into the terminal, which is what snapshots are taken from.
/// Heap-allocated because the stream handler holds a pointer to the
/// terminal — Session structs move when the sessions list reallocates.
const Vt = struct {
    term: ghostty.Terminal,
    stream: ghostty.TerminalStream,
};

const Session = struct {
    id: u32,
    pty: Pty,
    cols: u16,
    rows: u16,
    created_unix: i64 = 0,
    vt: *Vt,
    data_listen_fd: posix.fd_t,
    sock_path_buf: [108]u8 = undefined,
    sock_path_len: usize = 0,
    clients: std.ArrayList(Client) = .empty,

    fn sockPath(self: *const Session) []const u8 {
        return self.sock_path_buf[0..self.sock_path_len];
    }
};

var stop_flag: std.atomic.Value(bool) = .init(false);

fn handleStop(_: posix.SIG) callconv(.c) void {
    stop_flag.store(true, .monotonic);
}

alloc: std.mem.Allocator,
io: std.Io,
control_fd: posix.fd_t = -1,
control_path_buf: [108]u8 = undefined,
control_path_len: usize = 0,
sessions: std.ArrayList(Session) = .empty,
conns: std.ArrayList(Conn) = .empty,
next_id: u32 = 1,

pub fn run(alloc: std.mem.Allocator, io: std.Io) !void {
    var self: Daemon = .{ .alloc = alloc, .io = io };
    defer self.deinit();

    try self.bindControlSocket();

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

    log.info("listening on {s}", .{self.control_path_buf[0..self.control_path_len]});

    var pollfds: std.ArrayList(posix.pollfd) = .empty;
    defer pollfds.deinit(alloc);

    while (!stop_flag.load(.monotonic)) {
        self.reapSessions();

        // Rebuild the poll set: control listener, control conns, then
        // per session: master, data listener, data clients.
        pollfds.clearRetainingCapacity();
        try pollfds.append(alloc, .{ .fd = self.control_fd, .events = posix.POLL.IN, .revents = 0 });
        for (self.conns.items) |conn|
            try pollfds.append(alloc, .{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 });
        for (self.sessions.items) |*sess| {
            try pollfds.append(alloc, .{ .fd = sess.pty.master, .events = posix.POLL.IN, .revents = 0 });
            try pollfds.append(alloc, .{ .fd = sess.data_listen_fd, .events = posix.POLL.IN, .revents = 0 });
            for (sess.clients.items) |client|
                try pollfds.append(alloc, .{ .fd = client.fd, .events = posix.POLL.IN, .revents = 0 });
        }

        _ = posix.poll(pollfds.items, 200) catch |err| switch (err) {
            else => return err,
        };

        // Objects may be destroyed while handling earlier events in the
        // same pass, so resolve each fd fresh and skip ones that are gone.
        for (pollfds.items) |pfd| {
            if (pfd.revents == 0) continue;
            if (pfd.fd == self.control_fd) {
                self.acceptControl();
            } else if (self.findConn(pfd.fd)) |idx| {
                self.serviceConn(idx, pfd.revents);
            } else if (self.findSessionByMaster(pfd.fd)) |idx| {
                self.serviceMaster(idx, pfd.revents);
            } else if (self.findSessionByDataListener(pfd.fd)) |idx| {
                self.acceptDataClient(idx);
            } else if (self.findSessionClient(pfd.fd)) |loc| {
                self.serviceDataClient(loc.session, loc.client, pfd.revents);
            }
        }
    }

    log.info("shutting down", .{});
}

fn deinit(self: *Daemon) void {
    while (self.sessions.items.len > 0)
        self.destroySession(self.sessions.items.len - 1);
    self.sessions.deinit(self.alloc);
    for (self.conns.items) |conn| _ = c.close(conn.fd);
    self.conns.deinit(self.alloc);
    if (self.control_fd >= 0) {
        _ = c.close(self.control_fd);
        self.control_path_buf[self.control_path_len] = 0;
        _ = c.unlink(@ptrCast(self.control_path_buf[0..self.control_path_len :0]));
    }
}

fn bindControlSocket(self: *Daemon) !void {
    // Ensure the runtime dir exists, private to the user.
    var dir_buf: [96]u8 = undefined;
    const dir = try protocol.runtimeDir(&dir_buf);
    dir_buf[dir.len] = 0;
    _ = c.mkdir(dir_buf[0..dir.len :0], 0o700);

    const path = try protocol.controlSocketPath(&self.control_path_buf);
    self.control_path_len = path.len;
    self.control_fd = try bindListen(&self.control_path_buf, path.len);
}

/// NUL-terminate path in buf, unlink any stale socket, bind and listen.
fn bindListen(buf: *[108]u8, len: usize) !posix.fd_t {
    if (len >= 107) return error.PathTooLong;
    buf[len] = 0;
    const path_z: [:0]const u8 = buf[0..len :0];
    _ = c.unlink(path_z);

    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..len], buf[0..len]);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) < 0)
        return error.BindFailed;
    if (c.listen(fd, 8) < 0) return error.ListenFailed;
    return fd;
}

fn sendAll(fd: posix.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.send(fd, bytes[off..].ptr, bytes.len - off, posix.MSG.NOSIGNAL);
        if (n < 0) return false;
        off += @intCast(n);
    }
    return true;
}

// -- Control plane ---------------------------------------------------

fn acceptControl(self: *Daemon) void {
    const fd = c.accept4(self.control_fd, null, null, posix.SOCK.CLOEXEC);
    if (fd < 0) return;
    self.conns.append(self.alloc, .{ .fd = fd }) catch {
        _ = c.close(fd);
        return;
    };
}

fn findConn(self: *Daemon, fd: posix.fd_t) ?usize {
    for (self.conns.items, 0..) |conn, i|
        if (conn.fd == fd) return i;
    return null;
}

fn closeConn(self: *Daemon, idx: usize) void {
    _ = c.close(self.conns.items[idx].fd);
    _ = self.conns.swapRemove(idx);
}

fn serviceConn(self: *Daemon, idx: usize, revents: i16) void {
    if (revents & (posix.POLL.HUP | posix.POLL.ERR) != 0 and
        revents & posix.POLL.IN == 0)
    {
        self.closeConn(idx);
        return;
    }

    const conn = &self.conns.items[idx];
    const n = posix.read(conn.fd, conn.buf[conn.len..]) catch 0;
    if (n == 0) {
        self.closeConn(idx);
        return;
    }
    conn.len += n;

    // Handle every complete line in the buffer. The conn pointer stays
    // valid: handleRequest may mutate sessions but never self.conns.
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, conn.buf[0..conn.len], start, '\n')) |nl| {
        const line = std.mem.trim(u8, conn.buf[start..nl], " \r");
        if (line.len > 0) self.handleRequest(conn.fd, line);
        start = nl + 1;
    }
    std.mem.copyForwards(u8, &conn.buf, conn.buf[start..conn.len]);
    conn.len -= start;

    if (conn.len == max_line) {
        // Oversized line with no newline: protocol violation.
        self.closeConn(idx);
    }
}

fn respond(self: *Daemon, fd: posix.fd_t, resp: protocol.Response) void {
    const json = std.json.Stringify.valueAlloc(self.alloc, resp, .{
        .emit_null_optional_fields = false,
    }) catch return;
    defer self.alloc.free(json);
    _ = sendAll(fd, json);
    _ = sendAll(fd, "\n");
}

fn handleRequest(self: *Daemon, fd: posix.fd_t, line: []const u8) void {
    const req = std.json.parseFromSliceLeaky(protocol.Request, self.alloc, line, .{}) catch {
        self.respond(fd, .{ .ok = false, .msg = "malformed request" });
        return;
    };

    switch (req.op) {
        .create_session => {
            const info = self.createSession(req.cols, req.rows) catch |err| {
                log.warn("create_session failed: {t}", .{err});
                self.respond(fd, .{ .ok = false, .msg = "create failed" });
                return;
            };
            self.respond(fd, .{ .ok = true, .session = info });
        },
        .list_sessions => {
            const infos = self.alloc.alloc(protocol.SessionInfo, self.sessions.items.len) catch return;
            defer self.alloc.free(infos);
            for (self.sessions.items, infos) |*sess, *info| info.* = sessionInfo(sess);
            self.respond(fd, .{ .ok = true, .sessions = infos });
        },
        .kill_session => {
            const id = req.id orelse {
                self.respond(fd, .{ .ok = false, .msg = "kill_session requires id" });
                return;
            };
            const idx = self.findSessionById(id) orelse {
                self.respond(fd, .{ .ok = false, .msg = "no such session" });
                return;
            };
            const pid = self.sessions.items[idx].pty.pid;
            if (pid > 0) _ = c.kill(pid, .HUP);
            self.respond(fd, .{ .ok = true });
        },
    }
}

// -- Sessions --------------------------------------------------------

fn sessionInfo(sess: *const Session) protocol.SessionInfo {
    return .{
        .id = sess.id,
        .pid = sess.pty.pid,
        .cols = sess.cols,
        .rows = sess.rows,
        .created_unix = sess.created_unix,
        .socket_path = sess.sockPath(),
    };
}

fn findSessionById(self: *Daemon, id: u32) ?usize {
    for (self.sessions.items, 0..) |*sess, i|
        if (sess.id == id) return i;
    return null;
}

fn findSessionByMaster(self: *Daemon, fd: posix.fd_t) ?usize {
    for (self.sessions.items, 0..) |*sess, i|
        if (sess.pty.master == fd) return i;
    return null;
}

fn findSessionByDataListener(self: *Daemon, fd: posix.fd_t) ?usize {
    for (self.sessions.items, 0..) |*sess, i|
        if (sess.data_listen_fd == fd) return i;
    return null;
}

const ClientLoc = struct { session: usize, client: usize };

fn findSessionClient(self: *Daemon, fd: posix.fd_t) ?ClientLoc {
    for (self.sessions.items, 0..) |*sess, si|
        for (sess.clients.items, 0..) |client, ci|
            if (client.fd == fd) return .{ .session = si, .client = ci };
    return null;
}

fn createSession(self: *Daemon, cols_req: u16, rows_req: u16) !protocol.SessionInfo {
    const id = self.next_id;
    const cols = if (cols_req == 0) 80 else cols_req;
    const rows = if (rows_req == 0) 24 else rows_req;

    const vt = try self.alloc.create(Vt);
    errdefer self.alloc.destroy(vt);
    vt.term = try ghostty.Terminal.init(self.io, self.alloc, .{
        .cols = cols,
        .rows = rows,
    });
    errdefer vt.term.deinit(self.alloc);
    vt.stream = .initAlloc(self.alloc, .init(&vt.term));
    errdefer vt.stream.deinit();

    var sess: Session = .{
        .id = id,
        .cols = cols,
        .rows = rows,
        .created_unix = time(null),
        .pty = undefined,
        .data_listen_fd = -1,
        .vt = vt,
    };

    const path = try protocol.sessionSocketPath(&sess.sock_path_buf, id);
    sess.sock_path_len = path.len;
    sess.data_listen_fd = try bindListen(&sess.sock_path_buf, path.len);
    errdefer {
        _ = c.close(sess.data_listen_fd);
        _ = c.unlink(sess.sock_path_buf[0..sess.sock_path_len :0]);
    }

    sess.pty = try Pty.open(.{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 });
    errdefer sess.pty.deinit();

    const shell: [*:0]const u8 = c.getenv("SHELL") orelse "/bin/sh";
    const argv = [_:null]?[*:0]const u8{shell};
    try sess.pty.spawn(&argv);

    try self.sessions.append(self.alloc, sess);
    self.next_id += 1;
    log.info("session {d} created (pid={d}, {d}x{d})", .{ id, sess.pty.pid, cols, rows });
    return sessionInfo(&self.sessions.items[self.sessions.items.len - 1]);
}

fn destroySession(self: *Daemon, idx: usize) void {
    var sess = &self.sessions.items[idx];
    log.info("session {d} destroyed", .{sess.id});
    for (sess.clients.items) |client| _ = c.close(client.fd);
    sess.clients.deinit(self.alloc);
    _ = c.close(sess.data_listen_fd);
    sess.sock_path_buf[sess.sock_path_len] = 0;
    _ = c.unlink(sess.sock_path_buf[0..sess.sock_path_len :0]);
    if (sess.pty.pid > 0) {
        _ = c.kill(sess.pty.pid, .KILL);
        _ = sess.pty.wait(true);
    }
    sess.pty.deinit();
    sess.vt.stream.deinit();
    sess.vt.term.deinit(self.alloc);
    self.alloc.destroy(sess.vt);
    _ = self.sessions.swapRemove(idx);
}

fn reapSessions(self: *Daemon) void {
    var i: usize = self.sessions.items.len;
    while (i > 0) {
        i -= 1;
        const sess = &self.sessions.items[i];
        if (sess.pty.wait(false)) |status| {
            log.info("session {d} shell exited status={d}", .{ sess.id, status });
            self.destroySession(i);
        }
    }
}

// -- Data plane ------------------------------------------------------

fn sendFrame(fd: posix.fd_t, frame_type: protocol.FrameType, payload: []const u8) bool {
    var header: [protocol.frame_header_len]u8 = undefined;
    protocol.writeFrameHeader(&header, frame_type, @intCast(payload.len));
    if (!sendAll(fd, &header)) return false;
    return sendAll(fd, payload);
}

fn acceptDataClient(self: *Daemon, idx: usize) void {
    const sess = &self.sessions.items[idx];
    const fd = c.accept4(sess.data_listen_fd, null, null, posix.SOCK.CLOEXEC);
    if (fd < 0) return;
    sess.clients.append(self.alloc, .{ .fd = fd }) catch {
        _ = c.close(fd);
        return;
    };

    // Bring the new client current with one snapshot frame. The loop
    // is single-threaded, so this is atomic with respect to output:
    // everything after this point reaches the client as output frames.
    var out: std.Io.Writer.Allocating = .init(self.alloc);
    defer out.deinit();
    if (vt_mod.writeSnapshot(&sess.vt.term, &out.writer)) {
        _ = sendFrame(fd, .snapshot, out.writer.buffered());
    } else |err| {
        log.warn("session {d}: snapshot failed: {t}", .{ sess.id, err });
    }
    log.info("session {d}: client attached", .{sess.id});
}

fn dropDataClient(self: *Daemon, sidx: usize, cidx: usize) void {
    const sess = &self.sessions.items[sidx];
    _ = c.close(sess.clients.items[cidx].fd);
    _ = sess.clients.swapRemove(cidx);
    log.info("session {d}: client detached", .{sess.id});
}

/// PTY produced output: apply it to the session's canonical terminal
/// state, then broadcast it to attached clients as output frames.
fn serviceMaster(self: *Daemon, idx: usize, revents: i16) void {
    var buf: [4096]u8 = undefined;
    if (revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
        const n = posix.read(self.sessions.items[idx].pty.master, &buf) catch 0;
        if (n == 0) {
            // EOF/EIO: shell side gone; reap next pass (or destroy now).
            self.destroySession(idx);
            return;
        }
        const sess = &self.sessions.items[idx];
        sess.vt.stream.nextSlice(buf[0..n]);
        var ci: usize = sess.clients.items.len;
        while (ci > 0) {
            ci -= 1;
            if (!sendFrame(sess.clients.items[ci].fd, .output, buf[0..n]))
                self.dropDataClient(idx, ci);
        }
    }
}

/// Client sent framed input: data to the PTY, or a resize.
fn serviceDataClient(self: *Daemon, sidx: usize, cidx: usize, revents: i16) void {
    if (revents & (posix.POLL.HUP | posix.POLL.ERR) != 0 and
        revents & posix.POLL.IN == 0)
    {
        self.dropDataClient(sidx, cidx);
        return;
    }

    const client = &self.sessions.items[sidx].clients.items[cidx];
    const n = posix.read(client.fd, client.buf[client.len..]) catch 0;
    if (n == 0) {
        self.dropDataClient(sidx, cidx);
        return;
    }
    client.len += n;

    var start: usize = 0;
    while (client.len - start >= protocol.frame_header_len) {
        const header = client.buf[start..][0..protocol.frame_header_len];
        const payload_len = std.mem.readInt(u32, header[1..5], .little);
        if (payload_len > protocol.max_frame_payload) {
            self.dropDataClient(sidx, cidx);
            return;
        }
        const total = protocol.frame_header_len + payload_len;
        if (client.len - start < total) break;
        const payload = client.buf[start + protocol.frame_header_len ..][0..payload_len];

        switch (header[0]) {
            @intFromEnum(protocol.FrameType.data) => {
                const master = self.sessions.items[sidx].pty.master;
                var off: usize = 0;
                while (off < payload.len) {
                    const w = c.write(master, payload[off..].ptr, payload.len - off);
                    if (w < 0) break;
                    off += @intCast(w);
                }
            },
            @intFromEnum(protocol.FrameType.resize) => {
                if (payload_len == 4) {
                    const sess = &self.sessions.items[sidx];
                    sess.cols = std.mem.readInt(u16, payload[0..2], .little);
                    sess.rows = std.mem.readInt(u16, payload[2..4], .little);
                    sess.pty.setSize(.{
                        .row = sess.rows,
                        .col = sess.cols,
                        .xpixel = 0,
                        .ypixel = 0,
                    }) catch {};
                    sess.vt.term.resize(self.alloc, .{
                        .cols = sess.cols,
                        .rows = sess.rows,
                    }) catch |err| {
                        log.warn("session {d}: vt resize failed: {t}", .{ sess.id, err });
                    };
                }
            },
            else => {
                self.dropDataClient(sidx, cidx);
                return;
            },
        }
        start += total;
    }
    std.mem.copyForwards(u8, &client.buf, client.buf[start..client.len]);
    client.len -= start;
}
