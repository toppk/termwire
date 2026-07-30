const std = @import("std");
const Io = std.Io;
const protocol = @import("protocol");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("tw (protocol v{d})\n", .{protocol.version});
    try stdout.flush();
}
