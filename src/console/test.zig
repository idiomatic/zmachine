//! Tests of what `Screen` draws, read back through a test terminal.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Screen = @import("Screen.zig");
const TerminalInput = @import("TerminalInput.zig");
const TestTerminal = @import("TestTerminal.zig");

/// A full-screen screen of `width` by `height`, version 3 (with a status
/// line), whose piped input is `input`.
const Harness = struct {
    out: Io.Writer.Allocating,
    in: Io.Reader,
    keyboard: TerminalInput,
    screen: Screen,

    fn init(h: *Harness, input: []const u8, width: u16, height: u16) void {
        h.out = .init(testing.allocator);
        h.in = .fixed(input);
        h.keyboard = .{ .in = &h.in };
        h.screen = .init(testing.io, &h.out.writer, h.keyboard.input(), 3, true, false);
        h.screen.width = width;
        h.screen.height = height;
        h.screen.lower_row = height;
    }

    fn deinit(h: *Harness) void {
        h.out.deinit();
    }

    /// What a terminal shows after everything written so far.
    fn terminal(h: *Harness) TestTerminal {
        h.screen.out.flush() catch unreachable;
        var t: TestTerminal = .init(h.screen.width, h.screen.height);
        t.write(h.out.written());
        return t;
    }

    fn print(h: *Harness, text: []const u8) !void {
        for (text) |c| try h.screen.print(c);
    }
};

test "the status line takes the header look" {
    var h: Harness = undefined;
    h.init("", 30, 5);
    defer h.deinit();
    try h.screen.start();
    try h.screen.drawStatus("West of House", "Score: 0");
    const t = h.terminal();
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(" West of House       Score: 0", t.rowText(0, &buf));
    const header: TestTerminal.Style = .{ .bold = true, .fg = .{ .index = 231 }, .bg = .{ .index = 24 } };
    try testing.expectEqual(header, t.cell(0, 1).style);
    // The rest of the row too, to its end.
    try testing.expectEqual(header, t.cell(0, 29).style);
}

test "the prompt and piped input take their looks" {
    var h: Harness = undefined;
    h.init("open mailbox\n", 30, 5);
    defer h.deinit();
    try h.screen.looks.apply("prompt=bold+red,input=green,priorinput=italic");
    try h.screen.start();
    try h.print("Hello.\n\n>");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("open mailbox", (try h.screen.readLine(&buf)).?);
    const t = h.terminal();
    // The line just entered is on the row above the cursor.
    const row = t.row - 1;
    try testing.expectEqualStrings(">open mailbox", t.rowText(row, &buf));
    try testing.expectEqual(TestTerminal.Style{ .bold = true, .fg = .{ .index = 1 } }, t.cell(row, 0).style);
    // Piped input is echoed already entered: the prior look over input.
    try testing.expectEqual(TestTerminal.Style{ .italic = true, .fg = .{ .index = 2 } }, t.cell(row, 1).style);
    // The game's own style afterwards.
    try testing.expectEqual(TestTerminal.Style{}, t.style);
}

test "an input background stays on its row" {
    var h: Harness = undefined;
    h.init("look\n", 20, 4);
    defer h.deinit();
    try h.screen.looks.apply("input=/blue");
    try h.screen.start();
    try h.print(">");
    var buf: [64]u8 = undefined;
    _ = try h.screen.readLine(&buf);
    const t = h.terminal();
    // Entering the line at the bottom scrolled a new row in with the
    // input's background; it is cleared in the game's.
    try testing.expectEqual(t.height - 1, t.row);
    try testing.expectEqualStrings(">look", t.rowText(t.row - 1, &buf));
    try testing.expectEqual(TestTerminal.Color{ .index = 4 }, t.cell(t.row - 1, 1).style.bg);
    for (0..t.width) |col| {
        try testing.expectEqual(TestTerminal.Color.default, t.cell(t.row, @intCast(col)).style.bg);
    }
}

test "plain output has no escapes" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: Io.Reader = .fixed("look\n");
    var keyboard: TerminalInput = .{ .in = &in };
    var s: Screen = .init(testing.io, &out.writer, keyboard.input(), 3, false, false);
    try s.start();
    try s.drawStatus("West of House", "Score: 0");
    for ("Hello, sailor.\n>") |c| try s.print(c);
    var buf: [64]u8 = undefined;
    _ = try s.readLine(&buf);
    try s.finish();
    try testing.expectEqualStrings("Hello, sailor.\n>look\n", out.written());
}
