//! Watches a running machine for the web interface: records the rooms the
//! player has visited and the moves between them, and publishes JSON
//! snapshots of the object tree each time the game waits for input.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Machine = @import("vm").Machine;
const protocol = @import("protocol");

const Inspector = @This();

gpa: Allocator,
io: Io,

/// Guards `snapshot`, its arena, `generation` and `erase_map`, which are
/// shared with the server.
mutex: Io.Mutex = .init,
snapshot: ?protocol.Snapshot = null,
snapshot_arena: ?std.heap.ArenaAllocator = null,
generation: u64 = 0,
/// The map is erased before the next snapshot.
erase_map: bool = false,

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
    if (in.snapshot_arena) |*arena| arena.deinit();
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

/// Erases the map at the next snapshot, which starts it again from the
/// player's room.
pub fn eraseMap(in: *Inspector) void {
    in.mutex.lockUncancelable(in.io);
    defer in.mutex.unlock(in.io);
    in.erase_map = true;
    // A new generation, so every open inspector hears of it at once.
    in.generation += 1;
}

/// Returns the latest snapshot as JSON, allocated, if it is newer than
/// `since`.
pub fn latest(in: *Inspector, gpa: Allocator, since: u64) !?[]u8 {
    in.mutex.lockUncancelable(in.io);
    defer in.mutex.unlock(in.io);
    var snap = in.snapshot orelse return null;
    if (in.generation <= since) return null;
    // An erase moves the generation on before the next snapshot. Until
    // that snapshot erases the map, mark this one so the page shows only
    // the current room.
    snap.generation = in.generation;
    if (in.erase_map) snap.erasing = true;
    return try protocol.allocWrite(gpa, snap);
}

fn update(in: *Inspector, m: *Machine) !void {
    const erase = erase: {
        in.mutex.lockUncancelable(in.io);
        defer in.mutex.unlock(in.io);
        defer in.erase_map = false;
        break :erase in.erase_map;
    };
    if (erase) {
        // Start again from the room the player was in when it was erased.
        in.rooms.clearRetainingCapacity();
        in.edges.clearRetainingCapacity();
        if (in.location != 0) try in.rooms.put(in.gpa, in.location, {});
    }
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

    var arena: std.heap.ArenaAllocator = .init(in.gpa);
    errdefer arena.deinit();
    const snap = try in.takeSnapshot(m, arena.allocator(), object_count);

    in.mutex.lockUncancelable(in.io);
    defer in.mutex.unlock(in.io);
    if (in.snapshot_arena) |*old| old.deinit();
    in.snapshot_arena = arena;
    in.snapshot = snap;
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

/// The machine's objects, globals and the map, allocated in `arena`.
fn takeSnapshot(in: *Inspector, m: *Machine, arena: Allocator, object_count: u16) !protocol.Snapshot {
    var name: Machine.TextBuffer = undefined;
    const objects = try arena.alloc(protocol.Snapshot.Object, object_count);
    for (objects, 1..) |*o, i| {
        const obj: u16 = @intCast(i);
        m.objectName(obj, &name);
        var attrs: std.ArrayList(u16) = .empty;
        for (0..m.objects.attributeCount()) |a| {
            if (m.objects.attribute(obj, @intCast(a)) catch false) try attrs.append(arena, @intCast(a));
        }
        var props: std.ArrayList(protocol.Snapshot.Property) = .empty;
        var addr = m.objects.firstProperty(obj) catch 0;
        while (addr != 0) {
            const prop = (m.objects.propertyAt(addr) catch null) orelse break;
            if (prop.data + prop.size > m.memory.len) break;
            const data = m.memory[prop.data..][0..prop.size];
            const hex = try arena.alloc(u8, data.len * 2);
            for (data, 0..) |byte, j| _ = std.fmt.bufPrint(hex[j * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
            try props.append(arena, .{ .n = prop.number, .d = hex });
            addr = prop.next;
        }
        o.* = .{
            .id = obj,
            .name = try arena.dupe(u8, name.slice()),
            .parent = m.objects.parent(obj) catch 0,
            .sibling = m.objects.sibling(obj) catch 0,
            .child = m.objects.child(obj) catch 0,
            .attrs = attrs.items,
            .props = props.items,
        };
    }

    const globals = try arena.alloc(u16, 240);
    for (globals, 0..) |*g, i| g.* = m.readGlobal(@intCast(i)) catch 0;

    const rooms = try arena.alloc(protocol.Snapshot.Room, in.rooms.count());
    for (rooms, in.rooms.keys()) |*r, room| {
        m.objectName(room, &name);
        r.* = .{ .id = room, .name = try arena.dupe(u8, name.slice()) };
    }
    const edges = try arena.alloc(protocol.Snapshot.Edge, in.edges.items.len);
    for (edges, in.edges.items) |*out, e| out.* = .{ .from = e.from, .to = e.to, .dir = @tagName(e.dir) };
    const commands = try arena.alloc([]const u8, in.commands.items.len);
    for (commands, in.commands.items) |*out, c| out.* = try arena.dupe(u8, c);

    return .{
        .generation = in.generation + 1,
        .turn = in.turn,
        .version = m.version,
        .release = std.mem.readInt(u16, m.memory[2..4], .big),
        .serial = try arena.dupe(u8, m.memory[0x12..0x18]),
        .seed = m.seed,
        .seed_random = m.seed_random,
        .location = in.location,
        .objects = objects,
        .changed = try arena.dupe(u16, in.changed.items),
        .globals = globals,
        .rooms = rooms,
        .edges = edges,
        .commands = commands,
    };
}

test "direction from command" {
    try std.testing.expectEqual(Direction.n, Direction.fromCommand("north"));
    try std.testing.expectEqual(Direction.up, Direction.fromCommand("climb up"));
    try std.testing.expectEqual(Direction.sw, Direction.fromCommand("Go SW"));
    try std.testing.expectEqual(Direction.unknown, Direction.fromCommand("n. e"));
    try std.testing.expectEqual(Direction.unknown, Direction.fromCommand("open mailbox"));
}
