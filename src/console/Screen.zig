//! Terminal front end: the status line, upper and lower windows, text
//! styles and keyboard input, rendered with xterm-256color escape sequences.
//!
//! The lower window is a scroll region at the bottom of the terminal; the
//! status line (version 3) and the upper window sit above it and are drawn
//! with absolute cursor positioning. When stdout is not a terminal, output
//! degrades to plain word-wrapped text.

const std = @import("std");
const Io = std.Io;
const terminal = @import("terminal.zig");
const Password = @import("poly").Password;
const Remote = @import("hub").Remote;

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
/// Input shared with a remote partner; when set, the keyboard is read
/// through it instead of `in`.
remote: ?*Remote = null,
looks: Looks = .{},
/// What the lower window's current line holds, escapes included, so a
/// prompt can be shown again after a console command.
line_text: [256]u8 = undefined,
line_len: usize = 0,

pub const Error = Io.Writer.Error || Io.Reader.Error || error{StreamTooLong} || terminal.Error;

pub const Style = struct {
    pub const reverse = 1;
    pub const bold = 2;
    pub const italic = 4;
    pub const fixed = 8;
};

/// 256-color palette entries for the Z-machine colors 2-12.
const palette = [_]u8{ 16, 160, 34, 220, 33, 164, 44, 255, 250, 244, 238 };

/// How one part of the display is drawn: text attributes and colors.
/// Fields left null are unset: drawn as off and in the terminal's own
/// colors, or, when one look is laid over another, taken from the one
/// below.
pub const Look = struct {
    bold: ?bool = null,
    dim: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    reverse: ?bool = null,
    fg: ?Color = null,
    bg: ?Color = null,

    pub const Color = union(enum) {
        /// The terminal's own color.
        default,
        /// One of the 16 colors the terminal's theme defines, which suit
        /// its background: 0-7 are `names`, 8-15 their bright forms.
        theme: u4,
        /// An entry in the 256-color palette.
        index: u8,
        rgb: [3]u8,

        const names = [_][]const u8{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" };

        /// Parses a color name such as `blue` or `bright-blue`, a
        /// 256-color number, `#rrggbb` or `default`.
        fn parse(word: []const u8) error{InvalidStyle}!Color {
            if (word.len == 0 or std.mem.eql(u8, word, "default")) return .default;
            const bright = std.mem.startsWith(u8, word, "bright-");
            const name = if (bright) word["bright-".len..] else word;
            for (names, 0..) |n, i| {
                if (std.mem.eql(u8, name, n)) return .{ .theme = @intCast(if (bright) i + 8 else i) };
            }
            if (bright) return error.InvalidStyle;
            if (word[0] == '#') {
                var rgb: [3]u8 = undefined;
                if (word.len != 7) return error.InvalidStyle;
                _ = std.fmt.hexToBytes(&rgb, word[1..]) catch return error.InvalidStyle;
                return .{ .rgb = rgb };
            }
            return .{ .index = std.fmt.parseInt(u8, word, 10) catch return error.InvalidStyle };
        }

        /// Writes the SGR parameters for this color; `base` is 30 for the
        /// foreground and 40 for the background.
        fn write(c: Color, w: *Io.Writer, base: u8) Io.Writer.Error!void {
            switch (c) {
                .default => {},
                .theme => |n| try w.print(";{d}", .{if (n < 8) base + n else base + 60 + (n - 8)}),
                .index => |n| try w.print(";{d};5;{d}", .{ base + 8, n }),
                .rgb => |rgb| try w.print(";{d};2;{d};{d};{d}", .{ base + 8, rgb[0], rgb[1], rgb[2] }),
            }
        }
    };

    const attributes = .{ .{ "bold", "1" }, .{ "dim", "2" }, .{ "italic", "3" }, .{ "underline", "4" }, .{ "reverse", "7" } };

    /// No attributes, in the terminal's own colors, even when laid over
    /// another look.
    const plain: Look = .{
        .bold = false,
        .dim = false,
        .italic = false,
        .underline = false,
        .reverse = false,
        .fg = .default,
        .bg = .default,
    };

    /// Parses a spec such as `bold+white/blue`: attributes and a color
    /// (`fg`, `fg/bg` or `/bg`) joined by `+`. `plain` is no attributes in
    /// the terminal's own colors.
    pub fn parse(spec: []const u8) error{InvalidStyle}!Look {
        var look: Look = .{};
        var it = std.mem.splitScalar(u8, spec, '+');
        next: while (it.next()) |word| {
            if (std.mem.eql(u8, word, "plain")) {
                look = .plain;
                continue;
            }
            inline for (attributes) |attribute| {
                if (std.mem.eql(u8, word, attribute[0])) {
                    @field(look, attribute[0]) = true;
                    continue :next;
                }
            }
            if (word.len == 0) return error.InvalidStyle;
            // An empty side of `fg/bg` leaves that color unset.
            const slash = std.mem.indexOfScalar(u8, word, '/');
            const fg = word[0 .. slash orelse word.len];
            if (fg.len > 0) look.fg = try .parse(fg);
            if (slash) |i| {
                if (i + 1 < word.len) look.bg = try .parse(word[i + 1 ..]);
            }
        }
        return look;
    }

    /// This look laid over `base`: what it sets wins, and the rest comes
    /// from `base`.
    fn over(top: Look, base: Look) Look {
        var look = base;
        inline for (comptime std.meta.fieldNames(Look)) |name| {
            if (@field(top, name)) |value| @field(look, name) = value;
        }
        return look;
    }

    /// The escape sequence that resets the terminal's style and then sets
    /// this look.
    fn sgr(look: Look, buf: *[64]u8) []const u8 {
        var w: Io.Writer = .fixed(buf);
        w.writeAll("\x1b[0") catch unreachable;
        inline for (attributes) |attribute| {
            if (@field(look, attribute[0]) orelse false) w.writeAll(";" ++ attribute[1]) catch unreachable;
        }
        if (look.fg) |fg| fg.write(&w, 30) catch unreachable;
        if (look.bg) |bg| bg.write(&w, 40) catch unreachable;
        w.writeAll("m") catch unreachable;
        return w.buffered();
    }
};

/// The looks of the parts of the display, chosen with `--style`.
pub const Looks = struct {
    /// Input, both the line being typed and earlier ones. Teal reads well
    /// on light and dark backgrounds alike.
    input: Look = .{ .fg = .{ .index = 30 } },
    /// Laid over `input` for the line being typed.
    currentinput: Look = .{ .bold = true },
    /// Laid over `input` for lines already entered.
    priorinput: Look = .{},
    /// The prompt: the last word printed before a line of input, such as `>`.
    prompt: Look = .{},
    /// The version 3 status line.
    header: Look = .{ .bold = true, .fg = .{ .index = 231 }, .bg = .{ .index = 24 } },
    /// The `[MORE]` prompt.
    more: Look = .{ .reverse = true },

    pub const presets = [_]struct { []const u8, Looks }{
        .{ "default", .{} },
        // The original colors, for dark backgrounds.
        .{ "dark", .{ .input = .{ .fg = .{ .index = 222 } } } },
        .{ "light", .{ .input = .{ .fg = .{ .theme = 4 } } } },
        // No colors at all.
        .{ "mono", .{ .input = .{ .bold = true }, .prompt = .{ .bold = true }, .header = .{ .reverse = true } } },
        .{ "plain", .{ .input = .{}, .header = .{}, .more = .{} } },
    };

    /// Applies a comma-separated list of preset names and `part=spec`
    /// settings in order, such as `mono,prompt=bold+cyan`. `status` is
    /// another name for `header`.
    pub fn apply(looks: *Looks, list: []const u8) error{InvalidStyle}!void {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        next: while (it.next()) |raw| {
            const item = std.mem.trim(u8, raw, " ");
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse {
                for (presets) |preset| {
                    if (std.mem.eql(u8, item, preset[0])) {
                        looks.* = preset[1];
                        continue :next;
                    }
                }
                return error.InvalidStyle;
            };
            const part = if (std.mem.eql(u8, item[0..eq], "status")) "header" else item[0..eq];
            const look: Look = try .parse(item[eq + 1 ..]);
            inline for (comptime std.meta.fieldNames(Looks)) |name| {
                if (std.mem.eql(u8, part, name)) {
                    @field(looks, name) = look;
                    continue :next;
                }
            }
            return error.InvalidStyle;
        }
    }
};

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
        if (terminal.size()) |size| {
            s.width = size[0];
            s.height = size[1];
        }
    }
    s.lower_row = s.height;
    return s;
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
    s.trackLine(bytes);
}

fn trackLine(s: *Screen, bytes: []const u8) void {
    if (std.mem.indexOfScalar(u8, bytes, '\n') != null) {
        s.line_len = 0;
        return;
    }
    const n = @min(bytes.len, s.line_text.len - s.line_len);
    @memcpy(s.line_text[s.line_len..][0..n], bytes[0..n]);
    s.line_len += n;
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
    for (0..n) |_| s.trackLine(" ");
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
    var buf: [64]u8 = undefined;
    try s.writeLower(s.looks.more.sgr(&buf));
    try s.writeLower("[MORE]\x1b[0m");
    if (s.remote) |r| {
        // A command from the remote partner also continues.
        try s.out.flush();
        const raw: terminal.RawMode = try .enter();
        defer raw.leave();
        while (!r.pending()) {
            switch (r.takeKey(&s.keys, false, false)) {
                .none => s.pause(),
                else => break,
            }
        }
    } else {
        // Not readKey, which would print the pending word after [MORE],
        // only for it to be cleared with it.
        try s.out.flush();
        const raw: terminal.RawMode = try .enter();
        defer raw.leave();
        if (s.in.takeByte()) |c| {
            _ = decodeKey(c, s.in);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }
    try s.out.writeAll("\r\x1b[K");
    s.line_len = 0;
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
    if (s.window == 0) if (s.remote) |r| r.capture(bytes);

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
    if (s.remote) |r| r.setStatus(left, right);
    if (!s.ansi or s.status_rows == 0) return;
    // The pending word stays pending, so the prompt can still be styled.
    var buf: [64]u8 = undefined;
    try s.out.print("\x1b[1;1H{s} ", .{s.looks.header.sgr(&buf)});
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

/// Sets colors using Z-machine color numbers (0 = unchanged, 1 = default).
pub fn setColor(s: *Screen, fg: u16, bg: u16) Error!void {
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
    var sgr: [64]u8 = undefined;
    // A plain prompt keeps the game's own style.
    const prompt_sgr = s.looks.prompt.sgr(&sgr);
    if (s.ansi and !std.mem.eql(u8, prompt_sgr, "\x1b[0m")) s.stylePrompt(prompt_sgr);
    try s.flushWord();
    if (s.restore_lower) try s.moveLower();
    const start_col = s.col;
    // The prompt, to show again after a console command.
    var prompt_buf: [256]u8 = undefined;
    const prompt = prompt_buf[0..s.line_len];
    @memcpy(prompt, s.line_text[0..s.line_len]);
    var current_buf: [64]u8 = undefined;
    var prior_buf: [64]u8 = undefined;
    const current_sgr = s.looks.currentinput.over(s.looks.input).sgr(&current_buf);
    const prior_sgr = s.looks.priorinput.over(s.looks.input).sgr(&prior_buf);
    if (s.ansi) try s.out.writeAll(current_sgr);
    try s.out.flush();
    var typed_ahead = s.typedAhead();

    // Keys left over from a piped line are discarded, as in dumb Frotz.
    s.keys_pos = s.keys_len;
    var remote_line = false;
    const line = if (s.remote) |r| line: {
        r.waiting();
        while (true) switch (r.takeLine(buf)) {
            .none => s.pause(),
            .closed => break :line null,
            .keyboard => |line| break :line line,
            .remote => |line| {
                remote_line = true;
                break :line line;
            },
            .console => |command| {
                try s.consoleCommand(r, command);
                // Show the prompt again for the next line.
                try s.writeLower(prompt);
                s.col = start_col;
                if (s.ansi) try s.out.writeAll(current_sgr);
                try s.out.flush();
                typed_ahead = s.typedAhead();
            },
        };
    } else line: {
        const raw = s.in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => s.in.buffered(),
            else => return err,
        };
        const line = std.mem.trimEnd(u8, raw orelse break :line null, "\r");
        const n = @min(line.len, buf.len);
        @memcpy(buf[0..n], line[0..n]);
        break :line buf[0..n];
    };
    const n = (line orelse {
        if (s.ansi) try s.writeSgrDirect();
        return null;
    }).len;

    if (s.echo or remote_line) {
        // Echoed lines are already entered, so they take the prior look.
        if (s.ansi) try s.out.writeAll(prior_sgr);
        try s.writeLower(buf[0..n]);
        try s.writeLower(if (s.ansi) "\r\n" else "\n");
    } else if (s.ansi and !typed_ahead and !std.mem.eql(u8, current_sgr, prior_sgr)) {
        // The terminal echoed the line as it was typed; redraw it in the
        // prior look, on the rows above the cursor it took up.
        const width = start_col + displayWidth(buf[0..n]);
        const rows = @max(1, (width + s.width - 1) / s.width);
        try s.out.print("\x1b7\x1b[{d}A\r", .{rows});
        if (start_col > 0) try s.out.print("\x1b[{d}C", .{start_col});
        try s.out.writeAll(prior_sgr);
        try s.out.writeAll(buf[0..n]);
        // Clear the rest of the last row in the game's style, in case
        // wrapping scrolled it in with the input's background, unless the
        // line filled it (erasing there would take the last character).
        if (width % s.width != 0) {
            try s.writeSgrDirect();
            try s.out.writeAll("\x1b[K");
        }
        try s.out.writeAll("\x1b8");
    }
    if (s.ansi) {
        // Return may have scrolled the screen while the input look was set,
        // filling the new row with its background; clear it in the game's.
        try s.writeSgrDirect();
        try s.out.writeAll("\x1b[K");
    }
    s.col = 0;
    if (s.lower_row < s.height) s.lower_row += 1;
    s.lines_since_input = 0;
    return buf[0..n];
}

/// Whether keys were typed before the game asked for the line, so the
/// terminal echoed them somewhere else, or not at all.
fn typedAhead(s: *Screen) bool {
    if (!s.tty_input) return false;
    if (s.remote) |r| return r.keyboardPending();
    return s.in.bufferedLen() > 0 or terminal.inputPending();
}

/// Carries out a console command typed in place of a line of input, which
/// the terminal has already echoed, and notes the outcome on a line of its
/// own. The game never sees it.
fn consoleCommand(s: *Screen, r: *Remote, command: Remote.ConsoleCommand) Error!void {
    if (s.echo) {
        try s.writeLower("/");
        try s.writeLower(@tagName(command));
        try s.writeLower(if (s.ansi) "\r\n" else "\n");
    } else {
        s.line_len = 0;
    }
    if (s.lower_row < s.height) s.lower_row += 1;
    s.col = 0;
    const note: ?[]const u8 = switch (command) {
        .lead => if (r.leads(.console))
            "The console already leads."
        else if (r.passLeadership(.console, "console")) |_|
            "The console leads again."
        else |_|
            "Could not take back the leadership.",
        .password => try s.consolePassword(r),
        .showpassword => try s.showPassword(r),
    };
    if (note) |text| try s.consoleNote(text);
}

/// Writes a console note in brackets, on a line of its own.
fn consoleNote(s: *Screen, text: []const u8) Error!void {
    if (s.ansi) try s.out.writeAll("\x1b[0;2m");
    try s.writeLower("[");
    try s.writeLower(text);
    try s.writeLower("]");
    if (s.ansi) try s.writeSgrDirect();
    try s.writeLower(if (s.ansi) "\r\n" else "\n");
    if (s.lower_row < s.height) s.lower_row += 1;
}

/// `/password`: asks for a new password without echoing it; an empty one
/// generates a new password.
fn consolePassword(s: *Screen, r: *Remote) Error!?[]const u8 {
    if (!r.listening()) return "There is no password without --listen.";
    try s.writeLower("New password (Return to generate one): ");
    try s.out.flush();
    var text: [Password.max_len + 1]u8 = undefined;
    var len: usize = 0;
    if (s.tty_input) {
        const raw: terminal.RawMode = try .enter();
        defer raw.leave();
        while (true) switch (r.takeKey(&s.keys, false, false)) {
            .none => s.pause(),
            .closed => break,
            .line => break,
            .key => |c| switch (c) {
                '\r', '\n' => break,
                127, 8 => len -|= 1,
                else => if (c >= 0x20 and len < text.len) {
                    text[len] = c;
                    len += 1;
                },
            },
        };
    } else {
        while (true) switch (r.takeKey(&s.keys, true, false)) {
            .none => s.pause(),
            .line => |line| {
                len = @min(line.len, text.len);
                @memcpy(text[0..len], line[0..len]);
                break;
            },
            else => break,
        };
    }
    try s.writeLower(if (s.ansi) "\r\n" else "\n");
    if (s.lower_row < s.height) s.lower_row += 1;
    r.changePassword(.console, if (len > 0) text[0..len] else null) catch |err| return switch (err) {
        error.NotAllowed => "That password is too long.",
        else => "Could not change the password.",
    };
    return if (len > 0)
        "Password changed. Remote players need the new one."
    else
        "New password made; type /showpassword to see it. Remote players need the new one.";
}

/// `/showpassword`: shows the password on the bottom row until a key is
/// pressed, then clears the row. The terminal has just echoed the command,
/// so the cursor is on a fresh line and any rows below it are blank. The
/// password never scrolls into the terminal's history.
fn showPassword(s: *Screen, r: *Remote) Error!?[]const u8 {
    if (!r.listening()) return "There is no password without --listen.";
    if (!s.ansi) return "The password shows only on a full-screen terminal; copy an invite link with ⚭ on the play page here.";
    var buf: [Password.max_len]u8 = undefined;
    const password = r.readPassword(.console, &buf, "showed") catch return "Could not read the password.";
    var line_buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, " Password: {s}   (press a key to hide it)", .{password}) catch password;
    var sgr: [64]u8 = undefined;
    // Save the cursor, draw on the bottom row in the status line's look,
    // and fill the rest of the row.
    try s.out.print("\x1b7\x1b[{d};1H{s}{s}", .{ s.height, s.looks.header.sgr(&sgr), line });
    try s.out.splatByteAll(' ', s.width -| @as(u16, @intCast(@min(line.len, s.width))));
    try s.out.writeAll("\x1b[0m");
    try s.out.flush();
    try s.waitForKey(r);
    try s.out.print("\x1b[{d};1H\x1b[2K\x1b8", .{s.height});
    try s.writeSgrDirect();
    s.restore_lower = true;
    return null;
}

fn waitForKey(s: *Screen, r: *Remote) Error!void {
    const raw: ?terminal.RawMode = if (s.tty_input) try .enter() else null;
    defer if (raw) |mode| mode.leave();
    while (r.takeKey(&s.keys, !s.tty_input, false) == .none) s.pause();
}

/// Puts an escape sequence in front of the pending word, the prompt. The
/// input style that follows the prompt resets it.
fn stylePrompt(s: *Screen, sgr: []const u8) void {
    if (s.word_width == 0 or s.word_len + sgr.len > s.word.len) return;
    std.mem.copyBackwards(u8, s.word[sgr.len..][0..s.word_len], s.word[0..s.word_len]);
    @memcpy(s.word[0..sgr.len], sgr);
    s.word_len += sgr.len;
}

/// Reads a single keypress as a ZSCII code, returning null at end of input.
pub fn readKey(s: *Screen) Error!?u8 {
    try s.flushWord();
    if (s.restore_lower) try s.moveLower();
    try s.out.flush();
    s.lines_since_input = 0;

    if (s.remote) |r| return s.readRemoteKey(r);
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

    const raw: terminal.RawMode = try .enter();
    defer raw.leave();

    const c = s.in.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    return decodeKey(c, s.in);
}

/// Reads a key from the keyboard or, a line at a time, from the remote
/// partner.
fn readRemoteKey(s: *Screen, r: *Remote) Error!?u8 {
    if (s.keys_pos == s.keys_len) {
        r.waiting();
        const raw: ?terminal.RawMode = if (s.tty_input) try .enter() else null;
        defer if (raw) |mode| mode.leave();
        while (true) switch (r.takeKey(&s.keys, !s.tty_input, true)) {
            .none => s.pause(),
            .closed => return null,
            .key => |c| return decodeKey(c, RemoteBytes{ .screen = s, .remote = r }),
            .line => |line| {
                if (line.len == 0) return 13;
                s.keys_len = line.len;
                s.keys_pos = 0;
                break;
            },
        };
    }
    s.keys_pos += 1;
    return s.keys[s.keys_pos - 1];
}

/// The rest of an escape sequence from the keyboard thread, which sends
/// it at once.
const RemoteBytes = struct {
    screen: *Screen,
    remote: *Remote,

    fn takeByte(b: RemoteBytes) !u8 {
        for (0..5) |_| {
            if (b.remote.takeKeyboardByte()) |c| return c;
            b.screen.pause();
        }
        return error.EndOfStream;
    }
};

/// Translates a raw keypress, and any escape sequence after it read from
/// `rest`, to ZSCII.
fn decodeKey(c: u8, rest: anytype) u8 {
    return switch (c) {
        '\r', '\n' => 13,
        127, 8 => 8,
        0x1b => blk: {
            const b1 = rest.takeByte() catch break :blk 27;
            if (b1 != '[' and b1 != 'O') break :blk 27;
            const b2 = rest.takeByte() catch break :blk 27;
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

/// Waits briefly before looking for input again.
fn pause(s: *Screen) void {
    s.io.sleep(.fromMilliseconds(10), .awake) catch {};
}

test "Looks.apply" {
    var looks: Looks = .{};
    try looks.apply("mono, prompt=bold+cyan,status=bold+white/blue");
    try std.testing.expectEqual(Look{ .bold = true }, looks.input);
    try std.testing.expectEqual(Look{ .bold = true, .fg = .{ .theme = 6 } }, looks.prompt);
    try std.testing.expectEqual(Look{ .bold = true, .fg = .{ .theme = 7 }, .bg = .{ .theme = 4 } }, looks.header);
    try std.testing.expectEqual(Look{ .reverse = true }, looks.more);

    try looks.apply("input=plain,more=/bright-red");
    try std.testing.expectEqual(Look.plain, looks.input);
    try std.testing.expectEqual(Look{ .bg = .{ .theme = 9 } }, looks.more);

    try std.testing.expectError(error.InvalidStyle, looks.apply("neon"));
    try std.testing.expectError(error.InvalidStyle, looks.apply("footer=bold"));
    try std.testing.expectError(error.InvalidStyle, looks.apply("input=blink"));
    try std.testing.expectError(error.InvalidStyle, looks.apply("input=bold+"));
    try std.testing.expectError(error.InvalidStyle, looks.apply("input=#12345"));
    try std.testing.expectError(error.InvalidStyle, looks.apply("input=256"));
}

test "current and prior input are laid over input" {
    var buf: [64]u8 = undefined;
    var looks: Looks = .{};
    // In either order, the line being typed is bold and red, and earlier
    // lines are only red.
    for ([_][]const u8{ "currentinput=bold,input=red", "input=red,currentinput=bold" }) |list| {
        try looks.apply(list);
        try std.testing.expectEqualStrings("\x1b[0;1;31m", looks.currentinput.over(looks.input).sgr(&buf));
        try std.testing.expectEqualStrings("\x1b[0;31m", looks.priorinput.over(looks.input).sgr(&buf));
        looks = .{};
    }
    // A color or `plain` replaces what input sets.
    try looks.apply("input=bold+red,priorinput=dim+blue,currentinput=plain");
    try std.testing.expectEqualStrings("\x1b[0;1;2;34m", looks.priorinput.over(looks.input).sgr(&buf));
    try std.testing.expectEqualStrings("\x1b[0m", looks.currentinput.over(looks.input).sgr(&buf));
    // A preset resets them.
    try looks.apply("default");
    try std.testing.expectEqual(Look{}, looks.priorinput);
}

test "Look.sgr" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[0m", (Look{}).sgr(&buf));
    const look: Look = try .parse("bold+underline+bright-yellow/#102030");
    try std.testing.expectEqualStrings("\x1b[0;1;4;93;48;2;16;32;48m", look.sgr(&buf));
    const indexed: Look = try .parse("reverse+222/24");
    try std.testing.expectEqualStrings("\x1b[0;7;38;5;222;48;5;24m", indexed.sgr(&buf));
}
