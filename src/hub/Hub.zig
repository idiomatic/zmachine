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
    for (&h.status) |*s| s.deinit(h.gpa);
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
};

fn consoleCommand(line: []const u8) ?ConsoleCommand {
    const text = std.mem.trim(u8, line, " \t");
    if (text.len < 2 or text[0] != '/') return null;
    return std.meta.stringToEnum(ConsoleCommand, text[1..]);
}

/// Takes the next complete line from the keyboard or the web, copied into
/// `buf`, and adds it to the game text.
pub fn takeLine(h: *Hub, buf: []u8) InputSource.Line {
    h.lock();
    defer h.unlock();
    if (h.takeKeyboardLine(buf)) |line| {
        if (consoleCommand(line)) |command| return .{ .console = @tagName(command) };
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

    pub fn print(v: *Seen, cp: u21) Display.Error!void {
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
        return v.screen.eraseWindow(which);
    }
    pub fn eraseLine(v: *Seen) Display.Error!void {
        return v.screen.eraseLine();
    }
    pub fn setCursor(v: *Seen, row: u16, col: u16) Display.Error!void {
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

pub fn setStatus(h: *Hub, left: []const u8, right: []const u8) void {
    h.lock();
    defer h.unlock();
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

/// Writes the reply to command `id` as JSON, if the game has finished
/// answering it.
pub fn writeReply(h: *Hub, w: *Io.Writer, id: u64) !bool {
    h.lock();
    defer h.unlock();
    for (h.replies.items, 0..) |reply, i| {
        if (reply.id != id) continue;
        _ = h.replies.orderedRemove(i);
        try w.print("{{\"id\":{d},\"echo\":{d},\"offset\":{d},\"output\":", .{ id, reply.echo, reply.end });
        try writeString(w, h.textBetween(reply.start, reply.end));
        try w.writeAll(",");
        try h.writeStatus(w);
        try w.writeAll("}");
        return true;
    }
    return false;
}

/// The offset just past the latest game text.
pub fn textOffset(h: *Hub) u64 {
    h.lock();
    defer h.unlock();
    return h.textEnd();
}

/// Writes the game text printed since offset `since` as JSON, with the
/// players' `mode`.
pub fn writeText(h: *Hub, w: *Io.Writer, since: u64, mode: []const u8) !void {
    h.lock();
    defer h.unlock();
    try w.print("{{\"offset\":{d},\"waiting\":{},\"mode\":\"{s}\",\"text\":", .{ h.textEnd(), h.idle, mode });
    try writeString(w, h.textBetween(since, h.textEnd()));
    try w.writeAll(",");
    try h.writeStatus(w);
    try w.writeAll("}");
}

fn textBetween(h: *const Hub, start: u64, end: u64) []const u8 {
    const from = @max(start, h.text_base) - h.text_base;
    const to = @max(end, h.text_base) - h.text_base;
    if (from >= to or to > h.text.items.len) return "";
    return h.text.items[@intCast(from)..@intCast(to)];
}

fn writeStatus(h: *const Hub, w: *Io.Writer) !void {
    try w.writeAll("\"status\":[");
    try writeString(w, h.status[0].items);
    try w.writeAll(",");
    try writeString(w, h.status[1].items);
    try w.writeAll("]");
}

fn writeString(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
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

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try h.writeReply(&out.writer, id));
    h.waiting();
    try std.testing.expect(try h.writeReply(&out.writer, id));
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"echo\":0,\"offset\":60,\"output\":\"Opening the small mailbox reveals a leaflet.\\n\\n>\"," ++
            "\"status\":[\"West of House\",\"Score: 0   Moves: 1\"]}",
        out.written(),
    );

    out.clearRetainingCapacity();
    try h.writeText(&out.writer, 0, "turns");
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "{\"offset\":60,\"waiting\":true,\"mode\":\"turns\",\"text\":\"open mailbox\\nOpening"));
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
    try h.keyboard.appendSlice(h.gpa, "look\r\n/lead\nin");
    try std.testing.expectEqualStrings("look", h.takeLine(&buf).keyboard);
    try std.testing.expectEqualStrings("lead", h.takeLine(&buf).console);
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
