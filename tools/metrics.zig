//! Tallies the Phase 0 metrics of MODEL_EVALUATION.md from run logs.
//!
//! usage: metrics <log.jsonl>...
//!
//! A log has one JSON object per line: `init` (with the model), then a
//! `call` per tool call (`name`, `args`, `res`), and `prose` or `http` for
//! a reply with no usable call. A run succeeds when its first 50
//! `send_command` calls have no malformed call, no tool error, and no loop
//! (one command three times in ten). Parser refusals are counted, not failures.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const refusals = [_][]const u8{
    "I don't know the word",
    "isn't one I recognize",
    "You used the word",
    "no verb in that",
    "too many nouns",
    "can't see any",
    "aren't here",
};

pub const Metrics = struct {
    calls: usize = 0,
    plays: usize = 0,
    malformed: usize = 0,
    errors: usize = 0,
    refused: usize = 0,
    /// The 1-based play at which a command was first repeated three times in ten.
    first_loop: ?usize = null,
    best_score: u32 = 0,

    pub fn success(m: Metrics) bool {
        const loop_early = if (m.first_loop) |n| n <= 50 else false;
        return m.plays >= 50 and m.malformed == 0 and m.errors == 0 and !loop_early;
    }
};

pub fn tally(arena: Allocator, text: []const u8) !Metrics {
    var m: Metrics = .{};
    var commands: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (value != .object) continue;
        const ev = stringOf(value.object.get("ev")) orelse continue;
        if (std.mem.eql(u8, ev, "prose") or std.mem.eql(u8, ev, "http")) m.malformed += 1;
        if (!std.mem.eql(u8, ev, "call")) continue;
        m.calls += 1;
        const res = stringOf(value.object.get("res")) orelse "";
        if (std.mem.startsWith(u8, res, "ERROR") or std.mem.indexOf(u8, res, "isError\":true") != null) m.errors += 1;
        if (!std.mem.eql(u8, stringOf(value.object.get("name")) orelse "", "send_command")) continue;
        m.plays += 1;
        for (refusals) |r| if (std.mem.indexOf(u8, res, r) != null) {
            m.refused += 1;
            break;
        };
        m.best_score = @max(m.best_score, scoreIn(res));
        const args = value.object.get("args") orelse continue;
        if (args != .object) continue;
        const command = stringOf(args.object.get("command")) orelse "";
        try commands.append(arena, command);
        if (m.first_loop == null and repeats(commands.items)) m.first_loop = m.plays;
    }
    return m;
}

fn stringOf(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

/// Whether the last command was sent three times in the last ten.
fn repeats(commands: []const []const u8) bool {
    const last = commands[commands.len - 1];
    var n: usize = 0;
    for (commands[commands.len -| 10..]) |c| {
        if (std.mem.eql(u8, c, last)) n += 1;
    }
    return n >= 3;
}

/// The score in a reply's status line, "Score: 5" or "Score 5", or 0.
fn scoreIn(res: []const u8) u32 {
    var best: u32 = 0;
    var rest = res;
    while (std.mem.indexOf(u8, rest, "Score")) |at| {
        var i = at + "Score".len;
        while (i < rest.len and (rest[i] == ':' or rest[i] == ' ')) i += 1;
        const start = i;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i > start) best = @max(best, std.fmt.parseInt(u32, rest[start..i], 10) catch 0);
        rest = rest[i..];
    }
    return best;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try out.writeAll("usage: metrics <log.jsonl>...\n");
        return 2;
    }
    try out.writeAll("log | calls | plays | malformed | errors | parser refusals | first loop at | best score | success\n");
    for (args[1..]) |path| {
        const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024)) catch |err| {
            try out.print("{s} | cannot read: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        const m = try tally(arena, text);
        try out.print("{s} | {d} | {d} | {d} | {d} | {d} | ", .{ path, m.calls, m.plays, m.malformed, m.errors, m.refused });
        if (m.first_loop) |n| try out.print("{d}", .{n}) else try out.writeAll("-");
        try out.print(" | {d} | {s}\n", .{ m.best_score, if (m.success()) "yes" else "no" });
    }
    return 0;
}

test tally {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const log =
        \\{"ev":"init","model":"m"}
        \\{"ev":"call","name":"send_command","args":{"command":"look"},"res":"Score 5, moves 1, in X\nWest"}
        \\{"ev":"call","name":"send_command","args":{"command":"look"},"res":"I don't know the word \"x\"."}
        \\{"ev":"prose"}
        \\{"ev":"call","name":"send_command","args":{"command":"look"},"res":"[X | Score: 7   Moves: 3]"}
        \\{"ev":"call","name":"read_recent","args":{},"res":"ERROR boom"}
    ;
    const m = try tally(arena_state.allocator(), log);
    try std.testing.expectEqual(4, m.calls);
    try std.testing.expectEqual(3, m.plays);
    try std.testing.expectEqual(1, m.malformed);
    try std.testing.expectEqual(1, m.errors);
    try std.testing.expectEqual(1, m.refused);
    try std.testing.expectEqual(3, m.first_loop.?);
    try std.testing.expectEqual(7, m.best_score);
    try std.testing.expect(!m.success());
}
