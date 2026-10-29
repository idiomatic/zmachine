//! Where the screen's input comes from: the keyboard alone
//! (`TerminalInput`), or the keyboard and the web together. A context
//! pointer and a table of functions, like `std.Io`.
//!
//! Taking input may block, or return `none` when nothing has arrived yet,
//! for the screen to try again shortly.

const InputSource = @This();

context: *anyopaque,
vtable: *const VTable,

pub const Error = error{ReadFailed};

pub const Line = union(enum) {
    /// Nothing yet; wait and try again.
    none,
    /// Input has ended and nothing is left.
    closed,
    /// Typed at the keyboard (and echoed by the terminal, if any).
    keyboard: []u8,
    /// Sent by another player; the screen echoes it.
    web: []u8,
    /// The name of a console command such as `/lead`, typed at the
    /// keyboard; the game never sees it.
    console: []const u8,
};

pub const Key = union(enum) {
    none,
    closed,
    key: u8,
    /// A line whose characters are handed out one key at a time.
    line: []u8,
};

pub const VTable = struct {
    waiting: *const fn (context: *anyopaque) void,
    takeLine: *const fn (context: *anyopaque, buf: []u8) Error!Line,
    takeKey: *const fn (context: *anyopaque, buf: []u8, by_line: bool, web: bool) Error!Key,
    keyboardPending: *const fn (context: *anyopaque) bool,
    takeKeyboardByte: *const fn (context: *anyopaque) ?u8,
    webPending: *const fn (context: *anyopaque) bool,
};

/// The game starts waiting for new input.
pub fn waiting(i: InputSource) void {
    i.vtable.waiting(i.context);
}

/// Takes the next line, copied into `buf`.
pub fn takeLine(i: InputSource, buf: []u8) Error!Line {
    return i.vtable.takeLine(i.context, buf);
}

/// Takes the next key from the keyboard, or a line of keys from the web
/// (with `web`). With `by_line`, keyboard input is piped and arrives as
/// lines too.
pub fn takeKey(i: InputSource, buf: []u8, by_line: bool, web: bool) Error!Key {
    return i.vtable.takeKey(i.context, buf, by_line, web);
}

/// Whether keys have arrived from the keyboard that nothing has taken yet.
pub fn keyboardPending(i: InputSource) bool {
    return i.vtable.keyboardPending(i.context);
}

/// Takes a byte that is arriving from the keyboard, for the rest of an
/// escape sequence; null if none comes.
pub fn takeKeyboardByte(i: InputSource) ?u8 {
    return i.vtable.takeKeyboardByte(i.context);
}

/// Whether a command from the web is waiting.
pub fn webPending(i: InputSource) bool {
    return i.vtable.webPending(i.context);
}
