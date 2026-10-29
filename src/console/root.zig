//! The terminal UI: xterm-256color escapes or plain text.

pub const InputSource = @import("InputSource.zig");
pub const Screen = @import("Screen.zig");
pub const TerminalInput = @import("TerminalInput.zig");
pub const terminal = @import("terminal.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("TestTerminal.zig");
    _ = @import("test.zig");
}
