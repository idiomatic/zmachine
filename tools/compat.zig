//! Plays every story in the Obsessively Complete Infocom Catalog briefly,
//! for `zig build compat`, and compares zmachine with dfrotz.
//!
//! usage: compat <zmachine> <dir> [--frotz <dfrotz>] [--only <prefix>]
//!
//! `--frotz` names dfrotz (found on the path if it isn't a path); if it
//! won't run, zmachine plays alone.
//!
//! The catalog's story files (all versions but 6) are downloaded into
//! `<dir>/stories/` once; their SHA-256s are recorded in `SHA256SUMS` there
//! on first download and checked afterwards. Each story is played with the
//! same few commands and seed 1, its transcript kept in `<dir>/runs/`. With
//! dfrotz (`-I 6`, like zmachine), the transcripts are compared ignoring
//! whitespace, since Frotz wraps its transcript and zmachine doesn't.
//!
//! A story fails when zmachine exits with an error or hangs and dfrotz
//! doesn't; differences in what they print are reported, not failed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const catalog = "https://eblong.com/infocom/";

/// What each story gets: enough to pass openings that wait for a key or
/// ask to begin, then a look around, Infocom's own `$verify`, and quitting.
const input = "\n\n\nbegin\n\nlook\ninventory\n$verify\nquit\ny\n\n";

/// How long one run may take before it counts as hung.
const time_limit = Io.Duration.fromSeconds(15);

const Outcome = enum { same, differs, failed, both_fail, frotz_fails, played };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stderr(), io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        try out.writeAll("usage: compat <zmachine> <dir> [--frotz <dfrotz>] [--only <prefix>]\n");
        return 2;
    }
    const dir = args[2];
    var frotz: ?[]const u8 = null;
    var only: ?[]const u8 = null;
    var i: usize = 3;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--frotz")) frotz = args[i + 1];
        if (std.mem.eql(u8, args[i], "--only")) only = args[i + 1];
    }

    // Without dfrotz, zmachine plays alone.
    if (frotz) |path| {
        const probe = std.process.run(arena, io, .{ .argv = &.{ path, "-v" } }) catch null;
        if (probe == null) {
            try out.print("compat: no {s}; playing zmachine alone\n", .{path});
            frotz = null;
        }
    }

    const cwd = Io.Dir.cwd();
    // The interpreters run in runs/, so files a game saves land there;
    // every path they get is absolute.
    const zmachine = try cwd.realPathFileAlloc(io, args[1], arena);
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ dir, "stories" }));
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ dir, "runs" }));
    const stories_dir = try cwd.realPathFileAlloc(io, try std.fs.path.join(arena, &.{ dir, "stories" }), arena);
    const runs_dir = try cwd.realPathFileAlloc(io, try std.fs.path.join(arena, &.{ dir, "runs" }), arena);
    // Start each run afresh: a save left by the last could be restored.
    {
        var runs = try cwd.openDir(io, runs_dir, .{ .iterate = true });
        defer runs.close(io);
        var it = runs.iterate();
        while (try it.next(io)) |entry| if (entry.kind == .file) try runs.deleteFile(io, entry.name);
    }

    const names = try download(arena, init.gpa, io, out, stories_dir);
    if (names.len == 0) {
        try out.writeAll("compat: no stories\n");
        return 1;
    }
    const input_path = try std.fs.path.join(arena, &.{ runs_dir, "input.txt" });
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = input });

    var counts = std.enums.EnumArray(Outcome, usize).initFill(0);
    for (names) |name| {
        if (only) |prefix| if (!std.mem.startsWith(u8, name, prefix)) continue;
        const outcome = try check(arena, init.gpa, io, out, zmachine, frotz, stories_dir, runs_dir, input_path, name);
        counts.getPtr(outcome).* += 1;
        try out.flush();
    }
    try out.print("compat: {d} same, {d} differ, {d} failed, {d} fail in both, {d} fail only in dfrotz, {d} played without dfrotz\n", .{
        counts.get(.same),      counts.get(.differs),     counts.get(.failed),
        counts.get(.both_fail), counts.get(.frotz_fails), counts.get(.played),
    });
    return if (counts.get(.failed) > 0) 1 else 0;
}

/// Downloads the catalog's stories that aren't in `stories_dir` yet, and
/// checks every one against its recorded SHA-256. Returns the stories'
/// names, sorted. Without the network, the stories already there are used.
fn download(arena: Allocator, gpa: Allocator, io: Io, out: *Io.Writer, stories_dir: []const u8) ![]const []const u8 {
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
                    try out.print("compat: cannot download {s}\n", .{url});
                    _ = names.pop();
                    continue;
                };
                // A story downloaded before must be the same again.
                const hex = hashHex(data);
                if (sums.get(name)) |want| if (!std.mem.eql(u8, want, &hex)) {
                    try out.print("compat: {s} now has SHA-256 {s}, not the recorded {s}; skipped\n", .{ url, &hex, want });
                    _ = names.pop();
                    continue;
                };
                try cwd.writeFile(io, .{ .sub_path = path, .data = data });
            };
        }
    } else {
        try out.print("compat: cannot read {s}; using the stories already in {s}\n", .{ catalog, stories_dir });
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
                try out.print("compat: {s} has SHA-256 {s}, not the recorded {s}; skipped\n", .{ name, &hex, want });
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

/// A catalog story zmachine can play: `.z1`–`.z5`, `.z7` or `.z8`.
fn isStoryName(name: []const u8) bool {
    if (name.len < 4 or std.mem.indexOfScalar(u8, name, '/') != null) return false;
    const ext = name[name.len - 3 ..];
    return ext[0] == '.' and ext[1] == 'z' and std.mem.indexOfScalar(u8, "1234578", ext[2]) != null;
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

const Run = struct {
    /// The transcript, or empty if there is none.
    transcript: []const u8,
    /// Why the run went wrong, or null.
    problem: ?[]const u8,
};

/// Plays one story in zmachine, and in dfrotz if given, and reports.
fn check(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    zmachine: []const u8,
    frotz: ?[]const u8,
    stories_dir: []const u8,
    runs_dir: []const u8,
    input_path: []const u8,
    name: []const u8,
) !Outcome {
    const story = try std.fs.path.join(arena, &.{ stories_dir, name });
    const zm_path = try std.fmt.allocPrint(arena, "{s}/{s}.zmachine.txt", .{ runs_dir, name });
    const zm = try play(arena, gpa, io, &.{ zmachine, "--plain", "--seed", "1", "-t", zm_path, story }, runs_dir, input_path, zm_path);
    const dfrotz = frotz orelse {
        if (zm.problem) |why| {
            try out.print("FAIL {s}: {s}\n", .{ name, why });
            return .failed;
        }
        try out.print("ok   {s}\n", .{name});
        return .played;
    };
    const fz_path = try std.fmt.allocPrint(arena, "{s}/{s}.frotz.txt", .{ runs_dir, name });
    const fz = try play(arena, gpa, io, &.{ dfrotz, "-s", "1", "-I", "6", "-m", "-q", "-T", "-n", fz_path, story }, runs_dir, input_path, fz_path);

    if (zm.problem != null and fz.problem != null) {
        try out.print("both {s}: zmachine {s}; dfrotz {s}\n", .{ name, zm.problem.?, fz.problem.? });
        return .both_fail;
    }
    if (zm.problem) |why| {
        try out.print("FAIL {s}: {s} (dfrotz plays it)\n", .{ name, why });
        return .failed;
    }
    if (fz.problem) |why| {
        try out.print("note {s}: dfrotz {s}\n", .{ name, why });
        return .frotz_fails;
    }
    const a = try squeeze(arena, zm.transcript);
    const b = try squeeze(arena, try withoutWarnings(arena, fz.transcript));
    const at = firstDifference(a, b) orelse {
        try out.print("ok   {s}\n", .{name});
        return .same;
    };
    const from = at -| 30;
    try out.print("diff {s}:\n  zmachine: {s}\n  dfrotz:   {s}\n", .{
        name, a[from..@min(a.len, at + 40)], b[from..@min(b.len, at + 40)],
    });
    return .differs;
}

/// Runs `argv` with `input_path` as its input and returns the transcript
/// it wrote to `transcript_path`, or what went wrong.
fn play(
    arena: Allocator,
    gpa: Allocator,
    io: Io,
    argv: []const []const u8,
    run_dir: []const u8,
    input_path: []const u8,
    transcript_path: []const u8,
) !Run {
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, transcript_path) catch {};
    const stdin = try cwd.openFile(io, input_path, .{});
    defer stdin.close(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = run_dir },
        .stdin = .{ .file = stdin },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return .{ .transcript = "", .problem = try std.fmt.allocPrint(arena, "won't start: {s}", .{@errorName(err)}) };
    defer child.kill(io);

    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(gpa, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const deadline = (Io.Timeout{ .duration = .{ .raw = time_limit, .clock = .awake } }).toDeadline(io);
    var hung = false;
    while (reader.fill(4096, deadline)) |_| {
        if (reader.reader(0).buffered().len > 16 << 20) {
            hung = true;
            break;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => hung = true,
        else => |e| return e,
    }
    if (hung) return .{ .transcript = "", .problem = "hung" };
    const term = try child.wait(io);
    const stdout = reader.reader(0).buffered();
    const stderr = reader.reader(1).buffered();
    const transcript = cwd.readFileAlloc(io, transcript_path, arena, .limited(64 << 20)) catch "";
    // Frotz reports a fatal error on standard output.
    const fatal = std.mem.indexOf(u8, stdout, "Fatal error");
    if (term == .exited and term.exited == 0 and fatal == null) return .{ .transcript = transcript, .problem = null };
    const message = if (fatal) |at| stdout[at..] else stderr;
    var lines = std.mem.tokenizeAny(u8, message, "\r\n");
    return .{
        .transcript = transcript,
        .problem = try std.fmt.allocPrint(arena, "exited with an error: {s}", .{lines.next() orelse "(no message)"}),
    };
}

/// Where `a` (zmachine's) and `b` (dfrotz's) first differ, or null if they
/// don't, but for each interpreter's version letter (`VersionZ`, `VersionF`)
/// in the version banners Infocom's games print.
fn firstDifference(a: []const u8, b: []const u8) ?usize {
    var at: usize = 0;
    while (at < @min(a.len, b.len)) : (at += 1) {
        if (a[at] == b[at]) continue;
        if (a[at] == 'Z' and b[at] == 'F' and std.mem.endsWith(u8, a[0..at], "Version")) continue;
        return at;
    }
    return if (a.len == b.len) null else at;
}

test firstDifference {
    try std.testing.expectEqual(null, firstDifference("Interpreter6VersionZOk", "Interpreter6VersionFOk"));
    try std.testing.expectEqual(3, firstDifference("abcZ", "abcF"));
    try std.testing.expectEqual(2, firstDifference("ab", "abc"));
}

/// `text` without Frotz's own warning lines, such as missing sounds.
fn withoutWarnings(arena: Allocator, text: []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Warning: @") != null or
            std.mem.indexOf(u8, line, "ignore further occurrences)") != null) continue;
        try kept.appendSlice(arena, line);
        try kept.append(arena, '\n');
    }
    return kept.items;
}

/// `text` with all whitespace removed, so wrapping doesn't matter.
fn squeeze(arena: Allocator, text: []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    for (text) |c| if (!std.ascii.isWhitespace(c)) try kept.append(arena, c);
    return kept.toOwnedSlice(arena);
}

test squeeze {
    const text = try squeeze(std.testing.allocator, "a b\n c\t");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("abc", text);
}

test isStoryName {
    try std.testing.expect(isStoryName("zork1-r88-s840726.z3"));
    try std.testing.expect(!isStoryName("zork0-r393-s890714.z6"));
    try std.testing.expect(!isStoryName("../x.z3"));
}
