//! Downloads what local/ holds that can be had again, for `zig build` in
//! local/ and the root build's `zig build stories`.
//!
//! usage: fetch <url> <sha256-hex> <output>
//!        fetch --catalog <catalog-url> <dir>
//!
//! The first form downloads one file and checks it against a pinned
//! SHA-256; the build caches it like any other step's output. The second
//! downloads the catalog's story files (all versions but 6) that aren't in
//! `<dir>` yet, recording each one's SHA-256 in `<dir>/SHA256SUMS` at first
//! download and checking every one against it afterwards.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "--catalog")) {
        try Io.Dir.cwd().createDirPath(io, args[3]);
        const names = try download(arena, init.gpa, io, stderr, args[2], args[3]);
        try stderr.print("fetch: {d} stories in {s}\n", .{ names.len, args[3] });
        return if (names.len == 0) 1 else 0;
    }
    if (args.len != 4) {
        try stderr.writeAll("usage: fetch <url> <sha256-hex> <output>\n       fetch --catalog <catalog-url> <dir>\n");
        return 2;
    }
    const url, const want_hex, const output = .{ args[1], args[2], args[3] };

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    const data = get(arena, &client, url) orelse {
        try stderr.print("fetch: cannot download {s}\n", .{url});
        return 1;
    };
    const got_hex = hashHex(data);
    if (!std.mem.eql(u8, &got_hex, want_hex)) {
        try stderr.print("fetch: {s} has SHA-256 {s}, not the pinned {s}\n", .{ url, &got_hex, want_hex });
        return 1;
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = data });
    return 0;
}

/// Downloads the catalog's stories that aren't in `stories_dir` yet, and
/// checks every one against its recorded SHA-256. Returns the stories'
/// names, sorted. Without the network, the stories already there are used.
fn download(arena: Allocator, gpa: Allocator, io: Io, out: *Io.Writer, catalog: []const u8, stories_dir: []const u8) ![]const []const u8 {
    const cwd = Io.Dir.cwd();
    const sums_path = try std.fs.path.join(arena, &.{ stories_dir, "SHA256SUMS" });
    const sums_text = cwd.readFileAlloc(io, sums_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    var sums: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, sums_text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOf(u8, line, "  ") orelse continue;
        try sums.put(arena, line[space + 2 ..], line[0..space]);
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var names: std.ArrayList([]const u8) = .empty;

    if (get(arena, &client, catalog)) |index| {
        var rest = index;
        while (std.mem.indexOf(u8, rest, "href=\"gamefiles/")) |at| {
            rest = rest[at + "href=\"gamefiles/".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const name = rest[0..end];
            if (!isStoryName(name) or contains(names.items, name)) continue;
            try names.append(arena, name);
            const path = try std.fs.path.join(arena, &.{ stories_dir, name });
            cwd.access(io, path, .{}) catch {
                const url = try std.fmt.allocPrint(arena, "{s}gamefiles/{s}", .{ catalog, name });
                const data = get(arena, &client, url) orelse {
                    try out.print("fetch: cannot download {s}\n", .{url});
                    _ = names.pop();
                    continue;
                };
                // A story downloaded before must be the same again.
                const hex = hashHex(data);
                if (sums.get(name)) |want| if (!std.mem.eql(u8, want, &hex)) {
                    try out.print("fetch: {s} now has SHA-256 {s}, not the recorded {s}; skipped\n", .{ url, &hex, want });
                    _ = names.pop();
                    continue;
                };
                try cwd.writeFile(io, .{ .sub_path = path, .data = data });
            };
        }
    } else {
        try out.print("fetch: cannot read {s}; using the stories already in {s}\n", .{ catalog, stories_dir });
        var it = (try cwd.openDir(io, stories_dir, .{ .iterate = true })).iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file and isStoryName(entry.name)) try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    // Every story must still be what was first downloaded.
    var checked: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const path = try std.fs.path.join(arena, &.{ stories_dir, name });
        const data = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
        const hex = hashHex(data);
        if (sums.get(name)) |want| {
            if (!std.mem.eql(u8, want, &hex)) {
                try out.print("fetch: {s} has SHA-256 {s}, not the recorded {s}; skipped\n", .{ name, &hex, want });
                continue;
            }
        } else try sums.put(arena, name, try arena.dupe(u8, &hex));
        try checked.append(arena, name);
    }
    std.mem.sort([]const u8, checked.items, {}, lessThan);

    // Record every story's hash, the new ones included, sorted by name.
    var recorded: std.ArrayList([]const u8) = .empty;
    var it = sums.keyIterator();
    while (it.next()) |name| try recorded.append(arena, name.*);
    std.mem.sort([]const u8, recorded.items, {}, lessThan);
    var text: std.ArrayList(u8) = .empty;
    for (recorded.items) |name| try text.print(arena, "{s}  {s}\n", .{ sums.get(name).?, name });
    if (!std.mem.eql(u8, text.items, sums_text)) try cwd.writeFile(io, .{ .sub_path = sums_path, .data = text.items });
    return checked.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn hashHex(data: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The body at `url`, or null if it can't be had.
fn get(arena: Allocator, client: *std.http.Client, url: []const u8) ?[]u8 {
    var body: Io.Writer.Allocating = .init(arena);
    const result = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch return null;
    if (result.status != .ok) return null;
    return body.written();
}

/// A catalog story zmachine can play: `.z1`–`.z5`, `.z7` or `.z8`.
fn isStoryName(name: []const u8) bool {
    if (name.len < 4 or std.mem.indexOfScalar(u8, name, '/') != null) return false;
    const ext = name[name.len - 3 ..];
    return ext[0] == '.' and ext[1] == 'z' and std.mem.indexOfScalar(u8, "1234578", ext[2]) != null;
}

test isStoryName {
    try std.testing.expect(isStoryName("zork1-r88-s840726.z3"));
    try std.testing.expect(!isStoryName("zork0-r393-s890714.z6"));
    try std.testing.expect(!isStoryName("../x.z3"));
}
