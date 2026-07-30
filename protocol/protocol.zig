//! Wire-format types shared by the TermWire daemon and its clients.
//!
//! Control plane: newline-delimited JSON over a Unix domain socket at
//! `<runtime dir>/control.sock`. One `Request` per line in, one
//! `Response` per line out. The connection stays open for further
//! requests.
//!
//! Data plane: one Unix domain socket per session at
//! `<runtime dir>/session-<id>.sock`. Client-to-daemon traffic is
//! framed (see `Frame`); daemon-to-client traffic is the raw PTY
//! output byte stream.

const std = @import("std");

pub const version: u32 = 0;

pub const Op = enum {
    create_session,
    list_sessions,
    kill_session,
};

pub const Request = struct {
    op: Op,
    /// Session id; required by kill_session.
    id: ?u32 = null,
    /// Initial size; used by create_session.
    cols: u16 = 80,
    rows: u16 = 24,
};

pub const SessionInfo = struct {
    id: u32,
    pid: i32,
    cols: u16,
    rows: u16,
    /// Path of the session's data-plane socket.
    socket_path: []const u8,
};

pub const Response = struct {
    ok: bool,
    /// Error description when ok == false.
    msg: ?[]const u8 = null,
    /// Set by create_session.
    session: ?SessionInfo = null,
    /// Set by list_sessions.
    sessions: ?[]const SessionInfo = null,
};

/// Client -> daemon data-plane framing: a 5-byte header followed by
/// `len` payload bytes.
pub const FrameType = enum(u8) {
    /// Payload is keyboard/stdin bytes for the PTY.
    data = 0,
    /// Payload is 4 bytes: cols u16le, rows u16le.
    resize = 1,
};

pub const frame_header_len = 5;

/// Largest allowed frame payload. Clients must chunk larger writes.
pub const max_frame_payload = 4096;

pub fn writeFrameHeader(buf: *[frame_header_len]u8, ft: FrameType, len: u32) void {
    buf[0] = @intFromEnum(ft);
    std.mem.writeInt(u32, buf[1..5], len, .little);
}

/// Fill `buf` with the runtime directory path (not created here).
/// Prefers $XDG_RUNTIME_DIR/termwire, falls back to /tmp/termwire-<uid>.
pub fn runtimeDir(buf: []u8) ![]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/termwire", .{xdg});
    }
    return std.fmt.bufPrint(buf, "/tmp/termwire-{d}", .{std.c.getuid()});
}

pub fn controlSocketPath(buf: []u8) ![]const u8 {
    var dir_buf: [96]u8 = undefined;
    const dir = try runtimeDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/control.sock", .{dir});
}

pub fn sessionSocketPath(buf: []u8, id: u32) ![]const u8 {
    var dir_buf: [96]u8 = undefined;
    const dir = try runtimeDir(&dir_buf);
    return std.fmt.bufPrint(buf, "{s}/session-{d}.sock", .{ dir, id });
}

/// Connect a blocking, CLOEXEC stream socket to a Unix socket path.
pub fn connectUnix(path: []const u8) !std.posix.fd_t {
    const posix = std.posix;
    if (path.len >= 107) return error.PathTooLong;

    const fd = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) < 0)
        return error.ConnectFailed;
    return fd;
}

/// send() the whole buffer, suppressing SIGPIPE. Returns false on error.
pub fn sendAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.send(fd, bytes[off..].ptr, bytes.len - off, std.posix.MSG.NOSIGNAL);
        if (n < 0) return false;
        off += @intCast(n);
    }
    return true;
}

test "request round-trips through JSON" {
    const alloc = std.testing.allocator;
    const req: Request = .{ .op = .create_session, .cols = 120, .rows = 40 };
    const json = try std.json.Stringify.valueAlloc(alloc, req, .{});
    defer alloc.free(json);
    const parsed = try std.json.parseFromSlice(Request, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(req, parsed.value);
}

test "frame header round-trips" {
    var buf: [frame_header_len]u8 = undefined;
    writeFrameHeader(&buf, .resize, 4);
    try std.testing.expectEqual(@as(u8, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, buf[1..5], .little));
}
