//! The rules of playing together.

pub const Password = @import("Password.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
