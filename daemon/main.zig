const std = @import("std");
const protocol = @import("protocol");
const debug_shell = @import("debug_shell.zig");
const Daemon = @import("Daemon.zig");

const version = "0.0.0";

pub const std_options: std.Options = .{ .logFn = protocol.logging.logFn };

const usage =
    \\usage: termwired [command]
    \\
    \\commands:
    \\  (none)         run the daemon in the foreground
    \\  --version      print version and exit
    \\  --debug-shell  host $SHELL on a daemon-owned PTY, attached to
    \\                 the current terminal (PTY layer bring-up harness)
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--debug-shell")) {
            return debug_shell.run();
        } else if (std.mem.eql(u8, args[1], "--version")) {
            std.debug.print("termwired {s} (protocol v{d})\n", .{ version, protocol.version });
            return;
        } else {
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
    }

    return Daemon.run(std.heap.smp_allocator);
}

test {
    _ = @import("vt.zig");
    _ = @import("Pty.zig");
    _ = @import("Daemon.zig");
}
