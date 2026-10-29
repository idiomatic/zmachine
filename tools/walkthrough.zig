//! Plays the local walkthroughs for `zig build walkthrough`.
//!
//! usage: walkthrough <zmachine> <manifest> [--only <name>] [--update]
//!
//! The manifest, `tests/walkthroughs/walkthroughs.zon`, lists each script
//! with its story file, seed and a line the output must contain. Each
//! script is piped in with and without `--web`; both outputs must match,
//! and match the saved transcript `<script>.expected` when there is one.
//! `--update` saves the transcripts instead. Scripts, stories, transcripts
//! and the manifest stay local, so a missing one is skipped, not failed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Entry = struct {
    /// The script's file name in the manifest's directory.
    script: []const u8,
    /// The story file, relative to the working directory.
    story: []const u8,
    seed: ?u64 = null,
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
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--update")) {
            update = true;
        } else if (std.mem.eql(u8, args[i], "--only") and i + 1 < args.len) {
            i += 1;
            only = args[i];
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
        if (only) |want| if (!std.mem.eql(u8, want, name)) continue;
        const outcome = try play(arena, io, out, zmachine, dir, name, entry, update);
        counts.getPtr(outcome).* += 1;
        try out.flush();
    }
    if (only != null and counts.get(.passed) + counts.get(.failed) + counts.get(.skipped) == 0) {
        try out.print("walkthrough: nothing in {s} is named {s}\n", .{ manifest_path, only.? });
        return 1;
    }
    try out.print("walkthrough: {d} passed, {d} failed, {d} skipped\n", .{
        counts.get(.passed), counts.get(.failed), counts.get(.skipped),
    });
    return if (counts.get(.failed) > 0) 1 else 0;
}

/// Plays one walkthrough with and without `--web`, and checks the output.
fn play(
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    zmachine: []const u8,
    dir: []const u8,
    name: []const u8,
    entry: Entry,
    update: bool,
) !Outcome {
    const cwd = Io.Dir.cwd();
    const script = try std.fs.path.join(arena, &.{ dir, entry.script });
    inline for (.{ script, entry.story }) |path| {
        cwd.access(io, path, .{}) catch {
            try out.print("skip {s}: no {s}\n", .{ name, path });
            return .skipped;
        };
    }

    var seed_buf: [24]u8 = undefined;
    const seed = if (entry.seed) |n| try std.fmt.bufPrint(&seed_buf, "{d}", .{n}) else null;
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
