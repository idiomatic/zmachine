//! The object inspector and map: what it watches, and its routes.

pub const Map = @import("Map.zig");
pub const Export = @import("Export.zig");
pub const Inspector = @import("Inspector.zig");
pub const routes = @import("routes.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
