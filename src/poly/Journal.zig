//! The journal: everything that happened in the game, in order, for a
//! record of the session: the game's text, commands, thoughts, messages,
//! changes among the players, and rooms entered. Unlike the discussion it
//! is never cleared; only the oldest entries go once it is large. Its owner
//! locks it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Discussion = @import("Discussion.zig");

const Journal = @This();

entries: std.ArrayList(Entry) = .empty,
next_seq: u64 = 1,
/// Commands sent since the game began or restarted.
turn: u32 = 0,
/// Bytes of text held.
bytes: usize = 0,
/// A command has been sent since the game last printed, so the game's
/// text begins with its echo.
echo_pending: bool = false,
/// The object number of the room last entered, or 0 at the start of a game.
room: u16 = 0,

/// The most text kept before the oldest entries are dropped.
const max_bytes = 16 * 1024 * 1024;

pub const Kind = enum {
    /// What the game printed, in answer to the latest command.
    game,
    /// A command sent to the game.
    command,
    thought,
    message,
    mode,
    leader,
    joined,
    left,
    kicked,
    granted,
    revoked,
    /// The game restarted.
    restarted,
    /// The player entered a room; the text is its name.
    room,
    /// The random number generator was seeded; the text is the seed, then
    /// "(random)" if it was drawn at random.
    seed,

    /// The journal's kind for a discussion post, if it is kept. The
    /// password's change and the discussion's clearing are not.
    pub fn fromPost(kind: Discussion.PostKind) ?Kind {
        return switch (kind) {
            .thought => .thought,
            .message => .message,
            .command => .command,
            .mode => .mode,
            .leader => .leader,
            .joined => .joined,
            .left => .left,
            .kicked => .kicked,
            .granted => .granted,
            .revoked => .revoked,
            .restarted => .restarted,
            .password, .cleared => null,
        };
    }
};

pub const Entry = struct {
    seq: u64,
    time: i64,
    /// Commands sent so far this game, this one included.
    turn: u32,
    /// The person's or AI partner's name, or null for the console and for
    /// the game itself.
    author: ?[]u8,
    ai: bool,
    kind: Kind,
    text: []u8,
    suggestions: [][]u8,
    /// For a room entry, the room's object number; otherwise 0.
    room: u16 = 0,
};

pub fn deinit(j: *Journal, gpa: Allocator) void {
    for (j.entries.items) |e| freeEntry(gpa, e);
    j.entries.deinit(gpa);
}

fn freeEntry(gpa: Allocator, e: Entry) void {
    if (e.author) |name| gpa.free(name);
    for (e.suggestions) |text| gpa.free(text);
    gpa.free(e.suggestions);
    gpa.free(e.text);
}

fn size(e: Entry) usize {
    var n = e.text.len + @sizeOf(Entry);
    for (e.suggestions) |s| n += s.len;
    return n;
}

/// Adds an entry by `author` (null for the console or the game) at `time`.
pub fn add(j: *Journal, gpa: Allocator, time: i64, author: ?[]const u8, ai: bool, kind: Kind, text: []const u8, suggestions: []const []const u8) !void {
    return j.addIn(gpa, time, author, ai, kind, text, suggestions, 0);
}

fn addIn(j: *Journal, gpa: Allocator, time: i64, author: ?[]const u8, ai: bool, kind: Kind, text: []const u8, suggestions: []const []const u8, room: u16) !void {
    const copies = try gpa.alloc([]u8, suggestions.len);
    var copied: usize = 0;
    errdefer {
        for (copies[0..copied]) |c| gpa.free(c);
        gpa.free(copies);
    }
    for (suggestions, copies) |s, *c| {
        c.* = try gpa.dupe(u8, s);
        copied += 1;
    }
    const text_copy = try gpa.dupe(u8, text);
    errdefer gpa.free(text_copy);
    const author_copy = if (author) |n| try gpa.dupe(u8, n) else null;
    errdefer if (author_copy) |n| gpa.free(n);

    if (kind == .restarted) {
        j.turn = 0;
        j.room = 0;
    }
    if (kind == .command) {
        j.turn += 1;
        j.echo_pending = true;
    }
    const entry: Entry = .{
        .seq = j.next_seq,
        .time = time,
        .turn = j.turn,
        .author = author_copy,
        .ai = ai,
        .kind = kind,
        .text = text_copy,
        .suggestions = copies,
        .room = room,
    };
    try j.entries.append(gpa, entry);
    j.next_seq += 1;
    j.bytes += size(entry);
    var drop: usize = 0;
    while (j.bytes > max_bytes and drop + 1 < j.entries.items.len) : (drop += 1) {
        const old = j.entries.items[drop];
        j.bytes -= size(old);
        freeEntry(gpa, old);
    }
    if (drop > 0) j.entries.replaceRangeAssumeCapacity(0, drop, &.{});
}

/// Adds what the game printed since it last waited for input, as `raw`
/// holds it. Nothing is added if there is nothing to say.
pub fn addGame(j: *Journal, gpa: Allocator, time: i64, raw: []const u8) !void {
    const text = gameText(raw, j.echo_pending);
    j.echo_pending = false;
    if (text.len == 0) return;
    try j.add(gpa, time, null, false, .game, text, &.{});
}

/// Adds that the player is in room `id`, named `name`, unless the last
/// entry of the kind said so.
pub fn addRoom(j: *Journal, gpa: Allocator, time: i64, id: u16, name: []const u8) !void {
    if (id == 0 or id == j.room) return;
    try j.addIn(gpa, time, null, false, .room, name, &.{}, id);
    j.room = id;
}

/// The sequence number of the latest entry, or 0.
pub fn last(j: *const Journal) u64 {
    return j.next_seq - 1;
}

/// What the game printed in answer to a command, from the text between
/// two waits for input: without the echo of the command that begins it
/// (when `echoed`) and the prompt that ends it.
pub fn gameText(raw: []const u8, echoed: bool) []const u8 {
    var text = raw;
    if (echoed) {
        const eol = std.mem.indexOfScalar(u8, text, '\n') orelse return "";
        text = text[eol + 1 ..];
    }
    text = std.mem.trimEnd(u8, text, " \t\r\n");
    // The prompt, on a line of its own or after a blank one.
    if (std.mem.endsWith(u8, text, ">")) text = std.mem.trimEnd(u8, text[0 .. text.len - 1], " \t\r\n");
    return std.mem.trimStart(u8, text, "\r\n");
}

test "game text loses the echoed command and the prompt" {
    try std.testing.expectEqualStrings(
        "Opening the small mailbox reveals a leaflet.",
        gameText("open mailbox\nOpening the small mailbox reveals a leaflet.\n\n>", true),
    );
    // The first text has no command to drop.
    try std.testing.expectEqualStrings("ZORK I\nWest of House", gameText("ZORK I\nWest of House\n\n>", false));
    // A command with no answer.
    try std.testing.expectEqualStrings("", gameText("look\n", true));
    try std.testing.expectEqualStrings("", gameText("", false));
}

test "turns count commands and restart from zero" {
    const gpa = std.testing.allocator;
    var j: Journal = .{};
    defer j.deinit(gpa);
    try j.add(gpa, 1, null, false, .game, "Intro", &.{});
    try j.add(gpa, 2, "ada", true, .command, "n", &.{});
    try j.add(gpa, 3, null, false, .game, "Forest.", &.{});
    try j.add(gpa, 4, "ada", true, .thought, "Hm.", &.{"e"});
    try j.add(gpa, 5, null, false, .restarted, "", &.{});
    try j.add(gpa, 6, null, false, .game, "Intro", &.{});
    const turns = [_]u32{ 0, 1, 1, 1, 0, 0 };
    for (j.entries.items, turns) |e, t| try std.testing.expectEqual(t, e.turn);
    try std.testing.expectEqual(@as(u64, 6), j.last());
    try std.testing.expectEqualStrings("e", j.entries.items[3].suggestions[0]);
}

test "the oldest entries go when the journal is large" {
    const gpa = std.testing.allocator;
    var j: Journal = .{};
    defer j.deinit(gpa);
    const chunk = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(chunk);
    @memset(chunk, 'x');
    for (0..6) |_| try j.add(gpa, 0, null, false, .game, chunk, &.{});
    try std.testing.expect(j.bytes <= 16 * 1024 * 1024);
    try std.testing.expect(j.entries.items.len < 6);
    // Sequence numbers go on.
    try std.testing.expectEqual(@as(u64, 6), j.last());
    try std.testing.expectEqual(@as(u64, 6), j.entries.items[j.entries.items.len - 1].seq);
}

test "password and clearing are not kept" {
    try std.testing.expect(Kind.fromPost(.password) == null);
    try std.testing.expect(Kind.fromPost(.cleared) == null);
    try std.testing.expectEqual(Kind.command, Kind.fromPost(.command).?);
}

test "game text is added without the echo of the command before it" {
    const gpa = std.testing.allocator;
    var j: Journal = .{};
    defer j.deinit(gpa);
    try j.addGame(gpa, 1, "ZORK I\nWest of House\n\n>");
    try j.add(gpa, 2, null, false, .command, "n", &.{});
    try j.addGame(gpa, 3, "n\nNorth of House\n\n>");
    // Nothing printed, nothing added.
    try j.addGame(gpa, 4, "");
    try std.testing.expectEqual(@as(usize, 3), j.entries.items.len);
    try std.testing.expectEqualStrings("ZORK I\nWest of House", j.entries.items[0].text);
    try std.testing.expectEqualStrings("North of House", j.entries.items[2].text);
    try std.testing.expectEqual(@as(u32, 1), j.entries.items[2].turn);
}

test "a room is journaled when entered, and again after a restart" {
    const gpa = std.testing.allocator;
    var j: Journal = .{};
    defer j.deinit(gpa);
    try j.addRoom(gpa, 1, 64, "West of House");
    try j.addRoom(gpa, 2, 64, "West of House");
    try j.addRoom(gpa, 3, 137, "North of House");
    try j.addRoom(gpa, 4, 0, "");
    try std.testing.expectEqual(@as(usize, 2), j.entries.items.len);
    try std.testing.expectEqual(@as(u16, 137), j.entries.items[1].room);
    try j.add(gpa, 5, null, false, .restarted, "", &.{});
    try j.addRoom(gpa, 6, 137, "North of House");
    try std.testing.expectEqual(@as(usize, 4), j.entries.items.len);
}
