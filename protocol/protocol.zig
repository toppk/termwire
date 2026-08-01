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

pub const version: u32 = 1;

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
    /// Unix timestamp of session creation.
    created_unix: i64 = 0,
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

/// Data-plane framing, both directions: a 5-byte header (type byte +
/// u32le payload length) followed by the payload.
///
/// On attach the daemon sends one `snapshot` frame — a VT byte
/// sequence reconstructing the session's current screen state
/// (palette, modes, content, cursor) — followed by `output` frames as
/// the PTY produces bytes. The daemon is single-threaded, so the
/// snapshot is atomic with respect to the output stream: every client
/// sees the same snapshot point and the same events after it.
pub const FrameType = enum(u8) {
    /// client -> daemon: keyboard/stdin bytes for the PTY.
    data = 0,
    /// client -> daemon: 4-byte payload, cols u16le then rows u16le.
    resize = 1,
    /// daemon -> client: screen reconstruction, sent once on attach.
    snapshot = 2,
    /// daemon -> client: raw PTY output.
    output = 3,
};

pub const frame_header_len = 5;

/// Largest allowed client -> daemon frame payload; clients must chunk
/// larger writes. Daemon -> client frames (snapshots) may be larger.
pub const max_frame_payload = 4096;

/// Upper bound a client should accept for a daemon -> client frame.
pub const max_downstream_frame = 16 * 1024 * 1024;

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

/// std.log backend for the TermWire daemons: the standard scoped
/// output with a UTC timestamp prefix. Install from a root file with:
///   pub const std_options: std.Options = .{ .logFn = protocol.logging.logFn };
pub const logging = struct {
    extern "c" fn time(tloc: ?*i64) i64;

    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const io = std.Options.debug_io;
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        var buffer: [64]u8 = undefined;
        const terminal = std.debug.lockStderr(&buffer).terminal();
        defer std.debug.unlockStderr();
        logInner(level, scope, format, args, terminal) catch {};
    }

    fn logInner(
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
        terminal: std.Io.Terminal,
    ) !void {
        const now = time(null);
        if (now > 0) {
            const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now) };
            const yd = es.getEpochDay().calculateYearDay();
            const md = yd.calculateMonthDay();
            const ds = es.getDaySeconds();
            terminal.setColor(.dim) catch {};
            try terminal.writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z ", .{
                yd.year,                  md.month.numeric(),        md.day_index + 1,
                ds.getHoursIntoDay(),     ds.getMinutesIntoHour(),   ds.getSecondsIntoMinute(),
            });
            terminal.setColor(.reset) catch {};
        }
        try std.log.defaultLogFileTerminal(level, scope, format, args, terminal);
    }
};

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
