//! What the machine draws on and reads from: windows, styles, the status
//! line and input. A context pointer and a table of functions, like
//! `std.Io`; `from` builds one from any type with these methods.

const Display = @This();

context: *anyopaque,
vtable: *const VTable,

/// Every display's errors: writing failed (for example, a closed pipe), or
/// anything else.
pub const Error = error{ WriteFailed, ReadFailed };

/// What the display can do, for the story header.
pub const Capabilities = struct {
    /// Text styles and colors.
    styles: bool,
    width: u16,
    height: u16,
    /// Someone is typing at a terminal, so end-of-game prompts are shown.
    interactive: bool = false,
};

pub const VTable = struct {
    print: *const fn (context: *anyopaque, cp: u21) Error!void,
    setWindow: *const fn (context: *anyopaque, window: u8) Error!void,
    splitWindow: *const fn (context: *anyopaque, lines: u16) Error!void,
    eraseWindow: *const fn (context: *anyopaque, which: i16) Error!void,
    eraseLine: *const fn (context: *anyopaque) Error!void,
    setCursor: *const fn (context: *anyopaque, row: u16, col: u16) Error!void,
    getCursor: *const fn (context: *anyopaque) [2]u16,
    setStyle: *const fn (context: *anyopaque, style: u8) Error!void,
    setColor: *const fn (context: *anyopaque, fg: u16, bg: u16) Error!void,
    setBuffered: *const fn (context: *anyopaque, on: bool) Error!void,
    drawStatus: *const fn (context: *anyopaque, left: []const u8, right: []const u8) Error!void,
    readLine: *const fn (context: *anyopaque, buf: []u8) Error!?[]u8,
    readKey: *const fn (context: *anyopaque) Error!?u8,
    capabilities: *const fn (context: *anyopaque) Capabilities,
};

/// Text styles, as `set_text_style` numbers them.
pub const Style = struct {
    pub const reverse = 1;
    pub const bold = 2;
    pub const italic = 4;
    pub const fixed = 8;
};

/// Prints one Unicode character to the current window.
pub fn print(d: Display, cp: u21) Error!void {
    return d.vtable.print(d.context, cp);
}

pub fn setWindow(d: Display, window: u8) Error!void {
    return d.vtable.setWindow(d.context, window);
}

pub fn splitWindow(d: Display, lines: u16) Error!void {
    return d.vtable.splitWindow(d.context, lines);
}

pub fn eraseWindow(d: Display, which: i16) Error!void {
    return d.vtable.eraseWindow(d.context, which);
}

pub fn eraseLine(d: Display) Error!void {
    return d.vtable.eraseLine(d.context);
}

pub fn setCursor(d: Display, row: u16, col: u16) Error!void {
    return d.vtable.setCursor(d.context, row, col);
}

pub fn getCursor(d: Display) [2]u16 {
    return d.vtable.getCursor(d.context);
}

pub fn setStyle(d: Display, style: u8) Error!void {
    return d.vtable.setStyle(d.context, style);
}

/// Sets colors using Z-machine color numbers (0 = unchanged, 1 = default).
pub fn setColor(d: Display, fg: u16, bg: u16) Error!void {
    return d.vtable.setColor(d.context, fg, bg);
}

pub fn setBuffered(d: Display, on: bool) Error!void {
    return d.vtable.setBuffered(d.context, on);
}

/// Draws the version 1-3 status line.
pub fn drawStatus(d: Display, left: []const u8, right: []const u8) Error!void {
    return d.vtable.drawStatus(d.context, left, right);
}

/// Reads a line of input into `buf`, returning null at end of input.
pub fn readLine(d: Display, buf: []u8) Error!?[]u8 {
    return d.vtable.readLine(d.context, buf);
}

/// Reads a single keypress as a ZSCII code, returning null at end of input.
pub fn readKey(d: Display) Error!?u8 {
    return d.vtable.readKey(d.context);
}

pub fn capabilities(d: Display) Capabilities {
    return d.vtable.capabilities(d.context);
}

/// A display drawn by `impl`, a pointer to a type with the methods above.
/// Its errors may be any: `WriteFailed` stays, and the rest become
/// `ReadFailed`.
pub fn from(impl: anytype) Display {
    const T = @typeInfo(@TypeOf(impl)).pointer.child;
    const gen = struct {
        fn cast(context: *anyopaque) *T {
            return @ptrCast(@alignCast(context));
        }
        fn map(err: anyerror) Error {
            return if (err == error.WriteFailed) error.WriteFailed else error.ReadFailed;
        }
        fn print(c: *anyopaque, cp: u21) Error!void {
            return T.print(cast(c), cp) catch |err| map(err);
        }
        fn setWindow(c: *anyopaque, window: u8) Error!void {
            return T.setWindow(cast(c), window) catch |err| map(err);
        }
        fn splitWindow(c: *anyopaque, lines: u16) Error!void {
            return T.splitWindow(cast(c), lines) catch |err| map(err);
        }
        fn eraseWindow(c: *anyopaque, which: i16) Error!void {
            return T.eraseWindow(cast(c), which) catch |err| map(err);
        }
        fn eraseLine(c: *anyopaque) Error!void {
            return T.eraseLine(cast(c)) catch |err| map(err);
        }
        fn setCursor(c: *anyopaque, row: u16, col: u16) Error!void {
            return T.setCursor(cast(c), row, col) catch |err| map(err);
        }
        fn getCursor(c: *anyopaque) [2]u16 {
            return T.getCursor(cast(c));
        }
        fn setStyle(c: *anyopaque, style: u8) Error!void {
            return T.setStyle(cast(c), style) catch |err| map(err);
        }
        fn setColor(c: *anyopaque, fg: u16, bg: u16) Error!void {
            return T.setColor(cast(c), fg, bg) catch |err| map(err);
        }
        fn setBuffered(c: *anyopaque, on: bool) Error!void {
            return T.setBuffered(cast(c), on) catch |err| map(err);
        }
        fn drawStatus(c: *anyopaque, left: []const u8, right: []const u8) Error!void {
            return T.drawStatus(cast(c), left, right) catch |err| map(err);
        }
        fn readLine(c: *anyopaque, buf: []u8) Error!?[]u8 {
            return T.readLine(cast(c), buf) catch |err| map(err);
        }
        fn readKey(c: *anyopaque) Error!?u8 {
            return T.readKey(cast(c)) catch |err| map(err);
        }
        fn capabilities(c: *anyopaque) Capabilities {
            return T.capabilities(cast(c));
        }
    };
    return .{ .context = impl, .vtable = &.{
        .print = gen.print,
        .setWindow = gen.setWindow,
        .splitWindow = gen.splitWindow,
        .eraseWindow = gen.eraseWindow,
        .eraseLine = gen.eraseLine,
        .setCursor = gen.setCursor,
        .getCursor = gen.getCursor,
        .setStyle = gen.setStyle,
        .setColor = gen.setColor,
        .setBuffered = gen.setBuffered,
        .drawStatus = gen.drawStatus,
        .readLine = gen.readLine,
        .readKey = gen.readKey,
        .capabilities = gen.capabilities,
    } };
}
