//! The object inspector and map.

pub const Inspector = @import("Inspector.zig");
pub const html = @embedFile("inspector.html");

test {
    @import("std").testing.refAllDecls(@This());
}
