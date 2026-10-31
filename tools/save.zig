//! Saves a run's commands as a local walkthrough.
//!
//! usage: save <log.jsonl> [--run <n>] [--game <url>] [--out <dir>]
//!
//! The name carries game, version, seed, model, and iteration, read from
//! the running game's `GET /story` and the log's `init` line:
//! `<story>.r<release>-<serial>.dumberbots.seed<seed>.<model>.run<n>.txt`.
//! The file holds only the commands, one per line, so the walkthrough tool
//! can play it. Run it while the game still runs the game the log played.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const default_out = "tests/walkthroughs-local/dumberbots";

/// The story's name: its file name up to the first dot.
pub fn storyName(file: []const u8) []const u8 {
    return file[0 .. std.mem.indexOfScalar(u8, file, '.') orelse file.len];
}

/// `<story>.r<release>-<serial>.dumberbots.seed<seed>.<model>.run<n>.txt`.
pub fn fileName(arena: Allocator, story: []const u8, release: u16, serial: []const u8, seed: u64, model: []const u8, run: []const u8) ![]u8 {
    var slug: std.ArrayList(u8) = .empty;
    for (model) |c| {
        const lower = std.ascii.toLower(c);
        try slug.append(arena, if (std.ascii.isAlphanumeric(lower) or lower == '.') lower else '-');
    }
    return std.fmt.allocPrint(arena, "{s}.r{d}-{s}.dumberbots.seed{d}.{s}.run{s}.txt", .{ story, release, serial, seed, slug.items, run });
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args[0..args.len -| 1], 0..) |a, i| if (std.mem.eql(u8, a, name)) return args[i + 1];
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll("usage: save <log.jsonl> [--run <n>] [--game <url>] [--out <dir>]\n");
        return 2;
    }
    const log = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));

    var model: []const u8 = "model";
    var commands: Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (value != .object) continue;
        const ev = value.object.get("ev") orelse continue;
        if (ev != .string) continue;
        if (std.mem.eql(u8, ev.string, "init")) {
            if (value.object.get("model")) |m| if (m == .string) {
                model = m.string;
            };
        } else if (std.mem.eql(u8, ev.string, "call")) {
            const name = value.object.get("name") orelse continue;
            const call_args = value.object.get("args") orelse continue;
            if (name != .string or !std.mem.eql(u8, name.string, "send_command") or call_args != .object) continue;
            const command = call_args.object.get("command") orelse continue;
            if (command == .string) try commands.writer.print("{s}\n", .{command.string});
        }
    }

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();
    var body: Io.Writer.Allocating = .init(arena);
    const url = try std.fmt.allocPrint(arena, "{s}/story", .{option(args, "--game") orelse "http://127.0.0.1:9675"});
    const result = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch |err| {
        try stderr.print("save: cannot reach the game: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (result.status != .ok) {
        try stderr.writeAll("save: the game did not describe its story\n");
        return 1;
    }
    const Story = struct { file: []const u8, release: u16, serial: []const u8, seed: u64 };
    const story = try std.json.parseFromSliceLeaky(Story, arena, body.written(), .{ .ignore_unknown_fields = true });

    const name = try fileName(arena, storyName(story.file), story.release, story.serial, story.seed, model, option(args, "--run") orelse "1");
    const path = try std.fs.path.join(arena, &.{ option(args, "--out") orelse default_out, name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = commands.written() });
    try stderr.print("{s}\n", .{path});
    return 0;
}

test fileName {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const name = try fileName(arena_state.allocator(), "zork1", 119, "880429", 69, "qwen3:14b", "2");
    try std.testing.expectEqualStrings("zork1.r119-880429.dumberbots.seed69.qwen3-14b.run2.txt", name);
}

test storyName {
    try std.testing.expectEqualStrings("zork1", storyName("zork1.r119-880429.z3"));
    try std.testing.expectEqualStrings("zork1", storyName("zork1"));
}
