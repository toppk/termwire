const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol");
const debug_shell = @import("debug_shell.zig");

const version = "0.0.0";

const usage =
    \\usage: termwired [command]
    \\
    \\commands:
    \\  (none)         print version and exit (daemon mode comes later)
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
        } else {
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
    }

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("termwired {s} (protocol v{d})\n", .{ version, protocol.version });
    try stdout.flush();
}

test {
    _ = @import("vt.zig");
    _ = @import("Pty.zig");
}
