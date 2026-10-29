//! A small terminal emulator for tests: enough of xterm for what `Screen`
//! writes, keeping each cell's character and style, so tests can check
//! what a person would see.
//!
//! It handles text (with xterm's pending wrap), CR, LF, scrolling in the
//! scroll region, and the escapes CUP (`H`), CUU (`A`), CUF (`C`), ED
//! (`2J`), EL (`K`, `2K`), DECSTBM (`r`), SGR (`m`), DECSC (`ESC 7`) and
//! DECRC (`ESC 8`). Erasing and scrolling fill with the current background,
//! as xterm does.

const std = @import("std");

const TestTerminal = @This();

pub const max_width = 80;
pub const max_height = 30;

width: u16,
height: u16,
cells: [max_height][max_width]Cell = undefined,
/// The cursor, from 0.
row: u16 = 0,
col: u16 = 0,
/// The last column was written; the next character wraps first.
wrap_pending: bool = false,
/// The scroll region's first and last rows, from 0.
top: u16 = 0,
bottom: u16,
style: Style = .{},
saved: struct { row: u16, col: u16, style: Style } = .{ .row = 0, .col = 0, .style = .{} },
/// An escape sequence being read.
escape: std.ArrayList(u8) = .empty,
escape_buf: [64]u8 = undefined,

pub const Color = union(enum) {
    default,
    /// A 256-color palette entry; 0-15 are the theme's colors.
    index: u8,
    rgb: [3]u8,
};

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    fg: Color = .default,
    bg: Color = .default,
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},
};

pub fn init(width: u16, height: u16) TestTerminal {
    var t: TestTerminal = .{ .width = width, .height = height, .bottom = height - 1 };
    for (&t.cells) |*row| row.* = @splat(.{});
    t.escape = .initBuffer(&t.escape_buf);
    return t;
}

pub fn cell(t: *const TestTerminal, row: u16, col: u16) Cell {
    return t.cells[row][col];
}

/// The text of a row, without trailing spaces.
pub fn rowText(t: *const TestTerminal, row: u16, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (t.cells[row][0..t.width]) |c| w.printUnicodeCodepoint(c.char) catch break;
    return std.mem.trimEnd(u8, w.buffered(), " ");
}

/// Interprets what a program wrote.
pub fn write(t: *TestTerminal, bytes: []const u8) void {
    var it = std.unicode.Utf8View.initUnchecked(bytes).iterator();
    while (it.nextCodepoint()) |cp| t.feed(cp);
}

fn feed(t: *TestTerminal, cp: u21) void {
    if (t.escape.items.len > 0) return t.feedEscape(cp);
    switch (cp) {
        0x1b => t.escape.appendAssumeCapacity(0x1b),
        '\r' => {
            t.col = 0;
            t.wrap_pending = false;
        },
        '\n' => t.lineFeed(),
        else => t.put(cp),
    }
}

fn put(t: *TestTerminal, cp: u21) void {
    if (t.wrap_pending) {
        t.col = 0;
        t.lineFeed();
    }
    t.cells[t.row][t.col] = .{ .char = cp, .style = t.style };
    if (t.col + 1 < t.width) t.col += 1 else t.wrap_pending = true;
}

fn lineFeed(t: *TestTerminal) void {
    t.wrap_pending = false;
    if (t.row == t.bottom) {
        var r = t.top;
        while (r < t.bottom) : (r += 1) t.cells[r] = t.cells[r + 1];
        t.eraseRow(t.bottom, 0);
    } else if (t.row + 1 < t.height) {
        t.row += 1;
    }
}

fn eraseRow(t: *TestTerminal, row: u16, from: u16) void {
    for (t.cells[row][from..t.width]) |*c| c.* = .{ .style = .{ .bg = t.style.bg } };
}

fn feedEscape(t: *TestTerminal, cp: u21) void {
    const c: u8 = std.math.cast(u8, cp) orelse '?';
    t.escape.appendBounded(c) catch {};
    const seq = t.escape.items;
    if (seq.len == 2 and seq[1] != '[') {
        switch (seq[1]) {
            '7' => t.saved = .{ .row = t.row, .col = t.col, .style = t.style },
            '8' => {
                t.row = t.saved.row;
                t.col = t.saved.col;
                t.style = t.saved.style;
                t.wrap_pending = false;
            },
            else => {},
        }
        t.escape.clearRetainingCapacity();
        return;
    }
    if (seq.len < 3 or !std.ascii.isAlphabetic(c)) return;
    var params: [16]u16 = @splat(0);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, seq[2 .. seq.len - 1], ';');
    while (it.next()) |p| : (count += 1) {
        if (count == params.len) break;
        params[count] = std.fmt.parseInt(u16, p, 10) catch 0;
    }
    t.csi(c, params[0..count]);
    t.escape.clearRetainingCapacity();
}

fn csi(t: *TestTerminal, final: u8, params: []const u16) void {
    const first = if (params.len > 0) params[0] else 0;
    t.wrap_pending = false;
    switch (final) {
        'H' => {
            t.row = @min(@max(first, 1), t.height) - 1;
            t.col = @min(@max(if (params.len > 1) params[1] else 0, 1), t.width) - 1;
        },
        'A' => t.row -|= @max(first, 1),
        'C' => t.col = @min(t.col + @max(first, 1), t.width - 1),
        'J' => if (first == 2) {
            for (0..t.height) |r| t.eraseRow(@intCast(r), 0);
        },
        'K' => t.eraseRow(t.row, if (first == 2) 0 else t.col),
        'r' => {
            t.top = if (first > 0) first - 1 else 0;
            t.bottom = if (params.len > 1 and params[1] > 0) @min(params[1], t.height) - 1 else t.height - 1;
            t.row = 0;
            t.col = 0;
        },
        'm' => t.sgr(params),
        else => {},
    }
}

fn sgr(t: *TestTerminal, params: []const u16) void {
    if (params.len == 0) t.style = .{};
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const p = params[i];
        switch (p) {
            0 => t.style = .{},
            1 => t.style.bold = true,
            2 => t.style.dim = true,
            3 => t.style.italic = true,
            4 => t.style.underline = true,
            7 => t.style.reverse = true,
            30...37 => t.style.fg = .{ .index = @intCast(p - 30) },
            40...47 => t.style.bg = .{ .index = @intCast(p - 40) },
            90...97 => t.style.fg = .{ .index = @intCast(p - 90 + 8) },
            100...107 => t.style.bg = .{ .index = @intCast(p - 100 + 8) },
            39 => t.style.fg = .default,
            49 => t.style.bg = .default,
            38, 48 => {
                const color: Color = if (i + 2 < params.len and params[i + 1] == 5) color: {
                    i += 2;
                    break :color .{ .index = @intCast(params[i]) };
                } else if (i + 4 < params.len and params[i + 1] == 2) color: {
                    i += 4;
                    break :color .{ .rgb = .{ @intCast(params[i - 2]), @intCast(params[i - 1]), @intCast(params[i]) } };
                } else .default;
                if (p == 38) t.style.fg = color else t.style.bg = color;
            },
            else => {},
        }
    }
}

test "wrapping, scrolling and erasing" {
    var t: TestTerminal = .init(4, 3);
    var buf: [16]u8 = undefined;
    t.write("abcd");
    try std.testing.expectEqual(0, t.row);
    t.write("e\x1b[44m\r\n\r\nf");
    try std.testing.expectEqualStrings("e", t.rowText(0, &buf));
    try std.testing.expectEqual(Color{ .index = 4 }, t.cell(2, 3).style.bg);
    try std.testing.expectEqualStrings("f", t.rowText(2, &buf));
    t.write("\x1b[0m\x1b[K\x1b[1;2H\x1b[1;38;5;200mX");
    try std.testing.expectEqual(Cell{ .char = 'X', .style = .{ .bold = true, .fg = .{ .index = 200 } } }, t.cell(0, 1));
}
