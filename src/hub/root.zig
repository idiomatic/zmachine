//! One game, many inputs: the keyboard and the web.

pub const Remote = @import("Remote.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
