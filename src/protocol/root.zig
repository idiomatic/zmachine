//! The JSON the web routes speak: each reply's type, written by the server
//! (`web`, `inspector`) and read by the MCP server, so the two can't drift
//! apart. Field order is the order on the wire.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Whether `name` can name a player (`X-Player`, `X-Person`, `POST /join`):
/// 1 to 32 printable characters, and not "you" or "console", which stand
/// for the console.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 0x20 or c == 0x7f) return false;
    return !std.ascii.eqlIgnoreCase(name, "you") and !std.ascii.eqlIgnoreCase(name, "console");
}

/// `GET /transcript`: the game text since an offset.
pub const Transcript = struct {
    offset: u64,
    waiting: bool,
    mode: []const u8,
    text: []const u8,
    status: []const []const u8,
};

/// `POST /command`: the game's reply, or only `pending` while it is still
/// queued or running (the text then appears in `/transcript`).
pub const CommandReply = struct {
    id: u64,
    /// Where the echoed command starts in the game text.
    echo: ?u64 = null,
    /// The offset just past the reply.
    offset: ?u64 = null,
    output: ?[]const u8 = null,
    status: ?[]const []const u8 = null,
    pending: ?bool = null,

    pub const omit_null = true;
};

/// `GET /discussion`: the mode, leader and players, and the posts after a
/// sequence number.
pub const Discussion = struct {
    last: u64,
    mode: []const u8,
    inspector_for_all: bool,
    /// A name, or "console" for the local side.
    leader: []const u8,
    players: []const Member,
    posts: []const Post,
};

pub const Member = struct {
    name: []const u8,
    ai: bool,
    local: bool,
    leader: bool,
    /// An AI partner who may read the inspector.
    inspector: bool,
};

pub const Post = struct {
    seq: u64,
    time: i64,
    ai: bool,
    /// A name, or "console".
    author: []const u8,
    /// thought, message, command, mode, leader, joined, left, kicked,
    /// password, granted or revoked.
    kind: []const u8,
    text: []const u8,
    suggestions: []const []const u8,
};

/// `GET /events`: the audit log after a sequence number.
pub const Events = struct {
    last: u64,
    events: []const Event,
};

pub const Event = struct {
    seq: u64,
    time: i64,
    kind: []const u8,
    suspicious: bool,
    client: []const u8,
    detail: []const u8,
};

/// `GET /me`: who the server takes the client for.
pub const Me = struct {
    name: ?[]const u8,
    ai: bool,
    local: bool,
    leader: bool,
    listening: bool,
};

/// `GET /state`: the inspector's snapshot.
pub const Snapshot = struct {
    generation: u64,
    turn: u32,
    version: u8,
    release: u16,
    serial: []const u8,
    /// The random number generator's seed, and whether it was drawn at
    /// random rather than given by `--seed` or the story.
    seed: u64,
    seed_random: bool,
    /// The player's room.
    location: u16,
    /// Every object, numbered from 1.
    objects: []const Object,
    /// Objects that changed this turn.
    changed: []const u16,
    globals: []const u16,
    /// The rooms visited, and the moves between them.
    rooms: []const Room,
    edges: []const Edge,
    commands: []const []const u8,
    /// The map is being erased; show only the current room.
    erasing: ?bool = null,

    pub const omit_null = true;

    pub const Object = struct {
        id: u16,
        name: []const u8,
        parent: u16,
        sibling: u16,
        child: u16,
        attrs: []const u16,
        props: []const Property,
    };
    /// A property's number and its data in hex.
    pub const Property = struct { n: u16, d: []const u8 };
    pub const Room = struct { id: u16, name: []const u8 };
    pub const Edge = struct { from: u16, to: u16, dir: []const u8 };

    pub fn get(snap: Snapshot, id: u16) ?Object {
        if (id == 0 or id > snap.objects.len) return null;
        return snap.objects[id - 1];
    }
};

/// Writes `value` as JSON. Null fields are left out of types that say so
/// (`omit_null`) and written as null elsewhere.
pub fn write(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    const T = @TypeOf(value);
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = !@hasDecl(T, "omit_null") }, w);
}

/// `value` as JSON, allocated.
pub fn allocWrite(gpa: Allocator, value: anytype) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(&out.writer, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Reads a reply of type `T`, ignoring fields it doesn't know.
pub fn parse(comptime T: type, arena: Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, json, .{ .ignore_unknown_fields = true });
}

fn expectJson(expected: []const u8, value: anytype) !void {
    const json = try allocWrite(std.testing.allocator, value);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(expected, json);
}

// What the routes wrote before these types; they must stay byte for byte.

test "command replies" {
    try expectJson(
        "{\"id\":1,\"echo\":0,\"offset\":60,\"output\":\"Opening the small mailbox reveals a leaflet.\\n\\n>\"," ++
            "\"status\":[\"West of House\",\"Score: 0   Moves: 1\"]}",
        CommandReply{ .id = 1, .echo = 0, .offset = 60, .output = "Opening the small mailbox reveals a leaflet.\n\n>", .status = &.{ "West of House", "Score: 0   Moves: 1" } },
    );
    try expectJson("{\"id\":7,\"pending\":true}", CommandReply{ .id = 7, .pending = true });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(CommandReply, arena.allocator(), "{\"id\":7,\"pending\":true}");
    try std.testing.expectEqual(null, parsed.output);
}

test "me, transcript and events" {
    try expectJson(
        "{\"name\":null,\"ai\":false,\"local\":true,\"leader\":true,\"listening\":false}",
        Me{ .name = null, .ai = false, .local = true, .leader = true, .listening = false },
    );
    try expectJson(
        "{\"offset\":60,\"waiting\":true,\"mode\":\"turns\",\"text\":\"open mailbox\\n\",\"status\":[\"\",\"\"]}",
        Transcript{ .offset = 60, .waiting = true, .mode = "turns", .text = "open mailbox\n", .status = &.{ "", "" } },
    );
    try expectJson(
        "{\"last\":1,\"events\":[{\"seq\":1,\"time\":1700000000000,\"kind\":\"keyboard\",\"suspicious\":false,\"client\":\"keyboard\",\"detail\":\"look\"}]}",
        Events{ .last = 1, .events = &.{.{ .seq = 1, .time = 1700000000000, .kind = "keyboard", .suspicious = false, .client = "keyboard", .detail = "look" }} },
    );
}

test "discussion" {
    try expectJson(
        "{\"last\":3,\"mode\":\"debate\",\"inspector_for_all\":false,\"leader\":\"console\",\"players\":[" ++
            "{\"name\":\"Claude\",\"ai\":true,\"local\":false,\"leader\":false,\"inspector\":true}],\"posts\":[" ++
            "{\"seq\":2,\"time\":1700000001000,\"ai\":true,\"author\":\"Claude\",\"kind\":\"thought\",\"text\":\"The \\\"mailbox\\\".\",\"suggestions\":[\"open mailbox\",\"north\"]}]}",
        Discussion{
            .last = 3,
            .mode = "debate",
            .inspector_for_all = false,
            .leader = "console",
            .players = &.{.{ .name = "Claude", .ai = true, .local = false, .leader = false, .inspector = true }},
            .posts = &.{.{ .seq = 2, .time = 1700000001000, .ai = true, .author = "Claude", .kind = "thought", .text = "The \"mailbox\".", .suggestions = &.{ "open mailbox", "north" } }},
        },
    );
}

test "snapshot" {
    const snap: Snapshot = .{
        .generation = 4,
        .turn = 2,
        .version = 3,
        .release = 119,
        .serial = "880429",
        .seed = 42,
        .seed_random = true,
        .location = 1,
        .objects = &.{.{ .id = 1, .name = "West of House", .parent = 0, .sibling = 0, .child = 0, .attrs = &.{ 3, 9 }, .props = &.{.{ .n = 18, .d = "42ab" }} }},
        .changed = &.{},
        .globals = &.{ 1, 0 },
        .rooms = &.{.{ .id = 1, .name = "West of House" }},
        .edges = &.{.{ .from = 1, .to = 2, .dir = "n" }},
        .commands = &.{"north"},
    };
    const expected = "{\"generation\":4,\"turn\":2,\"version\":3,\"release\":119,\"serial\":\"880429\",\"seed\":42,\"seed_random\":true,\"location\":1," ++
        "\"objects\":[{\"id\":1,\"name\":\"West of House\",\"parent\":0,\"sibling\":0,\"child\":0,\"attrs\":[3,9],\"props\":[{\"n\":18,\"d\":\"42ab\"}]}]," ++
        "\"changed\":[],\"globals\":[1,0],\"rooms\":[{\"id\":1,\"name\":\"West of House\"}],\"edges\":[{\"from\":1,\"to\":2,\"dir\":\"n\"}],\"commands\":[\"north\"]";
    try expectJson(expected ++ "}", snap);
    var erasing = snap;
    erasing.erasing = true;
    try expectJson(expected ++ ",\"erasing\":true}", erasing);
}

test validName {
    try std.testing.expect(validName("Claude"));
    try std.testing.expect(validName("GPT-5 (scout)"));
    try std.testing.expect(!validName("You"));
    try std.testing.expect(!validName("Console"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a\tb"));
}
