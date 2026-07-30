//! A POSIX pseudo-terminal pair plus the child process running on its
//! slave side. This is the object the daemon owns per session: the PTY
//! outlives any client that happens to be viewing it.

const Pty = @This();

const std = @import("std");
const posix = std.posix;
const c = std.c;

// From libc (glibc merged libutil into libc; declared in <pty.h>/<utmp.h>).
extern "c" fn openpty(
    master: *c.fd_t,
    slave: *c.fd_t,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const posix.winsize,
) c_int;
extern "c" fn login_tty(fd: c.fd_t) c_int;
extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) c_int;

master: posix.fd_t,
/// Slave fd is only held between open() and spawn(); spawn closes it
/// in the parent once the child owns it.
slave: posix.fd_t,
/// Child pid once spawn() has been called.
pid: c.pid_t = -1,

pub fn open(size: posix.winsize) !Pty {
    var master: c.fd_t = undefined;
    var slave: c.fd_t = undefined;
    if (openpty(&master, &slave, null, null, &size) < 0)
        return error.OpenptyFailed;
    errdefer {
        _ = c.close(master);
        _ = c.close(slave);
    }

    // Only the slave side should be inherited by children.
    const flags = c.fcntl(master, posix.F.GETFD);
    if (flags < 0) return error.FcntlFailed;
    if (c.fcntl(master, posix.F.SETFD, flags | posix.FD_CLOEXEC) < 0)
        return error.FcntlFailed;

    return .{ .master = master, .slave = slave };
}

pub fn deinit(self: *Pty) void {
    _ = c.close(self.master);
    if (self.slave >= 0) _ = c.close(self.slave);
    self.* = undefined;
}

pub fn setSize(self: *const Pty, size: posix.winsize) !void {
    if (c.ioctl(self.master, posix.T.IOCSWINSZ, @intFromPtr(&size)) < 0)
        return error.IoctlFailed;
}

/// Fork and exec `argv[0]` (PATH-searched) as the session leader on the
/// slave side, with stdio wired to the PTY. Returns in the parent with
/// `pid` set; the slave fd is closed in the parent.
pub fn spawn(self: *Pty, argv: [*:null]const ?[*:0]const u8) !void {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // Child. Only async-signal-safe calls from here on.
        // login_tty: setsid + make slave the controlling tty + dup2 to
        // stdio + close the original fd.
        if (login_tty(self.slave) < 0) std.process.abort();
        _ = execvp(argv[0].?, argv);
        std.process.abort();
    }

    // Parent.
    _ = c.close(self.slave);
    self.slave = -1;
    self.pid = pid;
}

/// Non-blocking check whether the child has exited; reaps it if so.
/// Returns the exit status, or null if still running.
pub fn wait(self: *Pty, block: bool) ?u32 {
    if (self.pid < 0) return null;
    var status: c_int = 0;
    const flags: c_int = if (block) 0 else c.W.NOHANG;
    const rc = c.waitpid(self.pid, &status, flags);
    if (rc == self.pid) {
        self.pid = -1;
        return @bitCast(status);
    }
    return null;
}
