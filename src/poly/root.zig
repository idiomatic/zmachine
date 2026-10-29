//! The rules of playing together: players, leadership, modes, kicks, the
//! discussion, remote access and the audit log.

pub const Group = @import("Group.zig");
pub const Password = @import("Password.zig");
pub const World = @import("world.zig").World;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test.zig");
}
