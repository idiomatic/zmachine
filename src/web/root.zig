//! The web service: the play page and its routes.

const web = @import("web.zig");
pub const Server = web.Server;
pub const Routes = web.Routes;
pub const Answer = web.Answer;
pub const Mcp = web.Mcp;

test {
    _ = web;
}
