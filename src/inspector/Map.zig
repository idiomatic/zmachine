//! The map of visited rooms: the moves between them, and a layout of the
//! rooms on a grid.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

    /// The step on the grid for a compass direction.
    fn step(dir: Direction) ?[2]i32 {
        return switch (dir) {
            .n => .{ 0, -1 },
            .s => .{ 0, 1 },
            .e => .{ 1, 0 },
            .w => .{ -1, 0 },
            .ne => .{ 1, -1 },
            .nw => .{ -1, -1 },
            .se => .{ 1, 1 },
            .sw => .{ -1, 1 },
            else => null,
        };
    }

    /// Where to put a room reached by a move with no compass direction.
    fn fallback(dir: Direction) [2]i32 {
        return switch (dir) {
            .up => .{ 1, -1 },
            .down => .{ -1, 1 },
            .in => .{ 1, 1 },
            .out => .{ -1, -1 },
            else => .{ 1, 1 },
        };
    }

    pub fn inverse(dir: Direction) Direction {
        return switch (dir) {
            .n => .s,
            .s => .n,
            .e => .w,
            .w => .e,
            .ne => .sw,
            .sw => .ne,
            .nw => .se,
            .se => .nw,
            .up => .down,
            .down => .up,
            .in => .out,
            .out => .in,
            .unknown => .unknown,
        };
    }
};

pub const Edge = struct {
    from: u16,
    to: u16,
    dir: Direction,
    /// The same direction from `from` has also led somewhere else, so the
    /// way depends on something in the game.
    conditional: bool = false,
};

/// Records a move, merging it with one already seen between the rooms.
pub fn addEdge(gpa: Allocator, edges: *std.ArrayList(Edge), from: u16, to: u16, dir: Direction) !void {
    const index = for (edges.items, 0..) |*e, i| {
        if (e.from == from and e.to == to) {
            if (e.dir == .unknown) e.dir = dir;
            break i;
        }
    } else blk: {
        try edges.append(gpa, .{ .from = from, .to = to, .dir = dir });
        break :blk edges.items.len - 1;
    };
    const added = &edges.items[index];
    if (added.dir == .unknown) return;
    for (edges.items, 0..) |*e, i| {
        if (i != index and e.from == from and e.dir == added.dir and e.to != to) {
            e.conditional = true;
            added.conditional = true;
        }
    }
}

/// A room fixed at a grid cell.
pub const Cell = struct { id: u16, x: i32, y: i32 };

/// Places each of `rooms` (in the order visited) on a grid, following the
/// moves in `edges`. Rooms in `pins` go first, at their cells. The result
/// is allocated.
pub fn layout(gpa: Allocator, rooms: []const u16, edges: []const Edge, pins: []const Cell) ![]Cell {
    var placer: Placer = .{ .gpa = gpa };
    defer placer.deinit();
    for (rooms) |id| {
        for (pins) |p| {
            if (p.id == id and !placer.taken.contains(.{ p.x, p.y })) try placer.place(id, p.x, p.y);
        }
    }
    if (rooms.len > 0 and !placer.pos.contains(rooms[0])) {
        const cell = placer.near(0, 0);
        try placer.place(rooms[0], cell[0], cell[1]);
    }
    // Exploration order gives a stable, intuitive layout.
    var progress = true;
    while (progress) {
        progress = false;
        for (edges) |e| {
            const has_from = placer.pos.contains(e.from);
            const has_to = placer.pos.contains(e.to);
            if (has_from and !has_to) {
                try placer.placeFrom(e.from, e.to, e.dir);
                progress = true;
            } else if (has_to and !has_from) {
                try placer.placeFrom(e.to, e.from, e.dir.inverse());
                progress = true;
            }
        }
    }
    for (rooms) |id| {
        if (!placer.pos.contains(id)) {
            const cell = placer.near(0, 0);
            try placer.place(id, cell[0], cell[1]);
        }
    }
    const out = try gpa.alloc(Cell, rooms.len);
    for (out, rooms) |*c, id| {
        const cell = placer.pos.get(id).?;
        c.* = .{ .id = id, .x = cell[0], .y = cell[1] };
    }
    return out;
}

const Placer = struct {
    gpa: Allocator,
    pos: std.AutoHashMapUnmanaged(u16, [2]i32) = .empty,
    taken: std.AutoHashMapUnmanaged([2]i32, void) = .empty,

    fn deinit(p: *Placer) void {
        p.pos.deinit(p.gpa);
        p.taken.deinit(p.gpa);
    }

    fn place(p: *Placer, id: u16, x: i32, y: i32) !void {
        try p.pos.put(p.gpa, id, .{ x, y });
        try p.taken.put(p.gpa, .{ x, y }, {});
    }

    /// The free cell nearest (x, y), searching outwards in rings.
    fn near(p: *Placer, x: i32, y: i32) [2]i32 {
        if (!p.taken.contains(.{ x, y })) return .{ x, y };
        var r: i32 = 1;
        while (r < 50) : (r += 1) {
            var dx = -r;
            while (dx <= r) : (dx += 1) {
                var dy = -r;
                while (dy <= r) : (dy += 1) {
                    if (@max(@abs(dx), @abs(dy)) != r) continue;
                    if (!p.taken.contains(.{ x + dx, y + dy })) return .{ x + dx, y + dy };
                }
            }
        }
        return .{ x, y };
    }

    fn placeFrom(p: *Placer, from: u16, to: u16, dir: Direction) !void {
        const f = p.pos.get(from).?;
        const v = dir.step() orelse dir.fallback();
        for ([_]i32{ 1, 2 }) |step| {
            const tx = f[0] + v[0] * step;
            const ty = f[1] + v[1] * step;
            if (!p.taken.contains(.{ tx, ty })) return p.place(to, tx, ty);
        }
        const cell = p.near(f[0] + v[0], f[1] + v[1]);
        try p.place(to, cell[0], cell[1]);
    }
};

/// One line on the map: a pair of rooms, by index, and the direction of
/// the first move seen between them.
const Link = struct { a: u32, b: u32, dir: Direction };

const weight = struct {
    /// A compass move that doesn't point the way it was taken.
    const direction = 10.0;
    /// A diagonal that isn't at 45 degrees, per cell off.
    const slant = 0.5;
    /// Per cell between rooms beyond the first.
    const length = 1.0;
    const crossing = 6.0;
    /// A line passing under a room it doesn't connect.
    const under = 8.0;
};

/// Searches for a layout of `rooms` that follows the moves' directions and
/// has short, uncrossed lines that avoid other rooms, starting from the
/// automatic layout. The same map always gives the same layout. The result
/// is allocated.
pub fn rearrange(gpa: Allocator, rooms: []const u16, edges: []const Edge) ![]Cell {
    const start = try layout(gpa, rooms, edges, &.{});
    defer gpa.free(start);
    return improve(gpa, rooms, edges, start);
}

/// Improves `start` (a cell for each of `rooms`, in order) by moving and
/// swapping rooms, never leaving two in one cell.
pub fn improve(gpa: Allocator, rooms: []const u16, edges: []const Edge, start: []const Cell) ![]Cell {
    var search: Search = .{ .gpa = gpa };
    defer search.deinit();
    try search.init(rooms, edges, start);
    search.run();
    const out = try gpa.alloc(Cell, rooms.len);
    // Keeps the first room where the automatic layout put it.
    const dx = search.pos[0][0] - start[0].x;
    const dy = search.pos[0][1] - start[0].y;
    for (out, rooms, search.pos) |*c, id, p| c.* = .{ .id = id, .x = p[0] - dx, .y = p[1] - dy };
    return out;
}

/// The cost `rearrange` minimizes for `cells`, which are in the order of
/// `rooms`. Zero means every move points the way it was taken, with
/// adjacent rooms, nothing crossing and nothing in the way.
pub fn cost(gpa: Allocator, rooms: []const u16, edges: []const Edge, cells: []const Cell) !f64 {
    var search: Search = .{ .gpa = gpa };
    defer search.deinit();
    try search.init(rooms, edges, cells);
    return search.total();
}

const Search = struct {
    gpa: Allocator,
    links: []Link = &.{},
    /// For each room, the links it is in.
    incident: []std.ArrayList(u32) = &.{},
    pos: [][2]i32 = &.{},
    occupant: std.AutoHashMapUnmanaged([2]i32, u32) = .empty,
    /// Scratch: whether each link touches a room being moved.
    marked: []bool = &.{},
    rng: std.Random.DefaultPrng = .init(0x7a6d),

    fn deinit(s: *Search) void {
        s.gpa.free(s.links);
        for (s.incident) |*list| list.deinit(s.gpa);
        s.gpa.free(s.incident);
        s.gpa.free(s.pos);
        s.gpa.free(s.marked);
        s.occupant.deinit(s.gpa);
    }

    fn init(s: *Search, rooms: []const u16, edges: []const Edge, cells: []const Cell) !void {
        var index: std.AutoHashMapUnmanaged(u16, u32) = .empty;
        defer index.deinit(s.gpa);
        for (rooms, 0..) |id, i| try index.put(s.gpa, id, @intCast(i));

        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(s.gpa);
        for (edges) |e| {
            const a = index.get(e.from) orelse continue;
            const b = index.get(e.to) orelse continue;
            if (a == b) continue;
            // One line per pair of rooms.
            const seen = for (links.items) |l| {
                if ((l.a == a and l.b == b) or (l.a == b and l.b == a)) break true;
            } else false;
            if (!seen) try links.append(s.gpa, .{ .a = a, .b = b, .dir = e.dir });
        }
        s.links = try s.gpa.dupe(Link, links.items);
        s.marked = try s.gpa.alloc(bool, s.links.len);
        @memset(s.marked, false);

        s.incident = try s.gpa.alloc(std.ArrayList(u32), rooms.len);
        for (s.incident) |*list| list.* = .empty;
        for (s.links, 0..) |l, i| {
            try s.incident[l.a].append(s.gpa, @intCast(i));
            try s.incident[l.b].append(s.gpa, @intCast(i));
        }

        s.pos = try s.gpa.alloc([2]i32, rooms.len);
        for (rooms, 0..) |id, i| {
            const cell = for (cells) |c| {
                if (c.id == id) break c;
            } else return error.MissingCell;
            s.pos[i] = .{ cell.x, cell.y };
            try s.occupant.put(s.gpa, s.pos[i], @intCast(i));
        }
    }

    fn linkCost(s: *const Search, l: Link) f64 {
        const dx = s.pos[l.b][0] - s.pos[l.a][0];
        const dy = s.pos[l.b][1] - s.pos[l.a][1];
        const ax: f64 = @floatFromInt(@abs(dx));
        const ay: f64 = @floatFromInt(@abs(dy));
        var c = (@max(ax, ay) - 1) * weight.length;
        if (l.dir.step()) |v| {
            if (std.math.sign(dx) != v[0] or std.math.sign(dy) != v[1]) {
                c += weight.direction;
            } else if (v[0] != 0 and v[1] != 0) {
                c += @abs(ax - ay) * weight.slant;
            }
        }
        return c;
    }

    fn crossCost(s: *const Search, i: u32, j: u32) f64 {
        const p = s.links[i];
        const q = s.links[j];
        if (p.a == q.a or p.a == q.b or p.b == q.a or p.b == q.b) return 0;
        const a = s.pos[p.a];
        const b = s.pos[p.b];
        const c = s.pos[q.a];
        const d = s.pos[q.b];
        const o1 = orient(a, b, c);
        const o2 = orient(a, b, d);
        const o3 = orient(c, d, a);
        const o4 = orient(c, d, b);
        return if (o1 * o2 < 0 and o3 * o4 < 0) weight.crossing else 0;
    }

    fn underCost(s: *const Search, i: u32, room: u32) f64 {
        const l = s.links[i];
        if (room == l.a or room == l.b) return 0;
        const a = s.pos[l.a];
        const b = s.pos[l.b];
        const c = s.pos[room];
        return if (passesThrough(a, b, c)) weight.under else 0;
    }

    /// The cost of everything that involves a link in `moved`'s rooms, or
    /// a room of `moved`'s passing under another link.
    fn local(s: *Search, moved: []const u32) f64 {
        for (moved) |r| for (s.incident[r].items) |i| {
            s.marked[i] = true;
        };
        defer for (moved) |r| for (s.incident[r].items) |i| {
            s.marked[i] = false;
        };
        var sum: f64 = 0;
        for (s.links, 0..) |l, i| {
            if (!s.marked[i]) {
                for (moved) |r| sum += s.underCost(@intCast(i), r);
                continue;
            }
            sum += s.linkCost(l);
            for (s.links, 0..) |_, j| {
                if (j == i or (s.marked[j] and j < i)) continue;
                sum += s.crossCost(@intCast(i), @intCast(j));
            }
            for (s.pos, 0..) |_, r| sum += s.underCost(@intCast(i), @intCast(r));
        }
        return sum;
    }

    fn total(s: *const Search) f64 {
        var sum: f64 = 0;
        for (s.links, 0..) |l, i| {
            sum += s.linkCost(l);
            for (i + 1..s.links.len) |j| sum += s.crossCost(@intCast(i), @intCast(j));
            for (s.pos, 0..) |_, r| sum += s.underCost(@intCast(i), @intCast(r));
        }
        return sum;
    }

    fn run(s: *Search) void {
        const n = s.pos.len;
        if (n < 2 or s.links.len == 0) return;
        const iterations: usize = std.math.clamp(1000 * n, 20_000, 60_000);
        const t_start = 3.0;
        const t_end = 0.1;
        const best = s.gpa.alloc([2]i32, n) catch return;
        defer s.gpa.free(best);
        @memcpy(best, s.pos);
        var best_cost = s.total();
        // Each round cools from hot again, starting from the best so far.
        for (0..4) |_| {
            for (0..iterations) |i| {
                const progress = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(iterations));
                s.attempt(t_start * std.math.pow(f64, t_end / t_start, progress));
            }
            // Then only improvements.
            for (0..iterations / 4) |_| s.attempt(0);
            const c = s.total();
            if (c < best_cost) {
                best_cost = c;
                @memcpy(best, s.pos);
            } else {
                @memcpy(s.pos, best);
            }
            s.occupant.clearRetainingCapacity();
            for (s.pos, 0..) |p, i| s.occupant.putAssumeCapacity(p, @intCast(i));
            if (best_cost == 0) break;
        }
        @memcpy(s.pos, best);
    }

    fn attempt(s: *Search, temperature: f64) void {
        const random = s.rng.random();
        const r = random.uintLessThan(u32, @intCast(s.pos.len));
        const here = s.pos[r];
        const target: [2]i32 = target: {
            const list = s.incident[r].items;
            if (list.len > 0 and random.boolean()) {
                // Next to a neighbor, the way the move between them went.
                const l = s.links[list[random.uintLessThan(usize, list.len)]];
                const other = if (l.a == r) l.b else l.a;
                const dir = if (l.a == other) l.dir else l.dir.inverse();
                const v = dir.step() orelse dir.fallback();
                break :target .{ s.pos[other][0] + v[0], s.pos[other][1] + v[1] };
            }
            break :target .{ here[0] + random.intRangeAtMost(i32, -2, 2), here[1] + random.intRangeAtMost(i32, -2, 2) };
        };
        if (target[0] == here[0] and target[1] == here[1]) return;
        const other = s.occupant.get(target);
        var buf: [2]u32 = .{ r, undefined };
        const moved = if (other) |o| blk: {
            buf[1] = o;
            break :blk buf[0..2];
        } else buf[0..1];

        const before = s.local(moved);
        s.relocate(r, target, other);
        const delta = s.local(moved) - before;
        const accept = delta <= 0 or (temperature > 0 and random.float(f64) < @exp(-delta / temperature));
        if (!accept) s.relocate(r, here, other);
    }

    /// Puts `r` at `target`, where `other` is, if anyone, swapping them.
    fn relocate(s: *Search, r: u32, target: [2]i32, other: ?u32) void {
        const here = s.pos[r];
        s.pos[r] = target;
        if (other) |o| {
            s.pos[o] = here;
            s.occupant.putAssumeCapacity(here, o);
        } else {
            _ = s.occupant.remove(here);
        }
        s.occupant.putAssumeCapacity(target, r);
    }
};

fn orient(a: [2]i32, b: [2]i32, c: [2]i32) i64 {
    const v = @as(i64, b[0] - a[0]) * (c[1] - a[1]) - @as(i64, b[1] - a[1]) * (c[0] - a[0]);
    return std.math.sign(v);
}

/// Whether the line from cell `a` to cell `b` passes through the room
/// drawn in cell `c` (Liang-Barsky clipping against its box).
fn passesThrough(a: [2]i32, b: [2]i32, c: [2]i32) bool {
    const hw = 0.45;
    const hh = 0.32;
    const x1: f64 = @floatFromInt(a[0] - c[0]);
    const y1: f64 = @floatFromInt(a[1] - c[1]);
    const dx: f64 = @floatFromInt(b[0] - a[0]);
    const dy: f64 = @floatFromInt(b[1] - a[1]);
    var t0: f64 = 0;
    var t1: f64 = 1;
    const ps = [_]f64{ -dx, dx, -dy, dy };
    const qs = [_]f64{ x1 + hw, hw - x1, y1 + hh, hh - y1 };
    for (ps, qs) |p, q| {
        if (p == 0) {
            if (q < 0) return false;
        } else {
            const t = q / p;
            if (p < 0) t0 = @max(t0, t) else t1 = @min(t1, t);
        }
    }
    return t0 < t1;
}

test "direction from command" {
    try std.testing.expectEqual(Direction.n, Direction.fromCommand("north"));
    try std.testing.expectEqual(Direction.up, Direction.fromCommand("climb up"));
    try std.testing.expectEqual(Direction.sw, Direction.fromCommand("Go SW"));
    try std.testing.expectEqual(Direction.unknown, Direction.fromCommand("n. e"));
    try std.testing.expectEqual(Direction.unknown, Direction.fromCommand("open mailbox"));
}

test "a direction that led elsewhere makes both moves conditional" {
    const gpa = std.testing.allocator;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try addEdge(gpa, &edges, 1, 2, .n);
    try addEdge(gpa, &edges, 2, 1, .s);
    try std.testing.expect(!edges.items[0].conditional);
    try addEdge(gpa, &edges, 1, 3, .n);
    try std.testing.expect(edges.items[0].conditional);
    try std.testing.expect(edges.items[2].conditional);
    try std.testing.expect(!edges.items[1].conditional);
    // The same move again changes nothing.
    try addEdge(gpa, &edges, 1, 3, .n);
    try std.testing.expectEqual(@as(usize, 3), edges.items.len);
}

test "unknown directions are never conditional" {
    const gpa = std.testing.allocator;
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    try addEdge(gpa, &edges, 1, 2, .unknown);
    try addEdge(gpa, &edges, 1, 3, .unknown);
    try std.testing.expect(!edges.items[0].conditional);
    try std.testing.expect(!edges.items[1].conditional);
}

fn cellOf(cells: []const Cell, id: u16) Cell {
    for (cells) |c| if (c.id == id) return c;
    unreachable;
}

test "layout follows directions, backwards too" {
    const gpa = std.testing.allocator;
    const edges = [_]Edge{
        .{ .from = 1, .to = 2, .dir = .n },
        .{ .from = 3, .to = 1, .dir = .e },
    };
    const cells = try layout(gpa, &.{ 1, 2, 3 }, &edges, &.{});
    defer gpa.free(cells);
    try std.testing.expectEqual(Cell{ .id = 1, .x = 0, .y = 0 }, cellOf(cells, 1));
    try std.testing.expectEqual(Cell{ .id = 2, .x = 0, .y = -1 }, cellOf(cells, 2));
    try std.testing.expectEqual(Cell{ .id = 3, .x = -1, .y = 0 }, cellOf(cells, 3));
}

test "layout never overlaps rooms and respects pins" {
    const gpa = std.testing.allocator;
    const edges = [_]Edge{
        .{ .from = 1, .to = 2, .dir = .e },
        .{ .from = 1, .to = 3, .dir = .e },
        .{ .from = 1, .to = 4, .dir = .up },
    };
    const cells = try layout(gpa, &.{ 1, 2, 3, 4, 5 }, &edges, &.{.{ .id = 2, .x = 5, .y = 5 }});
    defer gpa.free(cells);
    try std.testing.expectEqual(Cell{ .id = 2, .x = 5, .y = 5 }, cellOf(cells, 2));
    for (cells, 0..) |a, i| {
        for (cells[i + 1 ..]) |b| try std.testing.expect(a.x != b.x or a.y != b.y);
    }
}

test "rearranging untangles a scrambled grid" {
    const gpa = std.testing.allocator;
    // A 3x3 grid of rooms, each joined east and south.
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var rooms: [9]u16 = undefined;
    for (&rooms, 0..) |*r, i| r.* = @intCast(i + 1);
    for (0..3) |y| for (0..3) |x| {
        const id: u16 = @intCast(y * 3 + x + 1);
        if (x < 2) try edges.append(gpa, .{ .from = id, .to = id + 1, .dir = .e });
        if (y < 2) try edges.append(gpa, .{ .from = id, .to = id + 3, .dir = .s });
    };
    const scrambled = [_]Cell{
        .{ .id = 1, .x = 2, .y = 2 }, .{ .id = 2, .x = 0, .y = 0 }, .{ .id = 3, .x = 1, .y = 2 },
        .{ .id = 4, .x = 2, .y = 0 }, .{ .id = 5, .x = 0, .y = 1 }, .{ .id = 6, .x = 1, .y = 1 },
        .{ .id = 7, .x = 0, .y = 2 }, .{ .id = 8, .x = 2, .y = 1 }, .{ .id = 9, .x = 1, .y = 0 },
    };
    const before = try cost(gpa, &rooms, edges.items, &scrambled);
    const cells = try improve(gpa, &rooms, edges.items, &scrambled);
    defer gpa.free(cells);
    const after = try cost(gpa, &rooms, edges.items, cells);
    try std.testing.expect(before > 30);
    try std.testing.expectEqual(@as(f64, 0), after);
    // The first room stays put.
    try std.testing.expectEqual(scrambled[0].x, cells[0].x);
    try std.testing.expectEqual(scrambled[0].y, cells[0].y);
}

test "rearranging is repeatable and never overlaps" {
    const gpa = std.testing.allocator;
    const rooms = [_]u16{ 1, 2, 3, 4, 5, 6 };
    const edges = [_]Edge{
        .{ .from = 1, .to = 2, .dir = .n },
        .{ .from = 1, .to = 3, .dir = .n, .conditional = true },
        .{ .from = 2, .to = 4, .dir = .e },
        .{ .from = 3, .to = 5, .dir = .e },
        .{ .from = 4, .to = 6, .dir = .up },
        .{ .from = 6, .to = 1, .dir = .unknown },
    };
    const one = try rearrange(gpa, &rooms, &edges);
    defer gpa.free(one);
    const two = try rearrange(gpa, &rooms, &edges);
    defer gpa.free(two);
    try std.testing.expectEqualSlices(Cell, one, two);
    for (one, 0..) |a, i| {
        for (one[i + 1 ..]) |b| try std.testing.expect(a.x != b.x or a.y != b.y);
    }
    const start = try layout(gpa, &rooms, &edges, &.{});
    defer gpa.free(start);
    try std.testing.expect(try cost(gpa, &rooms, &edges, one) <= try cost(gpa, &rooms, &edges, start));
}

test "a line passing under a room is found" {
    try std.testing.expect(passesThrough(.{ 0, 0 }, .{ 2, 0 }, .{ 1, 0 }));
    try std.testing.expect(!passesThrough(.{ 0, 0 }, .{ 2, 0 }, .{ 1, 1 }));
    try std.testing.expect(!passesThrough(.{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }));
}
