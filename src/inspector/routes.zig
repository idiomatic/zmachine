//! The inspector's routes, which the web server guards (this machine only;
//! AI partners only `/state`, when let):
//!
//!   GET /inspector        the inspector page
//!   GET /state?since=N    the latest snapshot, held open until it is newer
//!                         than generation N (long polling)
//!   POST /erase-map       erase the map at the next snapshot
//!
//! Each reply says what to note in the audit log.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Inspector = @import("Inspector.zig");

const page = @embedFile("inspector.html");

/// How long a long-poll request waits for a new snapshot.
const poll_timeout_ms = 20_000;
const poll_interval_ms = 100;

pub const paths = [_][]const u8{ "/inspector", "/state", "/erase-map" };
/// The one AI partners may read, when let.
pub const ai_path = "/state";

pub const Reply = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    log: ?Log = null,
};

/// An audit log entry: opening the inspector or erasing its map, or
/// reading a snapshot.
pub const Log = struct {
    kind: enum { inspector, snapshot },
    detail: []const u8,
    suspicious: bool,
};

/// Answers one of `paths`, or returns null for a method it doesn't take.
pub fn handle(in: *Inspector, arena: Allocator, method: []const u8, path: []const u8, query: []const u8) !?Reply {
    const get = std.mem.eql(u8, method, "GET");
    if (get and std.mem.eql(u8, path, "/inspector")) return .{
        .status = "200 OK",
        .content_type = "text/html; charset=utf-8",
        .body = page,
        .log = .{ .kind = .inspector, .detail = "opened the object inspector", .suspicious = true },
    };
    if (get and std.mem.eql(u8, path, "/state")) {
        const since = parseSince(query);
        var waited: u32 = 0;
        while (true) {
            if (try in.latest(arena, since)) |json| return .{
                .status = "200 OK",
                .content_type = "application/json",
                .body = json,
                .log = .{
                    .kind = .snapshot,
                    .detail = std.fmt.allocPrint(arena, "read the object tree and globals (since {d})", .{since}) catch "",
                    .suspicious = true,
                },
            };
            if (waited >= poll_timeout_ms) return .{ .status = "204 No Content", .content_type = "application/json", .body = "" };
            try in.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
            waited += poll_interval_ms;
        }
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/erase-map")) {
        in.eraseMap();
        return .{
            .status = "204 No Content",
            .content_type = "text/plain",
            .body = "",
            .log = .{ .kind = .inspector, .detail = "erased the inspector's map", .suspicious = false },
        };
    }
    return null;
}

fn parseSince(query: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "since=")) return std.fmt.parseInt(u64, pair["since=".len..], 10) catch 0;
    }
    return 0;
}

test parseSince {
    try std.testing.expectEqual(42, parseSince("since=42"));
    try std.testing.expectEqual(7, parseSince("x=1&since=7"));
    try std.testing.expectEqual(0, parseSince(""));
}
