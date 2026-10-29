//! The Z-machine: runs stories, knowing nothing of terminals or the web.

pub const Display = @import("Display.zig");
pub const Machine = @import("Machine.zig");
pub const ObjectTable = @import("ObjectTable.zig");
pub const RecordingDisplay = @import("RecordingDisplay.zig");
pub const Storage = @import("Storage.zig");
pub const quetzal = @import("quetzal.zig");
pub const zstring = @import("zstring.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test.zig");
}
