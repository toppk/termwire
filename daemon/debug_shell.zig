//! `termwired --debug-shell`: host $SHELL on a daemon-owned PTY and pump
//! bytes to/from the invoking terminal. This is a bring-up harness for
//! the PTY layer, not a real client. It exercises exactly the path a
//! session will use: PTY ownership, resize propagation, child lifetime.

const std = @import("std");
const posix = std.posix;
const c = std.c;
const Pty = @import("Pty.zig");

var winch_flag: std.atomic.Value(bool) = .init(false);

fn handleWinch(_: posix.SIG) callconv(.c) void {
    winch_flag.store(true, .monotonic);
}

fn getWinsize(fd: posix.fd_t) posix.winsize {
    var ws: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = c.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    return ws;
}

pub fn run() !void {
    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;

    // Spawn $SHELL on a fresh PTY sized like our own terminal.
    var pty: Pty = try .open(getWinsize(stdin_fd));
    defer pty.deinit();

    const shell: [*:0]const u8 = c.getenv("SHELL") orelse "/bin/sh";
    const argv = [_:null]?[*:0]const u8{shell};
    try pty.spawn(&argv);

    // Put our own terminal into raw mode so every byte reaches the PTY.
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

    // Propagate terminal resizes to the PTY.
    posix.sigaction(.WINCH, &.{
        .handler = .{ .handler = handleWinch },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    var buf: [4096]u8 = undefined;
    var fds = [_]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
    };

    pump: while (true) {
        // Timeout so we notice SIGWINCH even if poll was auto-restarted.
        _ = posix.poll(&fds, 200) catch |err| switch (err) {
            else => return err,
        };

        if (winch_flag.swap(false, .monotonic))
            try pty.setSize(getWinsize(stdin_fd));

        // Our terminal -> PTY.
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = try posix.read(stdin_fd, &buf);
            if (n == 0) break :pump;
            var off: usize = 0;
            while (off < n) {
                const w = c.write(pty.master, buf[off..].ptr, n - off);
                if (w < 0) break :pump;
                off += @intCast(w);
            }
        }

        // PTY -> our terminal.
        if (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(pty.master, &buf) catch break :pump;
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

    const status = pty.wait(true);
    std.log.info("shell exited status={?d}", .{status});
}
