//! Terminal front end: the status line, upper and lower windows, text
//! styles and keyboard input, rendered with xterm-256color escape sequences.
//!
//! The lower window is a scroll region at the bottom of the terminal; the
//! status line (version 3) and the upper window sit above it and are drawn
//! with absolute cursor positioning. When stdout is not a terminal, output
//! degrades to plain word-wrapped text.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

const Screen = @This();

io: Io,
out: *Io.Writer,
in: *Io.Reader,
/// Draw with escape sequences; otherwise emit plain text.
ansi: bool,
/// Whether stdin is a terminal (enables raw key reads).
tty_input: bool,
/// Echo input lines, for when input is piped in.
echo: bool,
width: u16 = 80,
height: u16 = 24,
version: u8,
/// Rows used by the version 3 status line.
status_rows: u16,
upper_rows: u16 = 0,
window: u8 = 0,
upper_row: u16 = 1,
upper_col: u16 = 1,
/// The terminal cursor is somewhere other than the lower window cursor.
restore_lower: bool = false,
lower_row: u16 = 24,
col: u16 = 0,
/// Pending word for word wrapping; escape sequences have zero width.
word: [1024]u8 = undefined,
word_len: usize = 0,
word_width: u16 = 0,
/// Spaces held back until the next word, so lines never end in spaces.
spaces: u16 = 0,
style: u8 = 0,
fg: u8 = 1,
bg: u8 = 1,
buffered: bool = true,
lines_since_input: u16 = 0,
/// Keypresses left over from a piped line; see `readKey`.
keys: [256]u8 = undefined,
keys_len: usize = 0,
keys_pos: usize = 0,

pub const Error = Io.Writer.Error || Io.Reader.Error || error{StreamTooLong} || posix.TermiosSetError;

pub const Style = struct {
    pub const reverse = 1;
    pub const bold = 2;
    pub const italic = 4;
    pub const fixed = 8;
};

/// 256-colour palette entries for the Z-machine colours 2-12.
const palette = [_]u8{ 16, 160, 34, 220, 33, 164, 44, 255, 250, 244, 238 };

const status_fg = 231;
const status_bg = 24;
const input_fg = 222;

pub fn init(io: Io, out: *Io.Writer, in: *Io.Reader, version: u8, ansi: bool, tty_input: bool) Screen {
    var s: Screen = .{
        .io = io,
        .out = out,
        .in = in,
        .ansi = ansi,
        .tty_input = tty_input,
        .echo = !tty_input,
        .version = version,
        .status_rows = if (version <= 3) 1 else 0,
    };
    if (ansi) {
        if (querySize()) |size| {
            s.width = size[0];
            s.height = size[1];
        }
    }
    s.lower_row = s.height;
    return s;
}

fn querySize() ?[2]u16 {
    var ws: posix.winsize = undefined;
    const fd = Io.File.stdout().handle;
    if (std.c.ioctl(fd, std.c.T.IOCGWINSZ, &ws) != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ ws.col, ws.row };
}

/// Prepares the terminal: clears it and sets up the scroll region.
pub fn start(s: *Screen) Error!void {
    if (!s.ansi) return;
    try s.out.writeAll("\x1b[0m\x1b[2J");
    try s.applyRegion();
    s.lower_row = if (s.version >= 5) s.topRows() + 1 else s.height;
    try s.moveLower();
    if (s.status_rows > 0) try s.drawStatus("", "");
}

/// Restores the terminal to a normal state.
pub fn finish(s: *Screen) Error!void {
    try s.flushWord();
    if (s.ansi) {
        try s.out.print("\x1b[0m\x1b[r\x1b[{d};1H\r\n", .{s.height});
    }
    try s.out.flush();
}

pub fn topRows(s: *const Screen) u16 {
    return s.status_rows + s.upper_rows;
}

fn applyRegion(s: *Screen) Error!void {
    const top = @min(s.topRows() + 1, s.height);
    try s.out.print("\x1b[{d};{d}r", .{ top, s.height });
    // Setting the region homes the cursor.
    s.restore_lower = true;
}

fn moveLower(s: *Screen) Error!void {
    if (!s.ansi) return;
    try s.out.print("\x1b[{d};{d}H", .{ s.lower_row, s.col + 1 });
    s.restore_lower = false;
}

fn writeLower(s: *Screen, bytes: []const u8) Error!void {
    if (s.restore_lower) try s.moveLower();
    try s.out.writeAll(bytes);
}

/// Writes an escape sequence at the current point in the text stream.
fn writeEscape(s: *Screen, bytes: []const u8) Error!void {
    if (!s.ansi) return;
    if (s.window == 0 and s.buffered and s.word_len + bytes.len <= s.word.len) {
        @memcpy(s.word[s.word_len..][0..bytes.len], bytes);
        s.word_len += bytes.len;
    } else if (s.window == 0) {
        try s.flushWord();
        try s.writeLower(bytes);
    } else {
        try s.out.writeAll(bytes);
    }
}

/// Writes out the pending word and any spaces held back before it.
pub fn flushWord(s: *Screen) Error!void {
    try s.emitWord();
    if (s.spaces > 0) {
        const n = @min(s.spaces, s.width -| s.col);
        try s.writeSpaces(n);
        s.spaces = 0;
    }
}

fn writeSpaces(s: *Screen, n: u16) Error!void {
    if (n == 0) return;
    if (s.restore_lower) try s.moveLower();
    try s.out.splatByteAll(' ', n);
    s.col += n;
}

/// Writes the pending word, breaking the line first if it does not fit.
fn emitWord(s: *Screen) Error!void {
    if (s.word_len == 0) return;
    if (s.word_width > 0) {
        if (s.col > 0 and s.col + s.spaces + s.word_width > s.width) {
            try s.newline();
        } else {
            try s.writeSpaces(s.spaces);
        }
        s.spaces = 0;
    }
    try s.writeLower(s.word[0..s.word_len]);
    s.col += s.word_width;
    s.word_len = 0;
    s.word_width = 0;
}

fn newline(s: *Screen) Error!void {
    try s.writeLower(if (s.ansi) "\r\n" else "\n");
    s.col = 0;
    s.spaces = 0;
    if (s.lower_row < s.height) s.lower_row += 1;
    s.lines_since_input += 1;
    if (s.ansi and s.tty_input and s.lines_since_input + 1 >= s.height -| s.topRows()) {
        try s.more();
    }
}

fn more(s: *Screen) Error!void {
    try s.writeLower("\x1b[7m[MORE]\x1b[0m");
    _ = try s.readKey();
    try s.out.writeAll("\r\x1b[K");
    try s.writeSgr();
    s.lines_since_input = 0;
}

/// Prints one Unicode character to the current window.
pub fn print(s: *Screen, cp: u21) Error!void {
    var utf8: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &utf8) catch blk: {
        utf8[0] = '?';
        break :blk 1;
    };
    const bytes = utf8[0..len];

    if (s.window == 1) return s.printUpper(cp, bytes);

    if (cp == '\n') {
        try s.emitWord();
        return s.newline();
    }
    if (!s.buffered) {
        try s.flushWord();
        if (s.col >= s.width) try s.newline();
        try s.writeLower(bytes);
        s.col += 1;
        return;
    }
    if (cp == ' ') {
        try s.emitWord();
        s.spaces += 1;
        return;
    }
    if (s.word_len + bytes.len > s.word.len or s.word_width >= s.width) try s.emitWord();
    @memcpy(s.word[s.word_len..][0..bytes.len], bytes);
    s.word_len += bytes.len;
    s.word_width += 1;
}

fn printUpper(s: *Screen, cp: u21, bytes: []const u8) Error!void {
    if (cp == '\n') {
        s.upper_row += 1;
        s.upper_col = 1;
        return;
    }
    if (!s.ansi) return;
    if (s.upper_row > s.upper_rows or s.upper_col > s.width) return;
    try s.out.print("\x1b[{d};{d}H", .{ s.upper_row + s.status_rows, s.upper_col });
    try s.out.writeAll(bytes);
    s.upper_col += 1;
    s.restore_lower = true;
}

/// Draws the version 3 status line.
pub fn drawStatus(s: *Screen, left: []const u8, right: []const u8) Error!void {
    if (!s.ansi or s.status_rows == 0) return;
    try s.flushWord();
    try s.out.print("\x1b[1;1H\x1b[0;1;38;5;{d};48;5;{d}m ", .{ status_fg, status_bg });
    const left_width = displayWidth(left);
    const right_width = displayWidth(right);
    const room = s.width -| 2;
    var used: usize = 0;
    if (left_width + right_width + 2 <= room) {
        try s.out.writeAll(left);
        used = left_width;
    } else {
        var it = std.unicode.Utf8View.initUnchecked(left).iterator();
        while (used + right_width + 3 < room) : (used += 1) {
            const cp = it.nextCodepointSlice() orelse break;
            try s.out.writeAll(cp);
        }
    }
    try s.out.splatByteAll(' ', room -| (used + right_width));
    try s.out.writeAll(right);
    try s.out.writeAll(" ");
    s.restore_lower = true;
    try s.writeSgrDirect();
}

fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn splitWindow(s: *Screen, lines: u16) Error!void {
    try s.flushWord();
    s.upper_rows = @min(lines, s.height -| s.status_rows -| 1);
    if (s.ansi) {
        try s.applyRegion();
        if (s.version == 3) try s.clearRows(s.status_rows + 1, s.topRows());
    }
    if (s.lower_row <= s.topRows()) {
        s.lower_row = s.topRows() + 1;
        s.col = 0;
    }
    if (s.upper_row > s.upper_rows) {
        s.upper_row = 1;
        s.upper_col = 1;
    }
    s.restore_lower = true;
}

pub fn setWindow(s: *Screen, window: u8) Error!void {
    try s.flushWord();
    s.window = window;
    if (window == 1) {
        s.upper_row = 1;
        s.upper_col = 1;
    }
}

fn clearRows(s: *Screen, first: u16, last: u16) Error!void {
    var row = first;
    while (row <= last) : (row += 1) {
        try s.out.print("\x1b[{d};1H\x1b[2K", .{row});
    }
    s.restore_lower = true;
}

pub fn eraseWindow(s: *Screen, which: i16) Error!void {
    try s.flushWord();
    switch (which) {
        -1, -2 => {
            if (which == -1) {
                s.upper_rows = 0;
                if (s.ansi) try s.applyRegion();
            }
            if (s.ansi) try s.out.writeAll("\x1b[0m\x1b[2J");
            s.lower_row = if (s.version >= 5) s.topRows() + 1 else s.height;
            s.col = 0;
            s.upper_row = 1;
            s.upper_col = 1;
            s.restore_lower = true;
            if (s.ansi) try s.writeSgrDirect();
        },
        0 => {
            if (s.ansi) try s.clearRows(s.topRows() + 1, s.height);
            s.lower_row = if (s.version >= 5) s.topRows() + 1 else s.height;
            s.col = 0;
        },
        1 => {
            if (s.ansi) try s.clearRows(s.status_rows + 1, s.topRows());
            s.upper_row = 1;
            s.upper_col = 1;
        },
        else => {},
    }
    s.lines_since_input = 0;
}

pub fn eraseLine(s: *Screen) Error!void {
    if (!s.ansi) return;
    if (s.window == 1) {
        try s.out.print("\x1b[{d};{d}H\x1b[K", .{ s.upper_row + s.status_rows, s.upper_col });
        s.restore_lower = true;
    } else {
        try s.flushWord();
        try s.writeLower("\x1b[K");
    }
}

pub fn setCursor(s: *Screen, row: u16, col: u16) Error!void {
    if (s.window != 1) return;
    s.upper_row = @max(row, 1);
    s.upper_col = @max(col, 1);
}

pub fn getCursor(s: *const Screen) [2]u16 {
    if (s.window == 1) return .{ s.upper_row, s.upper_col };
    return .{ s.lower_row -| s.topRows(), s.col + 1 + s.spaces + s.word_width };
}

pub fn setStyle(s: *Screen, style: u8) Error!void {
    if (style == 0) {
        s.style = 0;
    } else {
        s.style |= style;
    }
    try s.writeSgr();
}

/// Sets colours using Z-machine colour numbers (0 = unchanged, 1 = default).
pub fn setColour(s: *Screen, fg: u16, bg: u16) Error!void {
    if (fg != 0 and fg <= 12) s.fg = @intCast(fg);
    if (bg != 0 and bg <= 12) s.bg = @intCast(bg);
    try s.writeSgr();
}

pub fn setBuffered(s: *Screen, on: bool) Error!void {
    try s.flushWord();
    s.buffered = on;
}

fn formatSgr(s: *const Screen, buf: []u8) []const u8 {
    var w: Io.Writer = .fixed(buf);
    w.writeAll("\x1b[0") catch unreachable;
    if (s.style & Style.bold != 0) w.writeAll(";1") catch unreachable;
    if (s.style & Style.italic != 0) w.writeAll(";3") catch unreachable;
    if (s.style & Style.reverse != 0) w.writeAll(";7") catch unreachable;
    if (s.fg >= 2) w.print(";38;5;{d}", .{palette[s.fg - 2]}) catch unreachable;
    if (s.bg >= 2) w.print(";48;5;{d}", .{palette[s.bg - 2]}) catch unreachable;
    w.writeAll("m") catch unreachable;
    return w.buffered();
}

fn writeSgr(s: *Screen) Error!void {
    var buf: [48]u8 = undefined;
    try s.writeEscape(s.formatSgr(&buf));
}

fn writeSgrDirect(s: *Screen) Error!void {
    var buf: [48]u8 = undefined;
    try s.out.writeAll(s.formatSgr(&buf));
}

/// Reads a line of input into `buf`, returning null at end of input.
pub fn readLine(s: *Screen, buf: []u8) Error!?[]u8 {
    try s.flushWord();
    if (s.restore_lower) try s.moveLower();
    if (s.ansi) try s.out.print("\x1b[0;38;5;{d}m", .{input_fg});
    try s.out.flush();

    // Keys left over from a piped line are discarded, as in dumb Frotz.
    s.keys_pos = s.keys_len;
    const raw = s.in.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => s.in.buffered(),
        else => return err,
    };
    if (s.ansi) try s.writeSgrDirect();
    const line_raw = raw orelse return null;
    const line = std.mem.trimEnd(u8, line_raw, "\r");
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);

    if (s.echo) {
        try s.writeLower(buf[0..n]);
        try s.writeLower(if (s.ansi) "\r\n" else "\n");
    }
    s.col = 0;
    if (s.lower_row < s.height) s.lower_row += 1;
    s.lines_since_input = 0;
    return buf[0..n];
}

/// Reads a single keypress as a ZSCII code, returning null at end of input.
pub fn readKey(s: *Screen) Error!?u8 {
    try s.flushWord();
    if (s.restore_lower) try s.moveLower();
    try s.out.flush();
    s.lines_since_input = 0;

    if (!s.tty_input) {
        // Piped input is read a line at a time and handed out one key per
        // call, an empty line being Return. This matches dumb Frotz, so
        // walkthrough scripts behave the same in both.
        if (s.keys_pos == s.keys_len) {
            const raw = s.in.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => s.in.buffered(),
                else => return err,
            };
            const line = std.mem.trimEnd(u8, raw orelse return null, "\r");
            if (line.len == 0) return 13;
            s.keys_len = @min(line.len, s.keys.len);
            @memcpy(s.keys[0..s.keys_len], line[0..s.keys_len]);
            s.keys_pos = 0;
        }
        s.keys_pos += 1;
        return s.keys[s.keys_pos - 1];
    }

    const fd = Io.File.stdin().handle;
    const saved = try posix.tcgetattr(fd);
    var raw = saved;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@backingInt(posix.V.MIN)] = 1;
    raw.cc[@backingInt(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .NOW, raw);
    defer posix.tcsetattr(fd, .NOW, saved) catch {};

    const c = s.in.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    return switch (c) {
        '\r', '\n' => 13,
        127, 8 => 8,
        0x1b => blk: {
            const b1 = s.in.takeByte() catch break :blk 27;
            if (b1 != '[' and b1 != 'O') break :blk 27;
            const b2 = s.in.takeByte() catch break :blk 27;
            break :blk switch (b2) {
                'A' => 129,
                'B' => 130,
                'D' => 131,
                'C' => 132,
                else => 27,
            };
        },
        else => c,
    };
}
