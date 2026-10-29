//! The Z-machine: runs stories, knowing nothing of terminals or the web.

pub const Machine = @import("Machine.zig");
pub const ObjectTable = @import("ObjectTable.zig");
pub const quetzal = @import("quetzal.zig");
pub const zstring = @import("zstring.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
