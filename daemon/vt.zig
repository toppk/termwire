//! Integration point between the daemon and Ghostty's VT engine
//! (the `ghostty-vt` Zig module exported by third_party/ghostty).
//!
//! For now this only proves the wiring works: bytes go through
//! ghostty.TerminalStream into a ghostty.Terminal whose screen state
//! we can query. The daemon will grow a per-session Terminal here so
//! canonical screen state and scrollback live in the runtime, not in
//! clients.

const std = @import("std");
const ghostty = @import("ghostty-vt");

test "ghostty-vt: bytes through the VT stream produce screen state" {
    const alloc = std.testing.allocator;

    var term: ghostty.Terminal = try .init(
        std.testing.io,
        alloc,
        .{ .cols = 80, .rows = 24 },
    );
    defer term.deinit(alloc);

    var stream: ghostty.TerminalStream = .initAlloc(alloc, .init(&term));
    defer stream.deinit();

    stream.nextSlice("hello \x1b[1mworld\x1b[0m\r\r\ngoodbye");

    const str = try term.plainString(alloc);
    defer alloc.free(str);
    try std.testing.expectEqualStrings("hello world\ngoodbye", str);

    // Cursor ended up after "goodbye" on row 1 (0-indexed).
    try std.testing.expectEqual(@as(usize, 1), term.screens.active.cursor.y);
    try std.testing.expectEqual(@as(usize, 7), term.screens.active.cursor.x);
}
