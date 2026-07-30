//! tw — the TermWire CLI client.
//!
//! Talks JSON to the daemon's control socket for management and speaks
//! the framed data-plane protocol to attach the current terminal to a
//! session. Detach with Ctrl-\ (the session keeps running).

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const c = std.c;
const protocol = @import("protocol");

const usage =
    \\usage: tw <command>
    \\
    \\commands:
    \\  new           create a session sized like this terminal and attach
    \\  ls            list sessions
    \\  attach <id>   attach this terminal to a session (detach: Ctrl-\)
    \\  kill <id>     ask the daemon to end a session
    \\
;

var winch_flag: std.atomic.Value(bool) = .init(false);

fn handleWinch(_: posix.SIG) callconv(.c) void {
    winch_flag.store(true, .monotonic);
}

fn getWinsize(fd: posix.fd_t) posix.winsize {
    var ws: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = c.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    // A pty that was never sized reports 0x0; fall back to a sane default.
    if (ws.row == 0 or ws.col == 0) {
        ws.row = 24;
        ws.col = 80;
    }
    return ws;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "new")) {
        const ws = getWinsize(posix.STDIN_FILENO);
        const resp = try rpc(arena, .{ .op = .create_session, .cols = ws.col, .rows = ws.row });
        const sess = resp.session orelse fail("daemon returned no session", .{});
        std.debug.print("session {d} created\n", .{sess.id});
        return attach(arena, sess.id, sess.socket_path);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        const resp = try rpc(arena, .{ .op = .list_sessions });
        const sessions = resp.sessions orelse &.{};
        var stdout_buffer: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;
        if (sessions.len == 0) {
            try stdout.print("no sessions\n", .{});
        } else {
            try stdout.print("{s:<6} {s:<8} {s:<9} {s}\n", .{ "ID", "PID", "SIZE", "SOCKET" });
            for (sessions) |sess| {
                var size_buf: [16]u8 = undefined;
                const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ sess.cols, sess.rows });
                var pid_buf: [16]u8 = undefined;
                const pid = try std.fmt.bufPrint(&pid_buf, "{d}", .{sess.pid});
                try stdout.print("{d:<6} {s:<8} {s:<9} {s}\n", .{ sess.id, pid, size, sess.socket_path });
            }
        }
        try stdout.flush();
    } else if (std.mem.eql(u8, cmd, "attach")) {
        const id = parseId(args);
        const resp = try rpc(arena, .{ .op = .list_sessions });
        const sessions = resp.sessions orelse &.{};
        for (sessions) |sess| {
            if (sess.id == id) return attach(arena, sess.id, sess.socket_path);
        }
        fail("no such session: {d}", .{id});
    } else if (std.mem.eql(u8, cmd, "kill")) {
        const id = parseId(args);
        const resp = try rpc(arena, .{ .op = .kill_session, .id = id });
        if (!resp.ok) fail("kill failed: {s}", .{resp.msg orelse "unknown error"});
        std.debug.print("session {d} signalled\n", .{id});
    } else {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
}

fn parseId(args: []const [:0]const u8) u32 {
    if (args.len < 3) fail("missing session id", .{});
    return std.fmt.parseInt(u32, args[2], 10) catch fail("bad session id: {s}", .{args[2]});
}

/// One request/response round trip on the control socket. The parsed
/// response is arena-allocated.
fn rpc(arena: std.mem.Allocator, req: protocol.Request) !protocol.Response {
    var path_buf: [108]u8 = undefined;
    const path = try protocol.controlSocketPath(&path_buf);
    const fd = protocol.connectUnix(path) catch
        fail("cannot connect to daemon at {s} (is termwired running?)", .{path});
    defer _ = c.close(fd);

    const json = try std.json.Stringify.valueAlloc(arena, req, .{});
    if (!protocol.sendAll(fd, json) or !protocol.sendAll(fd, "\n"))
        return error.SendFailed;

    var line: std.ArrayList(u8) = .empty;
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch return error.ReadFailed;
        if (n == 0) return error.DaemonClosed;
        if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |nl| {
            try line.appendSlice(arena, buf[0..nl]);
            break;
        }
        try line.appendSlice(arena, buf[0..n]);
    }

    return std.json.parseFromSliceLeaky(protocol.Response, arena, line.items, .{});
}

const detach_key = 0x1c; // Ctrl-\

fn sendResize(fd: posix.fd_t, ws: posix.winsize) void {
    var msg: [protocol.frame_header_len + 4]u8 = undefined;
    protocol.writeFrameHeader(msg[0..protocol.frame_header_len], .resize, 4);
    std.mem.writeInt(u16, msg[5..7], ws.col, .little);
    std.mem.writeInt(u16, msg[7..9], ws.row, .little);
    _ = protocol.sendAll(fd, &msg);
}

fn sendData(fd: posix.fd_t, bytes: []const u8) bool {
    var header: [protocol.frame_header_len]u8 = undefined;
    var off: usize = 0;
    while (off < bytes.len) {
        const chunk = @min(bytes.len - off, protocol.max_frame_payload);
        protocol.writeFrameHeader(&header, .data, @intCast(chunk));
        if (!protocol.sendAll(fd, &header)) return false;
        if (!protocol.sendAll(fd, bytes[off..][0..chunk])) return false;
        off += chunk;
    }
    return true;
}

fn attach(arena: std.mem.Allocator, id: u32, socket_path: []const u8) !void {
    _ = arena;
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    const sock = protocol.connectUnix(socket_path) catch
        fail("cannot connect to session socket {s}", .{socket_path});
    defer _ = c.close(sock);

    std.debug.print("[attached to session {d}; detach: Ctrl-\\]\r\n", .{id});

    // Raw mode for the local terminal; the remote PTY does the cooking.
    const saved = try posix.tcgetattr(stdin_fd);
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.oflag.OPOST = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
    defer posix.tcsetattr(stdin_fd, .FLUSH, saved) catch {};

    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = handleWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // Size the session to this terminal.
    sendResize(sock, getWinsize(stdin_fd));

    var buf: [4096]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = sock, .events = posix.POLL.IN, .revents = 0 },
    };

    pump: while (true) {
        _ = posix.poll(&fds, 200) catch |err| switch (err) {
            else => return err,
        };

        if (winch_flag.swap(false, .monotonic))
            sendResize(sock, getWinsize(stdin_fd));

        // Local keyboard -> session (framed), watching for the detach key.
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = try posix.read(stdin_fd, &buf);
            if (n == 0) break :pump;
            if (std.mem.indexOfScalar(u8, buf[0..n], detach_key)) |i| {
                _ = sendData(sock, buf[0..i]);
                std.debug.print("\r\n[detached from session {d}]\r\n", .{id});
                return;
            }
            if (!sendData(sock, buf[0..n])) break :pump;
        }

        // Session output -> local terminal (raw).
        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(sock, &buf) catch break :pump;
            if (n == 0) break :pump;
            var off: usize = 0;
            while (off < n) {
                const w = c.write(stdout_fd, buf[off..].ptr, n - off);
                if (w < 0) break :pump;
                off += @intCast(w);
            }
        }

        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;
        if (fds[1].revents & posix.POLL.ERR != 0) break;
    }

    std.debug.print("\r\n[session {d} ended]\r\n", .{id});
}
