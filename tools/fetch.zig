//! Downloads a file for the build and checks it against a pinned SHA-256.
//!
//! usage: fetch <url> <sha256-hex> <output>
//!
//! The build uses it for the open-source Zork stories. Its output is cached
//! like any other build step's, so each file is downloaded once.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        try stderr.writeAll("usage: fetch <url> <sha256-hex> <output>\n");
        return 2;
    }
    const url, const want_hex, const output = .{ args[1], args[2], args[3] };

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(arena);
    const result = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |err| {
        try stderr.print("fetch: cannot download {s}: {s}\n", .{ url, @errorName(err) });
        return 1;
    };
    if (result.status != .ok) {
        try stderr.print("fetch: {s} answered {d}\n", .{ url, @backingInt(result.status) });
        return 1;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(body.written(), &digest, .{});
    const got_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &got_hex, want_hex)) {
        try stderr.print("fetch: {s} has SHA-256 {s}, not the pinned {s}\n", .{ url, &got_hex, want_hex });
        return 1;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = body.written() });
    return 0;
}
