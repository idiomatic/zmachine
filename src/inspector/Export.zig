//! Writes the session journal as a markdown document: the game's text,
//! the commands, and what the players thought and said, with a map drawn
//! in a code block each time the map grew.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol");
const Map = @import("Map.zig");

pub const Meta = struct {
    /// The story file's name without its extension, or empty.
    story: []const u8 = "",
    release: u16,
    serial: []const u8,
    version: u8,
};

/// The document for `entries`, allocated.
pub fn render(gpa: Allocator, meta: Meta, entries: []const protocol.JournalEntry) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var r: Renderer = .{ .gpa = gpa, .w = &out.writer };
    defer r.deinit();
    try r.document(meta, entries);
    return out.toOwnedSlice();
}

const Room = struct { id: u16, name: []const u8 };

/// One map cell is this wide and tall in characters: a box of 16 by 4,
/// (3 high when every name fits on a line), holding a name on up to two lines, and room around it for the lines
/// between boxes.
const cell_w = 18;
const box_w = 16;
/// The characters of a name in a line of a box.
const inner_w = box_w - 2;
/// The most cells across and down a figure may take.
const max_across = 5;
const max_down = 4;

const Renderer = struct {
    gpa: Allocator,
    w: *Io.Writer,
    rooms: std.ArrayList(Room) = .empty,
    edges: std.ArrayList(Map.Edge) = .empty,
    /// Names of the rooms first entered since the last figure.
    fresh: std.ArrayList([]const u8) = .empty,
    current: u16 = 0,
    last_command: []const u8 = "",
    /// The map has grown since the last figure.
    dirty: bool = false,
    game: u32 = 1,
    /// Seeds met so far.
    seeds: u32 = 0,
    /// When the current game began, for the elapsed times.
    game_start: i64 = 0,
    /// The opening text of the game is still to come.
    opening: bool = true,

    fn deinit(r: *Renderer) void {
        r.rooms.deinit(r.gpa);
        r.edges.deinit(r.gpa);
        r.fresh.deinit(r.gpa);
    }

    fn forgetMap(r: *Renderer) void {
        r.rooms.clearRetainingCapacity();
        r.edges.clearRetainingCapacity();
        r.fresh.clearRetainingCapacity();
        r.current = 0;
        r.last_command = "";
        r.dirty = false;
    }

    fn document(r: *Renderer, meta: Meta, entries: []const protocol.JournalEntry) !void {
        const w = r.w;
        try w.writeAll("# Game session\n\n");
        if (meta.story.len > 0) try w.print("Story {s} (release {d}, serial {s}, Z-machine version {d}).", .{ meta.story, meta.release, meta.serial, meta.version }) else try w.print("Story release {d}, serial {s} (Z-machine version {d}).", .{ meta.release, meta.serial, meta.version });
        if (entries.len > 0) {
            const t = stamp(entries[0].time);
            try w.print(" Started {d}-{d:0>2}-{d:0>2} {s} UTC.", .{ t.year, t.month, t.day, t.clock });
        }
        for (entries) |e| {
            if (std.mem.eql(u8, e.kind, "seed")) {
                try w.print(" Random seed {s}.", .{e.text});
                break;
            }
        }
        try w.writeAll("\n\n");
        try r.players(entries);
        try w.writeAll("## Game 1\n\n");
        if (entries.len > 0) r.game_start = entries[0].time;
        var i: usize = 0;
        while (i < entries.len) {
            if (!isChat(entries[i])) {
                try r.entry(entries[i]);
                i += 1;
                continue;
            }
            // Thoughts and messages that follow one another share a block.
            var j = i;
            while (j < entries.len and isChat(entries[j])) j += 1;
            try r.chat(entries[i..j]);
            i = j;
        }
        try r.finish();
    }

    fn players(r: *Renderer, entries: []const protocol.JournalEntry) !void {
        var seen: std.ArrayList(*const protocol.JournalEntry) = .empty;
        defer seen.deinit(r.gpa);
        for (entries) |*e| {
            const kind = std.meta.stringToEnum(Kind, e.kind) orelse continue;
            switch (kind) {
                // Only what a player themself does.
                .command, .thought, .message, .joined => {},
                else => continue,
            }
            if (std.mem.eql(u8, e.author, "game")) continue;
            const known = for (seen.items) |s| {
                if (std.mem.eql(u8, s.author, e.author)) break true;
            } else false;
            if (!known) try seen.append(r.gpa, e);
        }
        if (seen.items.len == 0) return;
        try r.w.writeAll("Players: ");
        for (seen.items, 0..) |e, i| {
            if (i > 0) try r.w.writeAll(", ");
            try r.name(e.author, e.ai);
        }
        try r.w.writeAll(".\n\n");
    }

    fn name(r: *Renderer, author: []const u8, ai: bool) !void {
        if (std.mem.eql(u8, author, "console")) {
            try r.w.writeAll("Console");
        } else {
            try r.w.writeAll(author);
            if (ai) try r.w.writeAll(" (AI)");
        }
    }

    fn entry(r: *Renderer, e: protocol.JournalEntry) !void {
        const w = r.w;
        const kind = std.meta.stringToEnum(Kind, e.kind) orelse return;
        switch (kind) {
            .game => {
                if (r.opening) try w.writeAll("### Opening\n\n");
                r.opening = false;
                try gameQuote(w, e.text);
                try w.writeAll("\n");
            },
            .command => {
                r.last_command = e.text;
                r.opening = false;
                try w.print("### {d} \u{b7} ", .{e.turn});
                try r.name(e.author, e.ai);
                try w.writeAll(" \u{b7} ");
                try inlineCode(w, e.text);
                var buf: [16]u8 = undefined;
                try w.print(" \u{b7} {s}\n\n", .{elapsed(&buf, e.time, r.game_start)});
            },
            .thought, .message => unreachable,
            .mode => try r.event(e, "set the mode to ", e.text),
            .leader => try r.event(e, "passed the lead to ", e.text),
            .kicked => try r.event(e, "kicked ", e.text),
            .granted => try r.event(e, "let ", e.text),
            .revoked => try r.event(e, "stopped ", e.text),
            .joined => try r.event(e, "joined", ""),
            .left => try r.event(e, "left", ""),
            .restarted => {
                try r.finish();
                r.forgetMap();
                r.game += 1;
                r.game_start = e.time;
                r.opening = true;
                try w.print("---\n\n## Game {d}\n\n", .{r.game});
                try r.event(e, "restarted the game", "");
            },
            .room => try r.enter(e.room, e.text),
            .seed => {
                // The first is in the header.
                if (r.seeds > 0) try w.print("> _Random seed {s}._\n\n", .{e.text});
                r.seeds += 1;
            },
        }
    }

    /// Thoughts and messages as a chat log in a code block: the time since
    /// the game began, who, and what, with suggestions beneath.
    fn chat(r: *Renderer, run: []const protocol.JournalEntry) !void {
        const w = r.w;
        var fence: usize = 3;
        var width: usize = 0;
        for (run) |e| {
            fence = @max(fence, fenceFor(e.text, 3));
            for (e.suggestions) |s| fence = @max(fence, fenceFor(s, 3));
            var buf: [16]u8 = undefined;
            width = @max(width, elapsed(&buf, e.time, r.game_start).len);
        }
        try w.splatByteAll('`', fence);
        try w.writeAll("text\n");
        for (run) |e| {
            var buf: [16]u8 = undefined;
            const when = elapsed(&buf, e.time, r.game_start);
            try w.splatByteAll(' ', width - when.len);
            try w.print("{s}  ", .{when});
            try r.name(e.author, e.ai);
            if (std.mem.eql(u8, e.kind, "thought")) try w.writeAll(" [thought]");
            try w.writeAll(":");
            var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, e.text, "\r\n"), '\n');
            var first = true;
            while (lines.next()) |l| {
                const line = std.mem.trimEnd(u8, l, "\r");
                if (first) {
                    if (line.len > 0) try w.print(" {s}", .{line});
                } else {
                    try w.writeAll("\n");
                    try w.splatByteAll(' ', width + 2);
                    try w.writeAll(line);
                }
                first = false;
            }
            try w.writeAll("\n");
            if (e.suggestions.len > 0) {
                try w.splatByteAll(' ', width + 2);
                try w.writeAll("\u{2192} ");
                for (e.suggestions, 0..) |s, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(s);
                }
                try w.writeAll("\n");
            }
        }
        try w.splatByteAll('`', fence);
        try w.writeAll("\n\n");
    }

    /// A line in a block quote saying what a player did.
    fn event(r: *Renderer, e: protocol.JournalEntry, what: []const u8, object: []const u8) !void {
        try r.w.writeAll("> _");
        try r.name(e.author, e.ai);
        try r.w.print(" {s}{s}", .{ what, object });
        if (std.mem.eql(u8, e.kind, "granted")) try r.w.writeAll(" read the inspector");
        if (std.mem.eql(u8, e.kind, "revoked")) try r.w.writeAll(" reading the inspector");
        try r.w.writeAll("._\n\n");
    }

    /// The player came into a room: the map grows if it is new, or the way
    /// there is.
    fn enter(r: *Renderer, id: u16, room_name: []const u8) !void {
        if (id == 0) return;
        var known = false;
        for (r.rooms.items) |room| known = known or room.id == id;
        if (!known) {
            try r.rooms.append(r.gpa, .{ .id = id, .name = room_name });
            try r.fresh.append(r.gpa, room_name);
            r.dirty = true;
        }
        if (r.current != 0 and r.current != id) {
            const before = r.edges.items.len;
            try Map.addEdge(r.gpa, &r.edges, r.current, id, Map.Direction.fromCommand(r.last_command));
            if (r.edges.items.len != before) r.dirty = true;
        }
        r.current = id;
        if (r.dirty) try r.figure(&.{ 2, 1, 0 });
    }

    /// At the end of a game, the map as far as it fits.
    fn finish(r: *Renderer) !void {
        if (r.rooms.items.len > 1) {
            try r.w.writeAll("**The map so far**\n\n");
            try r.figure(&.{ 1000, 3, 2, 1, 0 });
        }
    }

    fn roomName(r: *const Renderer, id: u16) []const u8 {
        for (r.rooms.items) |room| if (room.id == id) return room.name;
        return "?";
    }

    fn indexOf(r: *const Renderer, id: u16) ?usize {
        for (r.rooms.items, 0..) |room, i| if (room.id == id) return i;
        return null;
    }

    /// Draws the rooms within the first of `radii` hops of the player's
    /// room that fits, in a code block.
    fn figure(r: *Renderer, radii: []const u32) !void {
        r.dirty = false;
        const n = r.rooms.items.len;
        if (n == 0) return;
        const ids = try r.gpa.alloc(u16, n);
        defer r.gpa.free(ids);
        for (ids, r.rooms.items) |*id, room| id.* = room.id;
        const cells = try Map.layout(r.gpa, ids, r.edges.items, &.{});
        defer r.gpa.free(cells);

        // Hops from the player's room.
        const dist = try r.gpa.alloc(u32, n);
        defer r.gpa.free(dist);
        @memset(dist, std.math.maxInt(u32));
        dist[r.indexOf(r.current) orelse 0] = 0;
        var changed = true;
        while (changed) {
            changed = false;
            for (r.edges.items) |e| {
                const a = r.indexOf(e.from) orelse continue;
                const b = r.indexOf(e.to) orelse continue;
                if (dist[a] +| 1 < dist[b]) {
                    dist[b] = dist[a] + 1;
                    changed = true;
                }
                if (dist[b] +| 1 < dist[a]) {
                    dist[a] = dist[b] + 1;
                    changed = true;
                }
            }
        }

        const selected = try r.gpa.alloc(bool, n);
        defer r.gpa.free(selected);
        var min_x: i32 = 0;
        var min_y: i32 = 0;
        var across: usize = 1;
        var down: usize = 1;
        for (radii, 0..) |radius, k| {
            var lo_x: i32 = std.math.maxInt(i32);
            var lo_y: i32 = std.math.maxInt(i32);
            var hi_x: i32 = std.math.minInt(i32);
            var hi_y: i32 = std.math.minInt(i32);
            for (cells, 0..) |c, i| {
                selected[i] = dist[i] <= radius;
                if (!selected[i]) continue;
                lo_x = @min(lo_x, c.x);
                lo_y = @min(lo_y, c.y);
                hi_x = @max(hi_x, c.x);
                hi_y = @max(hi_y, c.y);
            }
            min_x = lo_x;
            min_y = lo_y;
            across = @intCast(hi_x - lo_x + 1);
            down = @intCast(hi_y - lo_y + 1);
            if ((across <= max_across and down <= max_down) or k + 1 == radii.len) break;
        }

        var tall = false;
        for (r.rooms.items, 0..) |room, i| tall = tall or (selected[i] and Label.wrap(room.name).count > 1);
        var canvas = try Canvas.init(r.gpa, across, down, if (tall) 4 else 3);
        defer canvas.deinit(r.gpa);
        var legend: Io.Writer.Allocating = .init(r.gpa);
        defer legend.deinit();
        var conditional = false;

        // Lines first, so boxes cover any that pass under them.
        for (r.edges.items, 0..) |e, i| {
            const a = r.indexOf(e.from) orelse continue;
            const b = r.indexOf(e.to) orelse continue;
            if (!selected[a] or !selected[b] or a == b) continue;
            // One line per pair of rooms, drawn for the first move.
            var first = true;
            var one_way = true;
            for (r.edges.items[0..i]) |p| {
                if ((p.from == e.from and p.to == e.to) or (p.from == e.to and p.to == e.from)) first = false;
            }
            for (r.edges.items) |p| {
                if (p.from == e.to and p.to == e.from) one_way = false;
            }
            if (!first) continue;
            conditional = conditional or e.conditional;
            const drawn = canvas.line(
                @intCast(cells[a].x - min_x),
                @intCast(cells[a].y - min_y),
                @intCast(cells[b].x - min_x),
                @intCast(cells[b].y - min_y),
                one_way,
                e.conditional,
            );
            if (!drawn) {
                const w = &legend.writer;
                try w.print("- {s} ", .{r.roomName(e.from)});
                try w.print("{s} ", .{arrowFor(e.dir)});
                try w.print("{s}", .{r.roomName(e.to)});
                if (e.conditional) try w.writeAll(" (not always)");
                try w.writeAll("\n");
            }
        }
        for (cells, 0..) |c, i| {
            if (!selected[i]) continue;
            canvas.box(@intCast(c.x - min_x), @intCast(c.y - min_y), r.rooms.items[i].name, r.rooms.items[i].id == r.current);
        }

        try r.w.writeAll("```text\n");
        try canvas.write(r.w);
        try r.w.writeAll("```\n\n");
        try r.w.writeAll("*You are in **");
        try r.w.writeAll(r.roomName(r.current));
        try r.w.writeAll("**");
        if (r.fresh.items.len > 0) {
            try r.w.writeAll("; new: ");
            for (r.fresh.items, 0..) |f, i| {
                if (i > 0) try r.w.writeAll(", ");
                try r.w.writeAll(f);
            }
        }
        try r.w.writeAll(".");
        if (conditional) try r.w.writeAll(" Dotted lines do not always lead there.");
        try r.w.writeAll("*\n\n");
        if (legend.written().len > 0) try r.w.print("{s}\n", .{legend.written()});
        r.fresh.clearRetainingCapacity();
    }
};

const Kind = enum { game, command, thought, message, mode, leader, joined, left, kicked, granted, revoked, restarted, room, seed };

fn arrowFor(dir: Map.Direction) []const u8 {
    return switch (dir) {
        .up => "\u{2191}",
        .down => "\u{2193}",
        .in => "\u{21e5} in:",
        .out => "\u{21e4} out:",
        .unknown => "\u{2192}",
        .n => "\u{2192} (north)",
        .ne => "\u{2192} (northeast)",
        .e => "\u{2192} (east)",
        .se => "\u{2192} (southeast)",
        .s => "\u{2192} (south)",
        .sw => "\u{2192} (southwest)",
        .w => "\u{2192} (west)",
        .nw => "\u{2192} (northwest)",
    };
}

/// A room's name on up to two lines of a box.
const Label = struct {
    lines: [2][inner_w]u21 = undefined,
    lens: [2]usize = .{ 0, 0 },
    count: usize = 1,

    /// Wraps `text` at spaces into lines of `inner_w` characters. What
    /// does not fit in two lines, or a word wider than a line, ends in an
    /// ellipsis.
    fn wrap(text: []const u8) Label {
        var l: Label = .{};
        var done = false;
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        while (words.next()) |word| {
            if (done) break;
            var cps: [128]u21 = undefined;
            const n = decode(word, &cps);
            var line = l.count - 1;
            const gap: usize = if (l.lens[line] > 0) 1 else 0;
            if (l.lens[line] + gap + n > inner_w) {
                if (l.lens[line] > 0 and line == 0 and n <= inner_w) {
                    // A new line, which the word fits.
                    l.count = 2;
                    line = 1;
                } else if (l.lens[line] > 0 or n > inner_w) {
                    // No room: cut here.
                    var len = l.lens[line];
                    if (len > 0 and len + 2 <= inner_w) {
                        l.lines[line][len] = ' ';
                        len += 1;
                    }
                    const room = inner_w - len;
                    if (room == 0) {
                        len -= 1;
                    } else {
                        for (cps[0..@min(n, room - 1)]) |cp| {
                            l.lines[line][len] = cp;
                            len += 1;
                        }
                    }
                    l.lines[line][len] = '\u{2026}';
                    l.lens[line] = len + 1;
                    done = true;
                    continue;
                }
            }
            if (l.lens[line] > 0) {
                l.lines[line][l.lens[line]] = ' ';
                l.lens[line] += 1;
            }
            for (cps[0..n]) |cp| {
                l.lines[line][l.lens[line]] = cp;
                l.lens[line] += 1;
            }
        }
        return l;
    }

    /// The code points of `text` (bytes, if it is not UTF-8), up to the room
    /// in `out`.
    fn decode(text: []const u8, out: []u21) usize {
        var n: usize = 0;
        if (std.unicode.Utf8View.init(text)) |view| {
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (n == out.len) break;
                out[n] = cp;
                n += 1;
            }
        } else |_| {
            for (text) |b| {
                if (n == out.len) break;
                out[n] = if (b < 0x80) b else '?';
                n += 1;
            }
        }
        return n;
    }
};

/// A grid of characters the map is drawn on.
const Canvas = struct {
    cols: usize,
    rows: usize,
    chars: []u21,
    /// Rows in a box: 4 if any name takes two lines, otherwise 3.
    box_h: usize,

    /// A canvas for `across` by `down` cells.
    fn init(gpa: Allocator, across: usize, down: usize, box_h: usize) !Canvas {
        const cols = across * cell_w;
        const rows = down * (box_h + 1);
        const chars = try gpa.alloc(u21, cols * rows);
        @memset(chars, ' ');
        return .{ .cols = cols, .rows = rows, .chars = chars, .box_h = box_h };
    }

    fn deinit(c: *Canvas, gpa: Allocator) void {
        gpa.free(c.chars);
    }

    fn put(c: *Canvas, row: usize, col: usize, ch: u21) void {
        if (row < c.rows and col < c.cols) c.chars[row * c.cols + col] = ch;
    }

    /// A box for the room in cell (cx, cy), double-lined if the player is
    /// there. The name is wrapped onto two lines, and cut short with an
    /// ellipsis if it needs more.
    fn box(c: *Canvas, cx: usize, cy: usize, room_name: []const u8, here: bool) void {
        const x0 = cx * cell_w;
        const y0 = cy * (c.box_h + 1);
        const set: [6]u21 = if (here)
            .{ '\u{2554}', '\u{2550}', '\u{2557}', '\u{2551}', '\u{255a}', '\u{255d}' }
        else
            .{ '\u{250c}', '\u{2500}', '\u{2510}', '\u{2502}', '\u{2514}', '\u{2518}' };
        for (0..box_w) |i| {
            c.put(y0, x0 + i, set[1]);
            c.put(y0 + c.box_h - 1, x0 + i, set[1]);
            for (1..c.box_h - 1) |row| c.put(y0 + row, x0 + i, ' ');
        }
        c.put(y0, x0, set[0]);
        c.put(y0, x0 + box_w - 1, set[2]);
        c.put(y0 + c.box_h - 1, x0, set[4]);
        c.put(y0 + c.box_h - 1, x0 + box_w - 1, set[5]);
        for (1..c.box_h - 1) |row| {
            c.put(y0 + row, x0, set[3]);
            c.put(y0 + row, x0 + box_w - 1, set[3]);
        }

        const label = Label.wrap(room_name);
        // A name on one line sits in the middle of a 3-high box, and on the
        // upper line of a 4-high one.
        for (0..label.count) |row| {
            const text = label.lines[row][0..label.lens[row]];
            const start = x0 + 1 + (inner_w - text.len) / 2;
            for (text, 0..) |ch, i| c.put(y0 + 1 + row, start + i, ch);
        }
    }

    /// Draws the line for a move between the cells, if they are in a row,
    /// a column, or touching diagonally; false if not. An arrowhead marks a
    /// move that has only been made one way.
    fn line(c: *Canvas, ax: usize, ay: usize, bx: usize, by: usize, one_way: bool, dotted: bool) bool {
        if (ay == by and ax != bx) {
            const left = @min(ax, bx);
            const right = @max(ax, bx);
            const row = ay * (c.box_h + 1) + 1;
            var col = left * cell_w + box_w;
            while (col < right * cell_w) : (col += 1) c.put(row, col, if (dotted) '\u{2504}' else '\u{2500}');
            if (one_way) {
                if (bx > ax) c.put(row, right * cell_w - 1, '\u{25b6}') else c.put(row, left * cell_w + box_w, '\u{25c0}');
            }
            return true;
        }
        if (ax == bx and ay != by) {
            const top = @min(ay, by);
            const bottom = @max(ay, by);
            const col = ax * cell_w + box_w / 2;
            var row = top * (c.box_h + 1) + c.box_h;
            while (row < bottom * (c.box_h + 1)) : (row += 1) c.put(row, col, if (dotted) '\u{2506}' else '\u{2502}');
            if (one_way) {
                if (by > ay) c.put(bottom * (c.box_h + 1) - 1, col, '\u{25bc}') else c.put(top * (c.box_h + 1) + c.box_h, col, '\u{25b2}');
            }
            return true;
        }
        const dx = @as(i64, @intCast(bx)) - @as(i64, @intCast(ax));
        const dy = @as(i64, @intCast(by)) - @as(i64, @intCast(ay));
        if (@abs(dx) == 1 and @abs(dy) == 1) {
            const col = @min(ax, bx) * cell_w + box_w;
            const row = @min(ay, by) * (c.box_h + 1) + c.box_h;
            c.put(row, col, if (dx * dy > 0) '\u{2572}' else '\u{2571}');
            return true;
        }
        return false;
    }

    fn write(c: *const Canvas, w: *Io.Writer) !void {
        // Not the blank row under the last boxes.
        var rows = c.rows;
        while (rows > 1 and std.mem.allEqual(u21, c.chars[(rows - 1) * c.cols ..][0..c.cols], ' ')) rows -= 1;
        for (0..rows) |row| {
            const cells = c.chars[row * c.cols ..][0..c.cols];
            var end = cells.len;
            while (end > 0 and cells[end - 1] == ' ') end -= 1;
            for (cells[0..end]) |ch| try w.print("{u}", .{ch});
            try w.writeAll("\n");
        }
    }
};

/// The length of fence that safely wraps `text`: longer than any run of
/// backticks in it, and at least `min`.
fn fenceFor(text: []const u8, min: usize) usize {
    var longest: usize = 0;
    var run: usize = 0;
    for (text) |ch| {
        run = if (ch == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    return @max(min, longest + 1);
}

/// `text` as inline code, with a delimiter it cannot contain.
fn inlineCode(w: *Io.Writer, text: []const u8) !void {
    const fence = fenceFor(text, 1);
    const pad = text.len > 0 and (text[0] == '`' or text[text.len - 1] == '`');
    try w.splatByteAll('`', fence);
    if (pad) try w.writeAll(" ");
    try w.writeAll(text);
    if (pad) try w.writeAll(" ");
    try w.splatByteAll('`', fence);
}

fn isChat(e: protocol.JournalEntry) bool {
    return std.mem.eql(u8, e.kind, "thought") or std.mem.eql(u8, e.kind, "message");
}

/// The game's text as a block quote, with its markdown escaped, its line
/// breaks kept, and its indentation too.
fn gameQuote(w: *Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\n');
    while (lines.next()) |l| {
        const line = std.mem.trimEnd(u8, l, "\r");
        // A blank line is a paragraph break.
        if (line.len == 0) {
            try w.writeAll(">\n");
            continue;
        }
        try w.writeAll("> ");
        var start: usize = 0;
        while (start < line.len and line[start] == ' ') : (start += 1) try w.writeAll("&nbsp;");
        const rest = line[start..];
        // What would start a list, heading, or rule; or a numbered item.
        if (rest.len > 0 and std.mem.indexOfScalar(u8, "#-+=", rest[0]) != null) try w.writeAll("\\");
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        const numbered = digits > 0 and digits < rest.len and (rest[digits] == '.' or rest[digits] == ')');
        for (rest, 0..) |ch, i| {
            if ((numbered and i == digits) or std.mem.indexOfScalar(u8, "\\`*_[]<>", ch) != null) try w.writeAll("\\");
            try w.writeByte(ch);
        }
        // A hard line break, unless this is the last line.
        if (lines.peek() != null) try w.writeAll("  ");
        try w.writeAll("\n");
    }
}

/// The time since `start` as `+m:ss`, or `+h:mm:ss` from an hour on.
fn elapsed(buf: *[16]u8, time: i64, start: i64) []const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(time - start, 1000)));
    const text = if (secs >= 3600)
        std.fmt.bufPrint(buf, "+{d}:{d:0>2}:{d:0>2}", .{ secs / 3600, secs % 3600 / 60, secs % 60 })
    else
        std.fmt.bufPrint(buf, "+{d}:{d:0>2}", .{ secs / 60, secs % 60 });
    return text catch unreachable;
}

const Stamp = struct {
    year: u16,
    month: u8,
    day: u8,
    clock: [8]u8,
};

/// A time in milliseconds since the epoch, in UTC.
fn stamp(ms: i64) Stamp {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    var s: Stamp = .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = month_day.day_index + 1,
        .clock = undefined,
    };
    _ = std.fmt.bufPrint(&s.clock, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return s;
}

fn je(seq: u64, turn: u32, author: []const u8, ai: bool, kind: []const u8, text: []const u8, room: u16) protocol.JournalEntry {
    return .{ .seq = seq, .time = 1_700_000_000_000 + @as(i64, @intCast(seq)) * 1000, .turn = turn, .ai = ai, .author = author, .kind = kind, .room = room, .text = text, .suggestions = &.{} };
}

test "a session reads as a document with a map that grows" {
    const gpa = std.testing.allocator;
    var thought = je(5, 1, "Ada", true, "thought", "North looks promising.\nTry it.", 0);
    thought.suggestions = &.{ "e", "open `box`" };
    const entries = [_]protocol.JournalEntry{
        je(1, 0, "game", false, "game", "ZORK I\nWest of House", 0),
        je(2, 0, "game", false, "room", "West of House", 64),
        je(3, 1, "console", false, "command", "n", 0),
        je(4, 1, "game", false, "game", "North of House", 0),
        je(5, 1, "game", false, "room", "North of House", 137),
        thought,
        je(6, 1, "Bo", false, "message", "I agree.", 0),
    };
    const text = try render(gpa, .{ .release = 119, .serial = "880429", .version = 3 }, &entries);
    defer gpa.free(text);
    const expect_in = [_][]const u8{
        "# Game session\n",
        "Story release 119, serial 880429 (Z-machine version 3). Started 2023-11-14 22:13:21 UTC.",
        "Players: Console, Ada (AI), Bo.",
        "## Game 1\n",
        "### Opening\n\n> ZORK I  \n> West of House\n\n",
        "### 1 \u{b7} Console \u{b7} `n` \u{b7} +0:02\n\n> North of House\n",
        "```text\n" ++
            "+0:04  Ada (AI) [thought]: North looks promising.\n" ++
            "       Try it.\n" ++
            "       \u{2192} e, open `box`\n" ++
            "+0:05  Bo: I agree.\n" ++
            "```\n",
        // The first figure: one room, the player in it.
        "╔══════════════╗\n",
        "*You are in **West of House**; new: West of House.*",
        // The second: the way north, traveled one way.
        "*You are in **North of House**; new: North of House.*",
        "        \u{25b2}\n",
    };
    for (expect_in) |piece| {
        std.testing.expect(std.mem.indexOf(u8, text, piece) != null) catch |err| {
            std.debug.print("missing {s}\n--- in ---\n{s}\n", .{ piece, text });
            return err;
        };
    }
    // The room North of House is above West of House.
    const north = std.mem.indexOf(u8, text, "North of House\u{2551}").?;
    const west = std.mem.indexOf(u8, text, "West of House \u{2502}").?;
    try std.testing.expect(north < west);
    // The map so far closes the game.
    try std.testing.expect(std.mem.indexOf(u8, text, "**The map so far**") != null);
}

test "a restart begins another game and another map" {
    const gpa = std.testing.allocator;
    const entries = [_]protocol.JournalEntry{
        je(1, 0, "game", false, "room", "West of House", 64),
        je(2, 1, "Ada", true, "command", "restart", 0),
        je(3, 0, "Ada", true, "restarted", "", 0),
        je(4, 0, "game", false, "room", "West of House", 64),
    };
    const text = try render(gpa, .{ .release = 1, .serial = "000000", .version = 3 }, &entries);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "---\n\n## Game 2\n\n> _Ada (AI) restarted the game._") != null);
    // The room is new again in the second game.
    const first = std.mem.indexOf(u8, text, "new: West of House").?;
    try std.testing.expect(std.mem.indexOfPos(u8, text, first + 1, "new: West of House") != null);
}

test "fences and inline code cope with backticks" {
    try std.testing.expectEqual(@as(usize, 3), fenceFor("plain", 3));
    try std.testing.expectEqual(@as(usize, 5), fenceFor("a ```` b", 3));
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try inlineCode(&w, "`x`");
    try std.testing.expectEqualStrings("`` `x` ``", w.buffered());
}

test "game text becomes a block quote that keeps its lines and indentation" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try gameQuote(&w, "You see *a* thing.\n\n  A bottle\n- not a list\n1. not numbered\nx_y [z]\n");
    try std.testing.expectEqualStrings(
        "> You see \\*a\\* thing.  \n" ++
            ">\n" ++
            "> &nbsp;&nbsp;A bottle  \n" ++
            "> \\- not a list  \n" ++
            "> 1\\. not numbered  \n" ++
            "> x\\_y \\[z\\]\n",
        w.buffered(),
    );
}

test "elapsed times count from the start of the game" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("+0:00", elapsed(&buf, 5000, 5000));
    try std.testing.expectEqualStrings("+1:12", elapsed(&buf, 77_000, 5000));
    try std.testing.expectEqualStrings("+1:02:30", elapsed(&buf, 3_750_000, 0));
    // Never negative.
    try std.testing.expectEqualStrings("+0:00", elapsed(&buf, 0, 5000));
}

test "restarting starts the clock again and the opening again" {
    const gpa = std.testing.allocator;
    const entries = [_]protocol.JournalEntry{
        je(1, 0, "game", false, "game", "Intro", 0),
        je(2, 1, "Ada", true, "command", "restart", 0),
        je(100, 0, "Ada", true, "restarted", "", 0),
        je(101, 0, "game", false, "game", "Intro", 0),
        je(104, 1, "Ada", true, "command", "n", 0),
    };
    const text = try render(gpa, .{ .release = 1, .serial = "000000", .version = 3 }, &entries);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "## Game 2\n\n> _Ada (AI) restarted the game._\n\n### Opening\n\n> Intro\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "### 1 \u{b7} Ada (AI) \u{b7} `n` \u{b7} +0:04\n") != null);
    // Only the first text of a game is its opening.
    try std.testing.expect(std.mem.count(u8, text, "### Opening") == 2);
}
