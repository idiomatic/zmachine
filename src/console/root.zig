//! The terminal UI: xterm-256color escapes or plain text.

pub const Screen = @import("Screen.zig");
pub const terminal = @import("terminal.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
