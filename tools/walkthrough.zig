//! Plays the walkthroughs for `zig build walkthrough`.
//!
//! usage: walkthrough <zmachine> <manifest> [--only <name>] [--update]
//!                    [--story <name>=<path>]...
//!
//! The manifest lists each script with its story file, the seeds to play
//! it with and a line the output must contain. For each seed, the script
//! is piped in with and without `--web`; both outputs must match, and match
//! the saved transcript when there is one.
//!
//! A script is named for its story, the release and serial number it was
//! written for, and optionally what it covers, such as
//! `zork1.r119-880429.opening.txt`; the story must be that release. Its
//! transcripts add the seed: `zork1.r119-880429.opening.seed1.expected`.
//! (A script named without a release gets the story's in its transcripts'
//! names.) `--update` saves the transcripts instead. `--only <name>` plays
//! the scripts with that name, or whose names start with it and a dot, such
//! as `zork1`. A missing script or story is
//! skipped, not failed: most stay local. A story named without a path, such
//! as `zork1`, is one `--story` gives (the open-source Zork stories, which
//! the build downloads).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Entry = struct {
    /// The script's file name in the manifest's directory.
    script: []const u8,
    /// The story file, relative to the working directory, or the name of
    /// one given with `--story`.
    story: []const u8,
    /// The seeds to play it with; with none, it is played once unseeded.
    seeds: []const u64 = &.{},
    /// A line the output must contain, such as a final score.
    expect: ?[]const u8 = null,
};

const Outcome = enum { passed, failed, skipped };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stderr(), io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        try out.writeAll("usage: walkthrough <zmachine> <manifest> [--only <name>] [--update]\n");
        return 2;
    }
    const zmachine = args[1];
    const manifest_path = args[2];
    var only: ?[]const u8 = null;
    var update = false;
    var stories: std.StringHashMapUnmanaged([]const u8) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--update")) {
            update = true;
        } else if (std.mem.eql(u8, args[i], "--only") and i + 1 < args.len) {
            i += 1;
            only = args[i];
        } else if (std.mem.eql(u8, args[i], "--story") and i + 1 < args.len) {
            i += 1;
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse continue;
            try stories.put(arena, args[i][0..eq], args[i][eq + 1 ..]);
        }
    }

    const cwd = Io.Dir.cwd();
    const source = cwd.readFileAllocOptions(io, manifest_path, arena, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("walkthrough: no {s}; skipped (the scripts and stories stay local)\n", .{manifest_path});
            return 0;
        },
        else => return err,
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const entries = std.zon.parse.fromSlice([]const Entry, .{
        .gpa = init.gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) try out.print("{f}\n", .{diagnostics.fmt(manifest_path)});
        return 1;
    };
    const dir = std.fs.path.dirname(manifest_path) orelse ".";

    var counts = std.enums.EnumArray(Outcome, usize).initFill(0);
    for (entries) |entry| {
        const name = if (std.mem.endsWith(u8, entry.script, ".txt")) entry.script[0 .. entry.script.len - 4] else entry.script;
        if (only) |want| if (!(std.mem.eql(u8, want, name) or
            (std.mem.startsWith(u8, name, want) and name.len > want.len and name[want.len] == '.'))) continue;
        var resolved = entry;
        if (stories.get(entry.story)) |path| resolved.story = path;
        const seeds: []const ?u64 = if (entry.seeds.len == 0) &.{null} else seeds: {
            const list = try arena.alloc(?u64, entry.seeds.len);
            for (list, entry.seeds) |*slot, seed| slot.* = seed;
            break :seeds list;
        };
        for (seeds) |seed| {
            const outcome = try play(arena, io, out, zmachine, dir, name, resolved, seed, update);
            counts.getPtr(outcome).* += 1;
            try out.flush();
        }
    }
    // With several manifests, a name is in at most one of them.
    if (only != null and counts.get(.passed) + counts.get(.failed) + counts.get(.skipped) == 0) {
        try out.print("walkthrough: nothing in {s} is named {s}\n", .{ manifest_path, only.? });
        return 0;
    }
    try out.print("walkthrough: {d} passed, {d} failed, {d} skipped\n", .{
        counts.get(.passed), counts.get(.failed), counts.get(.skipped),
    });
    return if (counts.get(.failed) > 0) 1 else 0;
}

/// Plays one walkthrough with one seed, with and without `--web`, and
/// checks the output.
fn play(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    zmachine: []const u8,
    dir: []const u8,
    script_name: []const u8,
    entry: Entry,
    seed_number: ?u64,
    update: bool,
) !Outcome {
    const cwd = Io.Dir.cwd();
    const script = try std.fs.path.join(arena, &.{ dir, entry.script });
    inline for (.{ script, entry.story }) |path| {
        cwd.access(io, path, .{}) catch {
            // A bare name is a story the build downloads.
            const hint = if (std.mem.indexOfAny(u8, path, "/.") == null) " (not downloaded with -Dstories=false)" else "";
            try out.print("skip {s}: no {s}{s}\n", .{ script_name, path, hint });
            return .skipped;
        };
    }

    // The story must be the release the script was written for; the
    // transcript is named for the script (with the release) and the seed.
    const version = try storyVersion(arena, io, entry.story);
    const written_for = scriptVersion(script_name);
    if (written_for) |want| if (!std.mem.eql(u8, want, version)) {
        try out.print("FAIL {s}: written for {s}, but {s} is {s}\n", .{ script_name, want, entry.story, version });
        return .failed;
    };
    const seed = if (seed_number) |n| try std.fmt.allocPrint(arena, "{d}", .{n}) else null;
    const base = if (written_for != null) script_name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ script_name, version });
    const name = if (seed) |n|
        try std.fmt.allocPrint(arena, "{s}.seed{s}", .{ base, n })
    else
        try std.fmt.allocPrint(arena, "{s}.unseeded", .{base});
    const plain = try run(arena, io, zmachine, seed, false, entry.story, script);
    // Port 0 lets the system pick a free port.
    const web = try run(arena, io, zmachine, seed, true, entry.story, script);

    if (!plain.ok) return fail(out, name, "the game exited with an error", .{});
    if (!web.ok) return fail(out, name, "the game exited with an error with --web", .{});
    if (!std.mem.eql(u8, plain.output, web.output)) {
        try out.print("FAIL {s}: output differs with --web\n", .{name});
        try showDifference(out, plain.output, web.output, "without --web", "with --web");
        return .failed;
    }
    if (entry.expect) |line| if (std.mem.indexOf(u8, plain.output, line) == null) {
        return fail(out, name, "the output lacks \"{s}\"", .{line});
    };

    const expected_path = try std.fmt.allocPrint(arena, "{s}/{s}.expected", .{ dir, name });
    if (update) {
        try cwd.writeFile(io, .{ .sub_path = expected_path, .data = plain.output });
        try out.print("ok   {s}: saved {s}\n", .{ name, expected_path });
        return .passed;
    }
    const expected = cwd.readFileAlloc(io, expected_path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("ok   {s} (no {s} to compare; -Dupdate-walkthroughs saves one)\n", .{ name, expected_path });
            return .passed;
        },
        else => return err,
    };
    if (!std.mem.eql(u8, expected, plain.output)) {
        try out.print("FAIL {s}: output differs from {s}\n", .{ name, expected_path });
        try showDifference(out, expected, plain.output, "expected", "now");
        return .failed;
    }
    try out.print("ok   {s}\n", .{name});
    return .passed;
}

/// The release and serial number in a script's name, such as `r88-840726`
/// in `zork1.r88-840726.txt`'s name `zork1.r88-840726`.
fn scriptVersion(name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len < 9 or part[0] != 'r') continue;
        const dash = std.mem.indexOfScalar(u8, part, '-') orelse continue;
        _ = std.fmt.parseInt(u16, part[1..dash], 10) catch continue;
        if (part.len - dash - 1 == 6) return part;
    }
    return null;
}

/// The story's release and serial number, such as `r88-840726`, from its
/// header.
fn storyVersion(arena: Allocator, io: Io, story: []const u8) ![]const u8 {
    const file = try Io.Dir.cwd().openFile(io, story, .{});
    defer file.close(io);
    var header: [0x18]u8 = undefined;
    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);
    reader.interface.readSliceAll(&header) catch return "unknown";
    var serial: [6]u8 = header[0x12..0x18].*;
    // Keep the name to letters and digits.
    for (&serial) |*c| if (!std.ascii.isAlphanumeric(c.*)) {
        c.* = '_';
    };
    return std.fmt.allocPrint(arena, "r{d}-{s}", .{ std.mem.readInt(u16, header[2..4], .big), &serial });
}

fn fail(out: *Io.Writer, name: []const u8, comptime fmt: []const u8, args: anytype) !Outcome {
    try out.print("FAIL {s}: " ++ fmt ++ "\n", .{name} ++ args);
    return .failed;
}

const Result = struct {
    output: []u8,
    ok: bool,
};

/// Runs the interpreter on `story` with `script` as its input, returning
/// what it printed.
fn run(
    arena: Allocator,
    io: Io,
    zmachine: []const u8,
    seed: ?[]const u8,
    web: bool,
    story: []const u8,
    script: []const u8,
) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, zmachine);
    if (seed) |n| try argv.appendSlice(arena, &.{ "--seed", n });
    if (web) try argv.appendSlice(arena, &.{ "--web", "0" });
    try argv.append(arena, story);

    const input = try Io.Dir.cwd().openFile(io, script, .{});
    defer input.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .{ .file = input },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var buf: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const output = try reader.interface.allocRemaining(arena, .limited(64 << 20));
    const term = try child.wait(io);
    return .{ .output = output, .ok = term == .exited and term.exited == 0 };
}

/// Shows the first line where `a` and `b` differ.
fn showDifference(out: *Io.Writer, a: []const u8, b: []const u8, a_name: []const u8, b_name: []const u8) !void {
    var line: usize = 1;
    var start: usize = 0;
    const n = @min(a.len, b.len);
    for (0..n) |k| {
        if (a[k] != b[k]) break;
        if (a[k] == '\n') {
            line += 1;
            start = k + 1;
        }
    }
    try out.print("  line {d}:\n  {s}: {s}\n  {s}: {s}\n", .{
        line, a_name, lineAt(a, start), b_name, lineAt(b, start),
    });
}

fn lineAt(text: []const u8, start: usize) []const u8 {
    if (start >= text.len) return "(end of output)";
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}
