const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol");

const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("termwired {s} (protocol v{d})\n", .{ version, protocol.version });
    try stdout.flush();
}

test {
    _ = @import("vt.zig");
}
