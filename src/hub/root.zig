//! One game, many inputs: the keyboard and the web.

pub const Hub = @import("Hub.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
