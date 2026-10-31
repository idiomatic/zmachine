//! One game, many inputs: the keyboard, read on a thread of its own, and
//! commands from the web, so the interpreter can wait for both at once;
//! the replies to web commands; and the game text and status line a player
//! sees. It knows nothing of players or leaders: `hooks` hears of each line
//! the game takes.
//!
//! The hooks run under the hub's lock, so code that also takes the
//! group's lock takes the hub's first.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Display = @import("vm").Display;
const InputSource = @import("console").InputSource;

const Hub = @This();

gpa: Allocator,
io: Io,
/// Guards everything below, which the interpreter, keyboard and server
/// threads share.
mutex: Io.Mutex = .init,

hooks: ?Hooks = null,

keyboard: std.ArrayList(u8) = .empty,
keyboard_closed: bool = false,

queue: std.ArrayList(Command) = .empty,
next_id: u64 = 1,
/// The web command the game is answering, and where its reply starts.
answering: ?u64 = null,
answer_echo: u64 = 0,
answer_start: u64 = 0,
replies: std.ArrayList(Reply) = .empty,
/// The game is waiting for input.
idle: bool = false,

/// The game text as a player sees it, without line wrapping.
text: std.ArrayList(u8) = .empty,
/// Offset of `text.items[0]` in all the text printed so far.
text_base: u64 = 0,
status: [2]std.ArrayList(u8) = .{ .empty, .empty },
/// The story drew a status line (versions 1 to 3); otherwise the rows of
/// its upper window stand in for one, when it has few.
has_status: bool = false,
upper: [upper_rows][upper_cols]u8 = undefined,
upper_lens: [upper_rows]usize = @splat(0),
/// The deepest row printed to (zero if none); past `upper_rows` it is no status line.
upper_depth: usize = 0,
/// Which story is loaded and its random seed, for `GET /story`.
story: ?Story = null,
/// The display the game draws on, seen through `display`.
seen: Seen = undefined,

const max_text = 256 * 1024;
const max_replies = 64;

/// Who sent a command from the web: a name, or null for a local client
/// that gives none.
pub const Sender = struct {
    name: ?[]const u8 = null,
    ai: bool = false,
};

/// Hears of each line the game takes: `sender` is null for the keyboard.
/// Console commands aren't lines the game takes.
pub const Hooks = struct {
    context: *anyopaque,
    taken: *const fn (context: *anyopaque, sender: ?Sender, line: []const u8) void,
};

const Command = struct {
    id: u64,
    player: ?[]u8,
    ai: bool,
    text: []u8,
};

const Reply = struct {
    id: u64,
    /// Where the echoed command starts, and where the game's answer starts
    /// and ends.
    echo: u64,
    start: u64,
    end: u64,
};

pub fn init(gpa: Allocator, io: Io) Hub {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(h: *Hub) void {
    h.keyboard.deinit(h.gpa);
    for (h.queue.items) |c| freeCommand(h.gpa, c);
    h.queue.deinit(h.gpa);
    h.replies.deinit(h.gpa);
    h.text.deinit(h.gpa);
    if (h.story) |s| h.gpa.free(s.file);
    for (&h.status) |*s| s.deinit(h.gpa);
}

/// The loaded story, read from its header.
pub const Story = struct {
    /// The story file's name.
    file: []u8,
    /// The Z-machine version.
    zversion: u8,
    release: u16,
    serial: [6]u8,
    seed: u64 = 0,
    seed_random: bool = true,
};

/// Notes the story loaded from `file`, whose bytes are `bytes`.
pub fn setStory(h: *Hub, file: []const u8, bytes: []const u8) error{ OutOfMemory, InvalidStory }!void {
    if (bytes.len < 0x18) return error.InvalidStory;
    const copy = try h.gpa.dupe(u8, file);
    h.lock();
    defer h.unlock();
    if (h.story) |old| h.gpa.free(old.file);
    h.story = .{
        .file = copy,
        .zversion = bytes[0],
        .release = std.mem.readInt(u16, bytes[2..4], .big),
        .serial = bytes[0x12..0x18].*,
    };
}

/// Notes the seed the generator last started from.
pub fn setSeed(h: *Hub, seed: u64, random: bool) void {
    h.lock();
    defer h.unlock();
    if (h.story) |*s| {
        s.seed = seed;
        s.seed_random = random;
    }
}

/// The story and seed, with the file name copied into `arena`.
pub fn storyInfo(h: *Hub, arena: Allocator) Allocator.Error!?Story {
    h.lock();
    defer h.unlock();
    var s = h.story orelse return null;
    s.file = try arena.dupe(u8, s.file);
    return s;
}

fn freeCommand(gpa: Allocator, c: Command) void {
    if (c.player) |name| gpa.free(name);
    gpa.free(c.text);
}

fn lock(h: *Hub) void {
    h.mutex.lockUncancelable(h.io);
}

fn unlock(h: *Hub) void {
    h.mutex.unlock(h.io);
}

/// Starts reading the keyboard (standard input) on its own thread.
pub fn startKeyboard(h: *Hub) !void {
    const thread = try std.Thread.spawn(.{}, readKeyboard, .{h});
    thread.detach();
}

fn readKeyboard(h: *Hub) void {
    var buf: [512]u8 = undefined;
    while (true) {
        const n = Io.File.stdin().readStreaming(h.io, &.{&buf}) catch break;
        h.lock();
        defer h.unlock();
        h.keyboard.appendSlice(h.gpa, buf[0..n]) catch break;
    }
    h.lock();
    defer h.unlock();
    h.keyboard_closed = true;
}

// Interpreter side

pub const ConsoleCommand = enum {
    /// Take back the leadership for the local side.
    lead,
    /// Change the password.
    password,
    /// Show the password in the status line.
    showpassword,
    /// Show or set the mode (`/mode turns`).
    mode,
    /// Clear the discussion.
    clear,
    /// List the console commands.
    help,
    /// List the players.
    who,
    /// Pass the lead to a player (`/promote name`).
    promote,
    /// Remove a remote player or AI partner (`/kick name`).
    kick,
    /// Let an AI partner read the inspector (`/grant name`).
    grant,
    /// Stop an AI partner reading the inspector (`/revoke name`).
    revoke,
    /// Post a message to the discussion as the console (`/say text`).
    say,
    /// Show the last lines of the audit log (`/log [n]`).
    log,
    /// Show an invite link on the bottom row.
    invite,
};

/// The text after the slash of a console command (its name, then any
/// arguments), if `line` is one.
fn consoleCommand(line: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, line, " \t");
    if (text.len < 2 or text[0] != '/') return null;
    const name = text[1 .. std.mem.indexOfAny(u8, text, " \t") orelse text.len];
    _ = std.meta.stringToEnum(ConsoleCommand, name) orelse return null;
    return text[1..];
}

/// Takes the next complete line from the keyboard or the web, copied into
/// `buf`, and adds it to the game text.
pub fn takeLine(h: *Hub, buf: []u8) InputSource.Line {
    h.lock();
    defer h.unlock();
    if (h.takeKeyboardLine(buf)) |line| {
        if (consoleCommand(line)) |command| return .{ .console = command };
        if (h.hooks) |k| k.taken(k.context, null, line);
        h.appendText(line);
        h.appendText("\n");
        return .{ .keyboard = line };
    }
    if (h.takeWeb(buf)) |command| {
        if (h.hooks) |k| k.taken(k.context, .{ .name = command.player, .ai = command.ai }, command.line);
        if (command.player) |name| h.gpa.free(name);
        h.appendText(command.line);
        h.appendText("\n");
        h.answer_start = h.textEnd();
        return .{ .web = command.line };
    }
    return if (h.keyboard_closed) .closed else .none;
}

/// Takes the next key from the keyboard, or a line of keys from the web.
/// With `by_line`, keyboard input is piped and arrives as lines too. With
/// `web` false, only the keyboard is read.
pub fn takeKey(h: *Hub, buf: []u8, by_line: bool, web: bool) InputSource.Key {
    h.lock();
    defer h.unlock();
    if (by_line) {
        if (h.takeKeyboardLine(buf)) |line| return .{ .line = line };
    } else if (h.keyboard.items.len > 0) {
        return .{ .key = h.keyboard.orderedRemove(0) };
    }
    if (web) {
        if (h.takeWeb(buf)) |command| {
            if (command.player) |name| h.gpa.free(name);
            return .{ .line = command.line };
        }
    }
    return if (h.keyboard_closed) .closed else .none;
}

/// The keyboard and the web as the screen's input.
pub fn input(h: *Hub) InputSource {
    const gen = struct {
        fn cast(c: *anyopaque) *Hub {
            return @ptrCast(@alignCast(c));
        }
        fn waiting(c: *anyopaque) void {
            cast(c).waiting();
        }
        fn takeLine(c: *anyopaque, buf: []u8) InputSource.Error!InputSource.Line {
            return cast(c).takeLine(buf);
        }
        fn takeKey(c: *anyopaque, buf: []u8, by_line: bool, web: bool) InputSource.Error!InputSource.Key {
            return cast(c).takeKey(buf, by_line, web);
        }
        fn keyboardPending(c: *anyopaque) bool {
            return cast(c).keyboardPending();
        }
        fn takeKeyboardByte(c: *anyopaque) ?u8 {
            return cast(c).takeKeyboardByte();
        }
        fn webPending(c: *anyopaque) bool {
            return cast(c).pending();
        }
    };
    return .{ .context = h, .vtable = &.{
        .waiting = gen.waiting,
        .takeLine = gen.takeLine,
        .takeKey = gen.takeKey,
        .keyboardPending = gen.keyboardPending,
        .takeKeyboardByte = gen.takeKeyboardByte,
        .webPending = gen.webPending,
    } };
}

/// Whether keys have arrived from the keyboard that nothing has taken yet.
pub fn keyboardPending(h: *Hub) bool {
    h.lock();
    defer h.unlock();
    return h.keyboard.items.len > 0;
}

/// Takes a byte that has already arrived from the keyboard, for the rest
/// of an escape sequence.
pub fn takeKeyboardByte(h: *Hub) ?u8 {
    h.lock();
    defer h.unlock();
    if (h.keyboard.items.len == 0) return null;
    return h.keyboard.orderedRemove(0);
}

fn takeKeyboardLine(h: *Hub, buf: []u8) ?[]u8 {
    const items = h.keyboard.items;
    const end = if (std.mem.indexOfScalar(u8, items, '\n')) |nl|
        nl
    else if (h.keyboard_closed and items.len > 0)
        items.len
    else
        return null;
    const line = std.mem.trimEnd(u8, items[0..end], "\r");
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    h.keyboard.replaceRangeAssumeCapacity(0, @min(end + 1, items.len), &.{});
    h.idle = false;
    return buf[0..n];
}

fn takeWeb(h: *Hub, buf: []u8) ?struct { line: []u8, player: ?[]u8, ai: bool } {
    if (h.queue.items.len == 0) return null;
    const command = h.queue.orderedRemove(0);
    defer h.gpa.free(command.text);
    const n = @min(command.text.len, buf.len);
    @memcpy(buf[0..n], command.text[0..n]);
    h.answering = command.id;
    h.answer_echo = h.textEnd();
    h.answer_start = h.textEnd();
    h.idle = false;
    return .{ .line = buf[0..n], .player = command.player, .ai = command.ai };
}

/// Called each time the game starts waiting for new input: the reply to
/// the web command it was answering is complete.
pub fn waiting(h: *Hub) void {
    h.lock();
    defer h.unlock();
    h.idle = true;
    const id = h.answering orelse return;
    h.answering = null;
    if (h.replies.items.len >= max_replies) _ = h.replies.orderedRemove(0);
    h.replies.append(h.gpa, .{
        .id = id,
        .echo = h.answer_echo,
        .start = h.answer_start,
        .end = h.textEnd(),
    }) catch {};
}

/// Whether a web command is waiting to be read.
pub fn pending(h: *Hub) bool {
    h.lock();
    defer h.unlock();
    return h.queue.items.len > 0;
}

/// `screen` as the game draws on it, keeping what it prints in the lower
/// window and the status line for players on the web.
pub fn display(h: *Hub, screen: Display) Display {
    h.seen = .{ .hub = h, .screen = screen };
    return .from(&h.seen);
}

/// A display passing everything on to the screen, and the game text and
/// status line to the hub too.
const Seen = struct {
    hub: *Hub,
    screen: Display,
    window: u8 = 0,
    /// The upper window's cursor, kept here because a screen that is not a
    /// terminal does not move its own.
    row: u16 = 1,
    col: u16 = 1,

    pub fn print(v: *Seen, cp: u21) Display.Error!void {
        if (v.window == 1) {
            if (cp == '\n') {
                v.row += 1;
                v.col = 1;
            } else {
                v.hub.putUpper(v.row, v.col - 1, cp);
                v.col += 1;
            }
        }
        if (v.window == 0) {
            var utf8: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &utf8) catch blk: {
                utf8[0] = '?';
                break :blk 1;
            };
            v.hub.capture(utf8[0..len]);
        }
        return v.screen.print(cp);
    }
    pub fn setWindow(v: *Seen, window: u8) Display.Error!void {
        v.window = window;
        if (window == 1) {
            v.row = 1;
            v.col = 1;
        }
        return v.screen.setWindow(window);
    }
    pub fn drawStatus(v: *Seen, left: []const u8, right: []const u8) Display.Error!void {
        v.hub.setStatus(left, right);
        return v.screen.drawStatus(left, right);
    }
    pub fn splitWindow(v: *Seen, lines: u16) Display.Error!void {
        return v.screen.splitWindow(lines);
    }
    pub fn eraseWindow(v: *Seen, which: i16) Display.Error!void {
        if (which == 1 or which == -1 or which == -2) {
            v.hub.clearUpper();
            v.row = 1;
            v.col = 1;
        }
        return v.screen.eraseWindow(which);
    }
    pub fn eraseLine(v: *Seen) Display.Error!void {
        return v.screen.eraseLine();
    }
    pub fn setCursor(v: *Seen, row: u16, col: u16) Display.Error!void {
        if (v.window == 1) {
            v.row = @max(row, 1);
            v.col = @max(col, 1);
        }
        return v.screen.setCursor(row, col);
    }
    pub fn getCursor(v: *Seen) [2]u16 {
        return v.screen.getCursor();
    }
    pub fn setStyle(v: *Seen, style: u8) Display.Error!void {
        return v.screen.setStyle(style);
    }
    pub fn setColor(v: *Seen, fg: u16, bg: u16) Display.Error!void {
        return v.screen.setColor(fg, bg);
    }
    pub fn setBuffered(v: *Seen, on: bool) Display.Error!void {
        return v.screen.setBuffered(on);
    }
    pub fn readLine(v: *Seen, buf: []u8) Display.Error!?[]u8 {
        return v.screen.readLine(buf);
    }
    pub fn readKey(v: *Seen) Display.Error!?u8 {
        return v.screen.readKey();
    }
    pub fn capabilities(v: *Seen) Display.Capabilities {
        return v.screen.capabilities();
    }
};

/// Adds text the game printed in the lower window.
pub fn capture(h: *Hub, bytes: []const u8) void {
    h.lock();
    defer h.unlock();
    h.appendText(bytes);
}

const upper_cols = 160;
const upper_rows = 4;

/// Puts a character in the upper window, at a one-based row and zero-based column.
fn putUpper(h: *Hub, row: usize, col: usize, cp: u21) void {
    if (col >= upper_cols or row == 0) return;
    h.lock();
    defer h.unlock();
    h.upper_depth = @max(h.upper_depth, row);
    if (row > upper_rows) return;
    const line = &h.upper[row - 1];
    var len = h.upper_lens[row - 1];
    while (len < col) : (len += 1) line[len] = ' ';
    line[col] = if (cp >= 32 and cp < 127) @intCast(cp) else if (cp < 32) ' ' else '?';
    h.upper_lens[row - 1] = @max(len, col + 1);
}

fn clearUpper(h: *Hub) void {
    h.lock();
    defer h.unlock();
    h.upper_lens = @splat(0);
    h.upper_depth = 0;
}

pub fn setStatus(h: *Hub, left: []const u8, right: []const u8) void {
    h.lock();
    defer h.unlock();
    h.has_status = true;
    for (&h.status, [_][]const u8{ left, right }) |*s, text| {
        s.clearRetainingCapacity();
        s.appendSlice(h.gpa, text) catch {};
    }
}

fn textEnd(h: *const Hub) u64 {
    return h.text_base + h.text.items.len;
}

fn appendText(h: *Hub, bytes: []const u8) void {
    h.text.appendSlice(h.gpa, bytes) catch return;
    if (h.text.items.len <= max_text) return;
    // Drop the older half, cutting at the start of a character.
    var cut = h.text.items.len / 2;
    while (cut < h.text.items.len and h.text.items[cut] & 0xc0 == 0x80) cut += 1;
    h.text.replaceRangeAssumeCapacity(0, cut, &.{});
    h.text_base += cut;
}

/// Forgets the game text so far (a restart); offsets stay valid.
pub fn clearText(h: *Hub) void {
    h.lock();
    defer h.unlock();
    h.text_base += h.text.items.len;
    h.text.clearRetainingCapacity();
}

// Server side

/// Queues a command from the web, which the caller has checked, and
/// returns its id.
pub fn submit(h: *Hub, sender: Sender, text: []const u8) error{OutOfMemory}!u64 {
    h.lock();
    defer h.unlock();
    const copy = try h.gpa.dupe(u8, text);
    errdefer h.gpa.free(copy);
    const name = if (sender.name) |n| try h.gpa.dupe(u8, n) else null;
    errdefer if (name) |n| h.gpa.free(n);
    const id = h.next_id;
    try h.queue.append(h.gpa, .{ .id = id, .player = name, .ai = sender.ai, .text = copy });
    h.next_id += 1;
    return id;
}

/// The game's reply to a web command.
pub const Answer = struct {
    /// Where the echoed command starts in the game text.
    echo: u64,
    /// The offset just past the reply.
    offset: u64,
    output: []const u8,
    status: [2][]const u8,
};

/// The reply to command `id`, copied into `arena`, if the game has
/// finished answering it.
pub fn takeAnswer(h: *Hub, arena: Allocator, id: u64) Allocator.Error!?Answer {
    h.lock();
    defer h.unlock();
    for (h.replies.items, 0..) |reply, i| {
        if (reply.id != id) continue;
        _ = h.replies.orderedRemove(i);
        return .{
            .echo = reply.echo,
            .offset = reply.end,
            .output = try arena.dupe(u8, h.textBetween(reply.start, reply.end)),
            .status = try h.copyStatus(arena),
        };
    }
    return null;
}

/// The offset just past the latest game text.
pub fn textOffset(h: *Hub) u64 {
    h.lock();
    defer h.unlock();
    return h.textEnd();
}

/// The game text printed since an offset.
pub const Text = struct {
    /// The offset just past it.
    offset: u64,
    /// The game is waiting for input.
    waiting: bool,
    text: []const u8,
    status: [2][]const u8,
    /// The status line's rows, left and right (see `copyLines`).
    lines: []const [2][]const u8,
};

/// The game text printed since offset `since`, copied into `arena`.
pub fn textSince(h: *Hub, arena: Allocator, since: u64) Allocator.Error!Text {
    h.lock();
    defer h.unlock();
    return .{
        .offset = h.textEnd(),
        .waiting = h.idle,
        .text = try arena.dupe(u8, h.textBetween(since, h.textEnd())),
        .status = try h.copyStatus(arena),
        .lines = try h.copyLines(arena),
    };
}

fn textBetween(h: *const Hub, start: u64, end: u64) []const u8 {
    const from = @max(start, h.text_base) - h.text_base;
    const to = @max(end, h.text_base) - h.text_base;
    if (from >= to or to > h.text.items.len) return "";
    return h.text.items[@intCast(from)..@intCast(to)];
}

/// A row split at its longest run of spaces (two or more) into left and
/// right, copied into `arena`.
fn splitRow(arena: Allocator, text: []const u8) Allocator.Error![2][]const u8 {
    const row = std.mem.trim(u8, text, " ");
    var best: usize = 0;
    var best_len: usize = 1;
    var at: usize = 0;
    while (at < row.len) {
        if (row[at] != ' ') {
            at += 1;
            continue;
        }
        const start = at;
        while (at < row.len and row[at] == ' ') at += 1;
        if (at - start > best_len) {
            best = start;
            best_len = at - start;
        }
    }
    if (best == 0) return .{ try arena.dupe(u8, row), "" };
    return .{ try arena.dupe(u8, row[0..best]), try arena.dupe(u8, row[best + best_len ..]) };
}

/// The status line's rows, left and right: the story's own (one), or for a
/// story without one the rows of its upper window, if it has no more than a
/// few.
pub fn copyLines(h: *const Hub, arena: Allocator) Allocator.Error![]const [2][]const u8 {
    if (h.has_status) {
        const one = try arena.alloc([2][]const u8, 1);
        one[0] = .{ try arena.dupe(u8, h.status[0].items), try arena.dupe(u8, h.status[1].items) };
        return one;
    }
    if (h.upper_depth == 0 or h.upper_depth > upper_rows) return &.{};
    var rows = try arena.alloc([2][]const u8, h.upper_depth);
    for (rows[0..], 0..) |*row, i| row.* = try splitRow(arena, h.upper[i][0..h.upper_lens[i]]);
    return rows;
}

/// The first row, for the page's header and command replies.
fn copyStatus(h: *const Hub, arena: Allocator) Allocator.Error![2][]const u8 {
    const lines = try h.copyLines(arena);
    return if (lines.len > 0) lines[0] else .{ "", "" };
}

test "clearing the text keeps offsets" {
    var h: Hub = .init(std.testing.allocator, std.testing.io);
    defer h.deinit();
    h.capture("old game\n");
    const before = h.textOffset();
    h.clearText();
    try std.testing.expectEqual(before, h.textOffset());
    h.capture("new game\n");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try h.textSince(arena.allocator(), 0);
    try std.testing.expectEqualStrings("new game\n", t.text);
}

test "story and seed" {
    var h: Hub = .init(std.testing.allocator, std.testing.io);
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try h.storyInfo(arena.allocator())) == null);
    var bytes: [0x40]u8 = undefined;
    @memset(&bytes, 0);
    bytes[0] = 3;
    bytes[3] = 119;
    @memcpy(bytes[0x12..0x18], "880429");
    try h.setStory("zork1.z3", &bytes);
    h.setSeed(69, false);
    const s = (try h.storyInfo(arena.allocator())).?;
    try std.testing.expectEqualStrings("zork1.z3", s.file);
    try std.testing.expectEqual(3, s.zversion);
    try std.testing.expectEqual(119, s.release);
    try std.testing.expectEqualStrings("880429", &s.serial);
    try std.testing.expectEqual(69, s.seed);
    try std.testing.expect(!s.seed_random);
}

test "web command and reply" {
    var h: Hub = .init(std.testing.allocator, std.testing.io);
    defer h.deinit();
    var buf: [64]u8 = undefined;

    try std.testing.expectEqual(InputSource.Line.none, h.takeLine(&buf));
    const id = try h.submit(.{ .name = "Claude", .ai = true }, "open mailbox");
    try std.testing.expect(h.pending());

    try std.testing.expectEqualStrings("open mailbox", h.takeLine(&buf).web);
    h.capture("Opening the small mailbox reveals a leaflet.\n\n>");
    h.setStatus("West of House", "Score: 0   Moves: 1");

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, try h.takeAnswer(arena.allocator(), id));
    h.waiting();
    const answer = (try h.takeAnswer(arena.allocator(), id)).?;
    try std.testing.expectEqual(0, answer.echo);
    try std.testing.expectEqual(60, answer.offset);
    try std.testing.expectEqualStrings("Opening the small mailbox reveals a leaflet.\n\n>", answer.output);
    try std.testing.expectEqualStrings("Score: 0   Moves: 1", answer.status[1]);
    try std.testing.expectEqual(null, try h.takeAnswer(arena.allocator(), id));

    const text = try h.textSince(arena.allocator(), 0);
    try std.testing.expect(text.waiting);
    try std.testing.expectEqual(60, text.offset);
    try std.testing.expect(std.mem.startsWith(u8, text.text, "open mailbox\nOpening"));
}

test "keyboard lines come first, and hooks hear them" {
    var h: Hub = .init(std.testing.allocator, std.testing.io);
    defer h.deinit();
    var buf: [64]u8 = undefined;
    const Heard = struct {
        lines: [4][16]u8 = undefined,
        ai: [4]bool = undefined,
        count: usize = 0,

        fn taken(context: *anyopaque, sender: ?Sender, line: []const u8) void {
            const heard: *@This() = @ptrCast(@alignCast(context));
            @memcpy(heard.lines[heard.count][0..line.len], line);
            heard.ai[heard.count] = if (sender) |s| s.ai else false;
            heard.count += 1;
        }
    };
    var heard: Heard = .{};
    h.hooks = .{ .context = &heard, .taken = Heard.taken };

    _ = try h.submit(.{ .name = "Claude", .ai = true }, "north");
    try h.keyboard.appendSlice(h.gpa, "look\r\n/lead\n/mode turns\nin");
    try std.testing.expectEqualStrings("look", h.takeLine(&buf).keyboard);
    try std.testing.expectEqualStrings("lead", h.takeLine(&buf).console);
    try std.testing.expectEqualStrings("mode turns", h.takeLine(&buf).console);
    try std.testing.expectEqualStrings("north", h.takeLine(&buf).web);
    try std.testing.expectEqual(InputSource.Line.none, h.takeLine(&buf));
    h.keyboard_closed = true;
    try std.testing.expectEqualStrings("in", h.takeLine(&buf).keyboard);
    try std.testing.expectEqual(InputSource.Line.closed, h.takeLine(&buf));

    // The console command never reaches the hooks.
    try std.testing.expectEqual(3, heard.count);
    try std.testing.expectEqualStrings("look", heard.lines[0][0..4]);
    try std.testing.expectEqualStrings("north", heard.lines[1][0..5]);
    try std.testing.expect(heard.ai[1] and !heard.ai[2]);
}

test "a story without a status line shows its upper window's rows" {
    var h: Hub = .init(std.testing.allocator, std.testing.io);
    defer h.deinit();
    for (0.., " Kitchen      Score: 3 ") |col, c| h.putUpper(1, col, c);
    for (0.., "Mode:  Mail          Time:  7:08pm") |col, c| h.putUpper(2, col, c);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const lines = try h.copyLines(arena.allocator());
    try std.testing.expectEqual(2, lines.len);
    try std.testing.expectEqualStrings("Kitchen", lines[0][0]);
    try std.testing.expectEqualStrings("Score: 3", lines[0][1]);
    try std.testing.expectEqualStrings("Mode:  Mail", lines[1][0]);
    try std.testing.expectEqualStrings("Time:  7:08pm", lines[1][1]);
    const first = try h.copyStatus(arena.allocator());
    try std.testing.expectEqualStrings("Kitchen", first[0]);
    // A window deeper than a status line is not one.
    h.putUpper(upper_rows + 1, 0, 'x');
    try std.testing.expectEqual(0, (try h.copyLines(arena.allocator())).len);
    h.clearUpper();
    try std.testing.expectEqual(0, (try h.copyLines(arena.allocator())).len);
}
