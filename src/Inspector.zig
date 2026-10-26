//! Watches a running machine for the web interface: records the rooms the
//! player has visited and the moves between them, and publishes JSON
//! snapshots of the object tree each time the game waits for input.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Machine = @import("Machine.zig");

const Inspector = @This();

gpa: Allocator,
io: Io,

/// Guards `snapshot` and `generation`, which are shared with the server.
mutex: Io.Mutex = .init,
snapshot: []u8 = &.{},
generation: u64 = 0,

// The rest is only touched on the interpreter thread.
rooms: std.AutoArrayHashMapUnmanaged(u16, void) = .empty,
edges: std.ArrayList(Edge) = .empty,
commands: std.ArrayList([]u8) = .empty,
hashes: []u64 = &.{},
changed: std.ArrayList(u16) = .empty,
location: u16 = 0,
last_command: []const u8 = "",
turn: u32 = 0,

const max_commands = 200;

pub const Direction = enum {
    n,
    ne,
    e,
    se,
    s,
    sw,
    w,
    nw,
    up,
    down,
    in,
    out,
    unknown,

    const words = std.StaticStringMap(Direction).initComptime(.{
        .{ "n", .n },         .{ "north", .n },
        .{ "ne", .ne },       .{ "northeast", .ne },
        .{ "e", .e },         .{ "east", .e },
        .{ "se", .se },       .{ "southeast", .se },
        .{ "s", .s },         .{ "south", .s },
        .{ "sw", .sw },       .{ "southwest", .sw },
        .{ "w", .w },         .{ "west", .w },
        .{ "nw", .nw },       .{ "northwest", .nw },
        .{ "u", .up },        .{ "up", .up },
        .{ "d", .down },      .{ "down", .down },
        .{ "in", .in },       .{ "inside", .in },
        .{ "enter", .in },    .{ "out", .out },
        .{ "outside", .out }, .{ "exit", .out },
        .{ "leave", .out },
    });

    /// Works out which way a command moved the player, if it names
    /// exactly one direction.
    pub fn fromCommand(command: []const u8) Direction {
        var buf: [128]u8 = undefined;
        const lower = std.ascii.lowerString(buf[0..@min(command.len, buf.len)], command[0..@min(command.len, buf.len)]);
        var found: Direction = .unknown;
        var sentences = std.mem.tokenizeAny(u8, lower, ".,");
        var sentence_count: usize = 0;
        while (sentences.next()) |sentence| {
            sentence_count += 1;
            var it = std.mem.tokenizeScalar(u8, sentence, ' ');
            var word = it.next() orelse continue;
            const climb = std.mem.eql(u8, word, "climb");
            if (climb or std.mem.eql(u8, word, "go") or std.mem.eql(u8, word, "walk") or
                std.mem.eql(u8, word, "run"))
            {
                word = it.next() orelse "";
            }
            if (words.get(word)) |dir| {
                found = dir;
            } else if (climb) {
                // "climb tree", "climb stairs": usually upwards.
                found = .up;
            }
        }
        return if (sentence_count == 1) found else .unknown;
    }
};

pub const Edge = struct {
    from: u16,
    to: u16,
    dir: Direction,
};

pub fn init(gpa: Allocator, io: Io) Inspector {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(in: *Inspector) void {
    in.gpa.free(in.snapshot);
    in.gpa.free(in.hashes);
    in.rooms.deinit(in.gpa);
    in.edges.deinit(in.gpa);
    for (in.commands.items) |c| in.gpa.free(c);
    in.commands.deinit(in.gpa);
    in.changed.deinit(in.gpa);
}

pub fn observer(in: *Inspector) Machine.Observer {
    return .{
        .context = in,
        .beforeInput = beforeInput,
        .afterInput = afterInput,
    };
}

fn beforeInput(context: *anyopaque, m: *Machine) void {
    const in: *Inspector = @ptrCast(@alignCast(context));
    in.update(m) catch |err| std.log.warn("inspector: {s}", .{@errorName(err)});
}

fn afterInput(context: *anyopaque, m: *Machine, line: []const u8) void {
    _ = m;
    const in: *Inspector = @ptrCast(@alignCast(context));
    const copy = in.gpa.dupe(u8, line) catch return;
    if (in.commands.items.len >= max_commands) {
        in.gpa.free(in.commands.orderedRemove(0));
    }
    in.commands.append(in.gpa, copy) catch {
        in.gpa.free(copy);
        return;
    };
    in.last_command = copy;
    in.turn += 1;
}

/// Returns a copy of the latest snapshot if it is newer than `since`.
pub fn latest(in: *Inspector, gpa: Allocator, since: u64) !?[]u8 {
    in.mutex.lockUncancelable(in.io);
    defer in.mutex.unlock(in.io);
    if (in.generation <= since or in.snapshot.len == 0) return null;
    return try gpa.dupe(u8, in.snapshot);
}

fn update(in: *Inspector, m: *Machine) !void {
    const object_count = m.objects.count();
    const here = m.readGlobal(0) catch 0;
    if (here != 0 and here <= object_count) {
        if (in.location != 0 and here != in.location) {
            try in.addEdge(in.location, here, Direction.fromCommand(in.last_command));
        }
        in.location = here;
        try in.rooms.put(in.gpa, here, {});
    }
    try in.detectChanges(m, object_count);

    var out: Io.Writer.Allocating = .init(in.gpa);
    defer out.deinit();
    try in.writeJson(m, &out.writer, object_count);

    in.mutex.lockUncancelable(in.io);
    defer in.mutex.unlock(in.io);
    in.gpa.free(in.snapshot);
    in.snapshot = try out.toOwnedSlice();
    in.generation += 1;
}

fn addEdge(in: *Inspector, from: u16, to: u16, dir: Direction) !void {
    for (in.edges.items) |*e| {
        if (e.from == from and e.to == to) {
            if (e.dir == .unknown) e.dir = dir;
            return;
        }
    }
    try in.edges.append(in.gpa, .{ .from = from, .to = to, .dir = dir });
}

fn hashObject(m: *Machine, obj: u16) u64 {
    var h = std.hash.Wyhash.init(obj);
    const entry = m.objects.entry(obj) catch return 0;
    const entry_size: usize = if (m.version <= 3) 9 else 14;
    h.update(m.memory[entry..][0..entry_size]);
    var addr = m.objects.firstProperty(obj) catch return h.final();
    while (m.objects.propertyAt(addr) catch null) |prop| : (addr = prop.next) {
        if (prop.data + prop.size > m.memory.len) break;
        h.update(m.memory[addr .. prop.data + prop.size]);
    }
    return h.final();
}

fn detectChanges(in: *Inspector, m: *Machine, object_count: u16) !void {
    in.changed.clearRetainingCapacity();
    const first_run = in.hashes.len != object_count;
    if (first_run) {
        in.gpa.free(in.hashes);
        in.hashes = try in.gpa.alloc(u64, object_count);
    }
    for (in.hashes, 1..) |*slot, obj| {
        const h = hashObject(m, @intCast(obj));
        if (!first_run and slot.* != h) try in.changed.append(in.gpa, @intCast(obj));
        slot.* = h;
    }
}

fn writeString(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn writeJson(in: *Inspector, m: *Machine, w: *Io.Writer, object_count: u16) !void {
    try w.print("{{\"generation\":{d},\"turn\":{d},\"version\":{d},\"release\":{d},\"serial\":", .{
        in.generation + 1, in.turn, m.version, std.mem.readInt(u16, m.memory[2..4], .big),
    });
    try writeString(w, m.memory[0x12..0x18]);
    try w.print(",\"location\":{d}", .{in.location});

    var name: Machine.TextBuffer = undefined;
    try w.writeAll(",\"objects\":[");
    for (1..@as(usize, object_count) + 1) |i| {
        const obj: u16 = @intCast(i);
        if (i > 1) try w.writeAll(",");
        m.objectName(obj, &name);
        try w.print("{{\"id\":{d},\"name\":", .{obj});
        try writeString(w, name.slice());
        try w.print(",\"parent\":{d},\"sibling\":{d},\"child\":{d},\"attrs\":[", .{
            m.objects.parent(obj) catch 0,
            m.objects.sibling(obj) catch 0,
            m.objects.child(obj) catch 0,
        });
        var first = true;
        for (0..m.objects.attributeCount()) |a| {
            if (m.objects.attribute(obj, @intCast(a)) catch false) {
                if (!first) try w.writeAll(",");
                try w.print("{d}", .{a});
                first = false;
            }
        }
        try w.writeAll("],\"props\":[");
        first = true;
        var addr = m.objects.firstProperty(obj) catch 0;
        while (addr != 0) {
            const prop = (m.objects.propertyAt(addr) catch null) orelse break;
            if (prop.data + prop.size > m.memory.len) break;
            if (!first) try w.writeAll(",");
            try w.print("{{\"n\":{d},\"d\":\"", .{prop.number});
            try w.printHex(m.memory[prop.data..][0..prop.size], .lower);
            try w.writeAll("\"}");
            first = false;
            addr = prop.next;
        }
        try w.writeAll("]}");
    }

    try w.writeAll("],\"changed\":[");
    for (in.changed.items, 0..) |obj, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{d}", .{obj});
    }

    try w.writeAll("],\"globals\":[");
    for (0..240) |i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{d}", .{m.readGlobal(@intCast(i)) catch 0});
    }

    try w.writeAll("],\"rooms\":[");
    for (in.rooms.keys(), 0..) |room, i| {
        if (i > 0) try w.writeAll(",");
        m.objectName(room, &name);
        try w.print("{{\"id\":{d},\"name\":", .{room});
        try writeString(w, name.slice());
        try w.writeAll("}");
    }

    try w.writeAll("],\"edges\":[");
    for (in.edges.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"from\":{d},\"to\":{d},\"dir\":\"{s}\"}}", .{ e.from, e.to, @tagName(e.dir) });
    }

    try w.writeAll("],\"commands\":[");
    for (in.commands.items, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try writeString(w, c);
    }
    try w.writeAll("]}");
}

test "direction from command" {
    try std.testing.expectEqual(Direction.n, Direction.fromCommand("north"));
    try std.testing.expectEqual(Direction.up, Direction.fromCommand("climb up"));
    try std.testing.expectEqual(Direction.sw, Direction.fromCommand("Go SW"));
    try std.testing.expectEqual(Direction.unknown, Direction.fromCommand("n. e"));
    try std.testing.expectEqual(Direction.unknown, Direction.fromCommand("open mailbox"));
}
