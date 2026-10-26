//! A small embedded HTTP server for the live object inspector and map.
//!
//! Routes:
//!   GET /                 the inspector page
//!   GET /state?since=N    the latest snapshot, held open until it is newer
//!                         than generation N (long polling)

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const Inspector = @import("Inspector.zig");

const index_html = @embedFile("inspector.html");

/// How long a long-poll request waits for a new snapshot.
const poll_timeout_ms = 20_000;
const poll_interval_ms = 100;

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    inspector: *Inspector,
    listener: net.Server,

    /// Binds to `port` on the loopback interface.
    pub fn listen(gpa: Allocator, io: Io, inspector: *Inspector, port: u16) !Server {
        const address: net.IpAddress = .{ .ip4 = .loopback(port) };
        return .{
            .gpa = gpa,
            .io = io,
            .inspector = inspector,
            .listener = try address.listen(io, .{ .reuse_address = true }),
        };
    }

    /// Accepts connections forever, one thread per connection.
    pub fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch |err| {
                std.log.warn("web: accept failed: {s}", .{@errorName(err)});
                continue;
            };
            const thread = std.Thread.spawn(.{}, handle, .{ s, stream }) catch {
                stream.close(s.io);
                continue;
            };
            thread.detach();
        }
    }

    fn handle(s: *Server, stream: net.Stream) void {
        defer stream.close(s.io);
        respond(s, stream) catch {};
    }

    fn respond(s: *Server, stream: net.Stream) !void {
        var read_buf: [4096]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(s.io, &read_buf);
        var writer = stream.writer(s.io, &write_buf);
        const r = &reader.interface;
        const w = &writer.interface;

        const request_line = (try r.takeDelimiter('\n')) orelse return;
        var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, request_line, "\r"), ' ');
        const method = parts.next() orelse return;
        const target = try s.gpa.dupe(u8, parts.next() orelse return);
        defer s.gpa.free(target);
        // Skip the headers.
        while (try r.takeDelimiter('\n')) |line| {
            if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
        }

        if (!std.mem.eql(u8, method, "GET")) {
            return sendResponse(w, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        }
        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. query_start orelse target.len];
        const query = if (query_start) |q| target[q + 1 ..] else "";

        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            return sendResponse(w, "200 OK", "text/html; charset=utf-8", index_html);
        }
        if (std.mem.eql(u8, path, "/state")) {
            const since = parseSince(query);
            var waited: u32 = 0;
            while (true) {
                if (try s.inspector.latest(s.gpa, since)) |json| {
                    defer s.gpa.free(json);
                    return sendResponse(w, "200 OK", "application/json", json);
                }
                if (waited >= poll_timeout_ms) {
                    return sendResponse(w, "204 No Content", "application/json", "");
                }
                try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                waited += poll_interval_ms;
            }
        }
        return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
    }
};

fn parseSince(query: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "since=")) {
            return std.fmt.parseInt(u64, pair["since=".len..], 10) catch 0;
        }
    }
    return 0;
}

fn sendResponse(w: *Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try w.print(
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    );
    try w.writeAll(body);
    try w.flush();
}

test parseSince {
    try std.testing.expectEqual(@as(u64, 42), parseSince("since=42"));
    try std.testing.expectEqual(@as(u64, 7), parseSince("x=1&since=7"));
    try std.testing.expectEqual(@as(u64, 0), parseSince(""));
}
