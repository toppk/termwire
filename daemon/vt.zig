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

/// Serialize a terminal's full state as a VT byte sequence that
/// reconstructs it when replayed into a fresh terminal (or any
/// VT-speaking client). This is the attach snapshot.
pub fn writeSnapshot(term: *const ghostty.Terminal, writer: *std.Io.Writer) !void {
    var fmt = ghostty.formatter.TerminalFormatter.init(term, .vt);
    fmt.extra = .all;
    try fmt.format(writer);
    // Upstream emits the tabstop reconstruction after the cursor
    // restore, which strands the cursor at the last tabstop.
    // Re-assert the position last so replay ends where the session is.
    const cursor = term.screens.active.cursor;
    try writer.print("\x1b[{d};{d}H", .{
        @as(u32, cursor.y) + 1,
        @as(u32, cursor.x) + 1,
    });
}

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

test "snapshot round-trip: formatter output rebuilds the screen" {
    const alloc = std.testing.allocator;

    // Session terminal with some state: text, styles, cursor movement.
    var a: ghostty.Terminal = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer a.deinit(alloc);
    var stream_a: ghostty.TerminalStream = .initAlloc(alloc, .init(&a));
    defer stream_a.deinit();
    stream_a.nextSlice("plain \x1b[1;31mbold-red\x1b[0m\r\r\n" ++
        "\x1b[44mon-blue\x1b[0m tail\r\r\n" ++
        "\x1b[3;10Hpositioned");

    // Snapshot it the way the daemon does on attach.
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSnapshot(&a, &out.writer);

    // Replay into a fresh terminal, as an attaching client would.
    var b: ghostty.Terminal = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
    defer b.deinit(alloc);
    var stream_b: ghostty.TerminalStream = .initAlloc(alloc, .init(&b));
    defer stream_b.deinit();
    stream_b.nextSlice(out.writer.buffered());

    const text_a = try a.plainString(alloc);
    defer alloc.free(text_a);
    const text_b = try b.plainString(alloc);
    defer alloc.free(text_b);
    try std.testing.expectEqualStrings(text_a, text_b);
    try std.testing.expectEqual(a.screens.active.cursor.x, b.screens.active.cursor.x);
    try std.testing.expectEqual(a.screens.active.cursor.y, b.screens.active.cursor.y);
}
