//! Shared state for playing together through the web server: commands sent
//! with `POST /command`, the game text a player sees, a discussion of what
//! to do next, the players and who leads them, sessions for players on
//! other machines, and an audit log of web requests that shows who sent
//! commands and who looked at the object inspector.
//!
//! Keyboard input is read on a thread of its own, so the interpreter can
//! wait for the keyboard and the web at the same time.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Password = @import("Password.zig");

const Remote = @This();

gpa: Allocator,
io: Io,
/// Guards everything below, which the interpreter, keyboard and server
/// threads share.
mutex: Io.Mutex = .init,

keyboard: std.ArrayList(u8) = .empty,
keyboard_closed: bool = false,

queue: std.ArrayList(Command) = .empty,
next_id: u64 = 1,
/// The remote command the game is answering, and where its reply starts.
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

events: std.ArrayList(Event) = .empty,
next_seq: u64 = 1,

mode: Mode = .debate,
/// The discussion: thoughts, messages, commands and changes.
posts: std.ArrayList(Post) = .empty,
next_post: u64 = 1,

/// The people on the play page and the AI partners, in the order they joined.
members: std.ArrayList(Member) = .empty,
next_order: u64 = 1,
/// Who leads: a remote person or AI partner by name, or null for the local
/// side (the console and local play-page clients, all coleaders).
leader: ?[]u8 = null,
/// AI partners kicked out, refused from then on.
banned: std.ArrayList([]u8) = .empty,
/// Whether every AI partner may read the inspector (`--grant-inspector`),
/// and the AI partners a person on this machine let read it.
inspector_for_all: bool = false,
inspector_grants: std.ArrayList([]u8) = .empty,

/// With `--listen`, the password remote players give, their sessions, and
/// sessions ended by a kick, so their pages can say so.
password: ?Password = null,
sessions: std.ArrayList(Session) = .empty,
kicked: std.ArrayList(Kicked) = .empty,
/// Wrong passwords by address, and the latest attempts overall.
failures: std.ArrayList(Failure) = .empty,
attempts: [max_attempts_per_second]i64 = @splat(0),
next_attempt: usize = 0,

const max_text = 256 * 1024;
const max_events = 1000;
const max_replies = 64;
const max_posts = 500;
const max_kicked = 64;
pub const max_command = 200;
pub const max_post = 4000;
pub const max_suggestions = 8;
/// A person who hasn't been heard from in a minute has left; the play
/// page asks for something at least every 20 seconds. AI partners may
/// think for longer.
const person_timeout_ms = 60_000;
const partner_timeout_ms = 10 * 60_000;
/// Password guesses: at most this many a second from everyone, and a
/// delay that doubles with each wrong guess from one address.
const max_attempts_per_second = 10;
const max_delay_ms = 60_000;

/// How the players share the game.
pub const Mode = enum {
    /// Only the leader sends commands; the others argue and suggest them.
    /// The default.
    debate,
    /// Anyone may send commands; they take turns.
    turns,
};

/// Who sent something.
pub const Player = struct {
    /// The person's or AI partner's name, or null for the console or a
    /// local client that gives none.
    name: ?[]const u8 = null,
    ai: bool = false,
    /// On this machine. The console and local play-page clients are local;
    /// AI partners never count as local.
    local: bool = true,

    pub const console: Player = .{};
};

/// Whether `name` can name a player: 1 to 32 printable characters, and not
/// "you" or "console", which stand for the console.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |c| if (c < 0x20 or c == 0x7f) return false;
    return !std.ascii.eqlIgnoreCase(name, "you") and !std.ascii.eqlIgnoreCase(name, "console");
}

pub const PostKind = enum {
    /// A partner's thinking, with any suggested commands.
    thought,
    /// A message to the other players.
    message,
    /// A command sent to the game.
    command,
    /// The mode changed; the text names the new one.
    mode,
    /// The leadership moved; the text names the new leader, or "console"
    /// for the local side.
    leader,
    /// The author joined.
    joined,
    /// The author left; the text is empty.
    left,
    /// The author kicked the player the text names.
    kicked,
    /// The author changed the password.
    password,
    /// The author let the AI partner the text names read the inspector.
    granted,
    /// The author stopped the AI partner the text names reading it.
    revoked,
};

pub const Post = struct {
    seq: u64,
    time: i64,
    /// The person's or AI partner's name, or null for the console.
    author: ?[]u8,
    ai: bool,
    kind: PostKind,
    text: []u8,
    suggestions: [][]u8,
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

const Member = struct {
    name: []u8,
    ai: bool,
    local: bool,
    /// Join order, for choosing a new leader.
    order: u64,
    /// When the member was last heard from, in milliseconds.
    seen: i64,
};

/// A session cookie's value.
pub const Token = [16]u8;

/// An address, for limiting password guesses.
pub const AddressKey = [16]u8;

const Session = struct {
    token: Token,
    /// The name chosen with `POST /join`.
    name: ?[]u8 = null,
};

const Kicked = struct {
    token: Token,
    /// Why the session ended, such as "Ana removed you from the game".
    why: []u8,
};

const Failure = struct {
    key: AddressKey,
    count: u32,
    /// No more guesses from this address until then, in milliseconds.
    until: i64,
};

pub const Kind = enum {
    /// A command sent with `POST /command`.
    command,
    /// A line typed at the keyboard.
    keyboard,
    /// The object inspector page was opened.
    inspector,
    /// An inspector snapshot (object tree, attributes, globals) was read.
    snapshot,
    /// A request was refused.
    refused,
    /// A player joined or left.
    join,
    /// A remote player gave the password, rightly or wrongly.
    login,
    /// The leadership moved.
    leader,
    /// A player was kicked.
    kick,
    /// The password was changed, read or shown.
    password,
    /// An AI partner was let read the inspector, or stopped.
    access,
};

pub const Event = struct {
    seq: u64,
    time: i64,
    kind: Kind,
    suspicious: bool,
    client: []u8,
    detail: []u8,
};

pub fn init(gpa: Allocator, io: Io) Remote {
    return .{ .gpa = gpa, .io = io };
}

pub fn deinit(r: *Remote) void {
    r.keyboard.deinit(r.gpa);
    for (r.queue.items) |c| freeCommand(r.gpa, c);
    r.queue.deinit(r.gpa);
    r.replies.deinit(r.gpa);
    r.text.deinit(r.gpa);
    for (&r.status) |*s| s.deinit(r.gpa);
    for (r.events.items) |e| freeEvent(r.gpa, e);
    r.events.deinit(r.gpa);
    for (r.posts.items) |p| freePost(r.gpa, p);
    r.posts.deinit(r.gpa);
    for (r.members.items) |m| r.gpa.free(m.name);
    r.members.deinit(r.gpa);
    if (r.leader) |name| r.gpa.free(name);
    for (r.banned.items) |name| r.gpa.free(name);
    r.banned.deinit(r.gpa);
    for (r.inspector_grants.items) |name| r.gpa.free(name);
    r.inspector_grants.deinit(r.gpa);
    for (r.sessions.items) |s| if (s.name) |name| r.gpa.free(name);
    r.sessions.deinit(r.gpa);
    for (r.kicked.items) |k| r.gpa.free(k.why);
    r.kicked.deinit(r.gpa);
    r.failures.deinit(r.gpa);
}

fn freeCommand(gpa: Allocator, c: Command) void {
    if (c.player) |name| gpa.free(name);
    gpa.free(c.text);
}

fn freePost(gpa: Allocator, p: Post) void {
    if (p.author) |name| gpa.free(name);
    for (p.suggestions) |text| gpa.free(text);
    gpa.free(p.suggestions);
    gpa.free(p.text);
}

fn freeEvent(gpa: Allocator, e: Event) void {
    gpa.free(e.client);
    gpa.free(e.detail);
}

fn now(r: *const Remote) i64 {
    return Io.Timestamp.now(r.io, .real).toMilliseconds();
}

/// Starts reading the keyboard (standard input) on its own thread.
pub fn startKeyboard(r: *Remote) !void {
    const thread = try std.Thread.spawn(.{}, readKeyboard, .{r});
    thread.detach();
}

fn readKeyboard(r: *Remote) void {
    var buf: [512]u8 = undefined;
    while (true) {
        const n = Io.File.stdin().readStreaming(r.io, &.{&buf}) catch break;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.keyboard.appendSlice(r.gpa, buf[0..n]) catch break;
    }
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.keyboard_closed = true;
}

// Interpreter side

pub const Line = union(enum) {
    /// Nothing yet; wait and try again.
    none,
    /// The keyboard is closed and nothing is left.
    closed,
    keyboard: []u8,
    remote: []u8,
    /// A console command such as `/lead`, typed at the keyboard; the game
    /// never sees it.
    console: ConsoleCommand,
};

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
pub fn takeLine(r: *Remote, buf: []u8) Line {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (r.takeKeyboardLine(buf)) |line| {
        if (consoleCommand(line)) |command| return .{ .console = command };
        r.logLocked(.keyboard, "keyboard", line, false);
        r.postLocked(.console, .command, line, &.{}) catch {};
        r.appendText(line);
        r.appendText("\n");
        return .{ .keyboard = line };
    }
    if (r.takeRemote(buf)) |command| {
        r.postLocked(.{ .name = command.player, .ai = command.ai, .local = false }, .command, command.line, &.{}) catch {};
        if (command.player) |name| r.gpa.free(name);
        r.appendText(command.line);
        r.appendText("\n");
        r.answer_start = r.textEnd();
        return .{ .remote = command.line };
    }
    return if (r.keyboard_closed) .closed else .none;
}

pub const Key = union(enum) {
    none,
    closed,
    key: u8,
    /// A line whose characters are handed out one key at a time.
    line: []u8,
};

/// Takes the next key from the keyboard, or a line of keys from the web.
/// With `by_line`, keyboard input is piped and arrives as lines too. With
/// `remote` false, only the keyboard is read.
pub fn takeKey(r: *Remote, buf: []u8, by_line: bool, remote: bool) Key {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (by_line) {
        if (r.takeKeyboardLine(buf)) |line| return .{ .line = line };
    } else if (r.keyboard.items.len > 0) {
        return .{ .key = r.keyboard.orderedRemove(0) };
    }
    if (remote) {
        if (r.takeRemote(buf)) |command| {
            if (command.player) |name| r.gpa.free(name);
            return .{ .line = command.line };
        }
    }
    return if (r.keyboard_closed) .closed else .none;
}

/// Whether keys have arrived from the keyboard that nothing has taken yet.
pub fn keyboardPending(r: *Remote) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.keyboard.items.len > 0;
}

/// Takes a byte that has already arrived from the keyboard, for the rest
/// of an escape sequence.
pub fn takeKeyboardByte(r: *Remote) ?u8 {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (r.keyboard.items.len == 0) return null;
    return r.keyboard.orderedRemove(0);
}

fn takeKeyboardLine(r: *Remote, buf: []u8) ?[]u8 {
    const items = r.keyboard.items;
    const end = if (std.mem.indexOfScalar(u8, items, '\n')) |nl|
        nl
    else if (r.keyboard_closed and items.len > 0)
        items.len
    else
        return null;
    const line = std.mem.trimEnd(u8, items[0..end], "\r");
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    r.keyboard.replaceRangeAssumeCapacity(0, @min(end + 1, items.len), &.{});
    r.idle = false;
    return buf[0..n];
}

fn takeRemote(r: *Remote, buf: []u8) ?struct { line: []u8, player: ?[]u8, ai: bool } {
    if (r.queue.items.len == 0) return null;
    const command = r.queue.orderedRemove(0);
    defer r.gpa.free(command.text);
    const n = @min(command.text.len, buf.len);
    @memcpy(buf[0..n], command.text[0..n]);
    r.answering = command.id;
    r.answer_echo = r.textEnd();
    r.answer_start = r.textEnd();
    r.idle = false;
    return .{ .line = buf[0..n], .player = command.player, .ai = command.ai };
}

/// Called each time the game starts waiting for new input: the reply to
/// the remote command it was answering is complete.
pub fn waiting(r: *Remote) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.idle = true;
    const id = r.answering orelse return;
    r.answering = null;
    if (r.replies.items.len >= max_replies) _ = r.replies.orderedRemove(0);
    r.replies.append(r.gpa, .{
        .id = id,
        .echo = r.answer_echo,
        .start = r.answer_start,
        .end = r.textEnd(),
    }) catch {};
}

/// Whether a remote command is waiting to be read.
pub fn pending(r: *Remote) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.queue.items.len > 0;
}

/// Adds text the game printed in the lower window.
pub fn capture(r: *Remote, bytes: []const u8) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.appendText(bytes);
}

pub fn setStatus(r: *Remote, left: []const u8, right: []const u8) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    for (&r.status, [_][]const u8{ left, right }) |*s, text| {
        s.clearRetainingCapacity();
        s.appendSlice(r.gpa, text) catch {};
    }
}

fn textEnd(r: *const Remote) u64 {
    return r.text_base + r.text.items.len;
}

fn appendText(r: *Remote, bytes: []const u8) void {
    r.text.appendSlice(r.gpa, bytes) catch return;
    if (r.text.items.len <= max_text) return;
    // Drop the older half, cutting at the start of a character.
    var cut = r.text.items.len / 2;
    while (cut < r.text.items.len and r.text.items[cut] & 0xc0 == 0x80) cut += 1;
    r.text.replaceRangeAssumeCapacity(0, cut, &.{});
    r.text_base += cut;
}

// Server side

pub const SubmitError = error{ InvalidCommand, NotYourTurn, OutOfMemory };

fn validCommand(text: []const u8) bool {
    if (text.len > max_command) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Queues a command from the web and returns its id. In debate mode only
/// the leader may send commands.
pub fn submit(r: *Remote, client: []const u8, player: Player, text: []const u8) SubmitError!u64 {
    if (!validCommand(text)) return error.InvalidCommand;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (r.mode == .debate and !r.leadsLocked(player)) return error.NotYourTurn;
    const copy = try r.gpa.dupe(u8, text);
    errdefer r.gpa.free(copy);
    const name = if (player.name) |n| try r.gpa.dupe(u8, n) else null;
    errdefer if (name) |n| r.gpa.free(n);
    const id = r.next_id;
    try r.queue.append(r.gpa, .{ .id = id, .player = name, .ai = player.ai, .text = copy });
    r.next_id += 1;
    r.logLocked(.command, client, text, false);
    return id;
}

/// Writes the reply to command `id` as JSON, if the game has finished
/// answering it.
pub fn writeReply(r: *Remote, w: *Io.Writer, id: u64) !bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    for (r.replies.items, 0..) |reply, i| {
        if (reply.id != id) continue;
        _ = r.replies.orderedRemove(i);
        try w.print("{{\"id\":{d},\"echo\":{d},\"offset\":{d},\"output\":", .{ id, reply.echo, reply.end });
        try writeString(w, r.textBetween(reply.start, reply.end));
        try w.writeAll(",");
        try r.writeStatus(w);
        try w.writeAll("}");
        return true;
    }
    return false;
}

/// The offset just past the latest game text.
pub fn textOffset(r: *Remote) u64 {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.textEnd();
}

/// Writes the game text printed since offset `since` as JSON.
pub fn writeText(r: *Remote, w: *Io.Writer, since: u64) !void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    try w.print("{{\"offset\":{d},\"waiting\":{},\"mode\":\"{s}\",\"text\":", .{
        r.textEnd(), r.idle, @tagName(r.mode),
    });
    try writeString(w, r.textBetween(since, r.textEnd()));
    try w.writeAll(",");
    try r.writeStatus(w);
    try w.writeAll("}");
}

fn textBetween(r: *const Remote, start: u64, end: u64) []const u8 {
    const from = @max(start, r.text_base) - r.text_base;
    const to = @max(end, r.text_base) - r.text_base;
    if (from >= to or to > r.text.items.len) return "";
    return r.text.items[@intCast(from)..@intCast(to)];
}

fn writeStatus(r: *const Remote, w: *Io.Writer) !void {
    try w.writeAll("\"status\":[");
    try writeString(w, r.status[0].items);
    try w.writeAll(",");
    try writeString(w, r.status[1].items);
    try w.writeAll("]");
}

/// Records an event in the audit log.
pub fn log(r: *Remote, kind: Kind, client: []const u8, detail: []const u8, suspicious: bool) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.logLocked(kind, client, detail, suspicious);
}

fn logLocked(r: *Remote, kind: Kind, client: []const u8, detail: []const u8, suspicious: bool) void {
    const client_copy = r.gpa.dupe(u8, client) catch return;
    const detail_copy = r.gpa.dupe(u8, detail) catch {
        r.gpa.free(client_copy);
        return;
    };
    if (r.events.items.len >= max_events) freeEvent(r.gpa, r.events.orderedRemove(0));
    r.events.append(r.gpa, .{
        .seq = r.next_seq,
        .time = r.now(),
        .kind = kind,
        .suspicious = suspicious,
        .client = client_copy,
        .detail = detail_copy,
    }) catch {
        freeEvent(r.gpa, .{ .seq = 0, .time = 0, .kind = kind, .suspicious = false, .client = client_copy, .detail = detail_copy });
        return;
    };
    r.next_seq += 1;
}

/// Logs an event about `p`, naming them.
fn logPlayerLocked(r: *Remote, kind: Kind, p: Player, comptime fmt: []const u8, args: anytype, suspicious: bool) void {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    r.logLocked(kind, displayName(p), detail, suspicious);
}

fn displayName(p: Player) []const u8 {
    return p.name orelse "console";
}

/// The sequence number of the latest event, or 0.
pub fn lastEvent(r: *Remote) u64 {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.next_seq - 1;
}

/// Writes the events after `since` as JSON.
pub fn writeEvents(r: *Remote, w: *Io.Writer, since: u64) !void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    try w.print("{{\"last\":{d},\"events\":[", .{r.next_seq - 1});
    var first = true;
    for (r.events.items) |e| {
        if (e.seq <= since) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"seq\":{d},\"time\":{d},\"kind\":\"{s}\",\"suspicious\":{},\"client\":", .{
            e.seq, e.time, @tagName(e.kind), e.suspicious,
        });
        try writeString(w, e.client);
        try w.writeAll(",\"detail\":");
        try writeString(w, e.detail);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

// Discussion

pub const PostError = error{ InvalidPost, OutOfMemory };

/// Adds a thought or message to the discussion.
pub fn post(r: *Remote, author: Player, kind: PostKind, text: []const u8, suggestions: []const []const u8) PostError!void {
    if (kind != .thought and kind != .message) return error.InvalidPost;
    if (text.len > max_post or !std.unicode.utf8ValidateSlice(text)) return error.InvalidPost;
    if (suggestions.len > max_suggestions) return error.InvalidPost;
    for (suggestions) |s| if (s.len == 0 or !validCommand(s)) return error.InvalidPost;
    if (text.len == 0 and suggestions.len == 0) return error.InvalidPost;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    try r.postLocked(author, kind, text, suggestions);
}

fn postLocked(r: *Remote, author: Player, kind: PostKind, text: []const u8, suggestions: []const []const u8) !void {
    const copies = try r.gpa.alloc([]u8, suggestions.len);
    var copied: usize = 0;
    errdefer {
        for (copies[0..copied]) |c| r.gpa.free(c);
        r.gpa.free(copies);
    }
    for (suggestions, copies) |s, *c| {
        c.* = try r.gpa.dupe(u8, s);
        copied += 1;
    }
    const text_copy = try r.gpa.dupe(u8, text);
    errdefer r.gpa.free(text_copy);
    const author_copy = if (author.name) |n| try r.gpa.dupe(u8, n) else null;
    errdefer if (author_copy) |n| r.gpa.free(n);
    if (r.posts.items.len >= max_posts) freePost(r.gpa, r.posts.orderedRemove(0));
    try r.posts.append(r.gpa, .{
        .seq = r.next_post,
        .time = r.now(),
        .author = author_copy,
        .ai = author.ai,
        .kind = kind,
        .text = text_copy,
        .suggestions = copies,
    });
    r.next_post += 1;
}

pub const LeaderError = error{ NotLeader, UnknownPlayer, CannotKick, OutOfMemory };

/// Sets the mode; only the leader may.
pub fn setMode(r: *Remote, from: Player, mode: Mode) LeaderError!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (!r.leadsLocked(from)) return error.NotLeader;
    if (r.mode == mode) return;
    r.mode = mode;
    r.postLocked(from, .mode, @tagName(mode), &.{}) catch {};
}

/// The sequence number of the latest post, or 0.
pub fn lastPost(r: *Remote) u64 {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.next_post - 1;
}

/// Writes the mode, the leader, the players and the posts after `since`
/// as JSON.
pub fn writePosts(r: *Remote, w: *Io.Writer, since: u64) !void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    try w.print("{{\"last\":{d},\"mode\":\"{s}\",\"inspector_for_all\":{},\"leader\":", .{
        r.next_post - 1, @tagName(r.mode), r.inspector_for_all,
    });
    try writeString(w, r.leader orelse "console");
    try w.writeAll(",\"players\":[");
    for (r.members.items, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeString(w, m.name);
        const leader = r.leadsLocked(.{ .name = m.name, .ai = m.ai, .local = m.local });
        const inspects = m.ai and r.mayInspectLocked(m.name);
        try w.print(",\"ai\":{},\"local\":{},\"leader\":{},\"inspector\":{}}}", .{ m.ai, m.local, leader, inspects });
    }
    try w.writeAll("],\"posts\":[");
    var first = true;
    for (r.posts.items) |p| {
        if (p.seq <= since) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("{{\"seq\":{d},\"time\":{d},\"ai\":{},\"author\":", .{ p.seq, p.time, p.ai });
        try writeString(w, p.author orelse "console");
        try w.print(",\"kind\":\"{s}\",\"text\":", .{@tagName(p.kind)});
        try writeString(w, p.text);
        try w.writeAll(",\"suggestions\":[");
        for (p.suggestions, 0..) |s, i| {
            if (i > 0) try w.writeAll(",");
            try writeString(w, s);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

fn writeString(w: *Io.Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

// Players and leadership

pub const TouchError = error{ NameTaken, Kicked, OutOfMemory };

/// Notes that a named player is here, adding them the first time. A name
/// belongs to one player at a time; AI partners who were kicked stay out.
pub fn touch(r: *Remote, p: Player) TouchError!void {
    const name = p.name orelse return;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    try r.touchLocked(name, p.ai, p.local);
}

fn touchLocked(r: *Remote, name: []const u8, ai: bool, local: bool) TouchError!void {
    if (r.findMember(name)) |i| {
        const m = &r.members.items[i];
        if (m.ai != ai or m.local != local) return error.NameTaken;
        m.seen = r.now();
        return;
    }
    if (ai) for (r.banned.items) |b| if (std.ascii.eqlIgnoreCase(b, name)) return error.Kicked;
    const copy = try r.gpa.dupe(u8, name);
    errdefer r.gpa.free(copy);
    try r.members.append(r.gpa, .{ .name = copy, .ai = ai, .local = local, .order = r.next_order, .seen = r.now() });
    r.next_order += 1;
    const p: Player = .{ .name = copy, .ai = ai, .local = local };
    r.postLocked(p, .joined, "", &.{}) catch {};
    // AI partners connect from this machine but never count as local, so
    // only people are said to be local or remote.
    r.logPlayerLocked(.join, p, "joined ({s})", .{
        if (ai) "AI partner" else if (local) "person, local" else "person, remote",
    }, false);
    // With nobody local on the play page, the first remote person leads.
    if (!ai and !local and r.leader == null and !r.anyLocalPersonLocked()) r.setLeaderLocked(p, p) catch {};
}

fn findMember(r: *const Remote, name: []const u8) ?usize {
    for (r.members.items, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.name, name)) return i;
    return null;
}

fn anyLocalPersonLocked(r: *const Remote) bool {
    for (r.members.items) |m| if (m.local and !m.ai) return true;
    return false;
}

/// Drops players who have gone quiet, choosing a new leader if the
/// leader was one of them.
fn pruneLocked(r: *Remote) void {
    const t = r.now();
    var i: usize = 0;
    while (i < r.members.items.len) {
        const m = r.members.items[i];
        const timeout: i64 = if (m.ai) partner_timeout_ms else person_timeout_ms;
        if (t - m.seen < timeout) {
            i += 1;
            continue;
        }
        r.removeMemberLocked(i, true);
    }
}

/// Removes member `i`; if they led, the earliest remaining player leads.
fn removeMemberLocked(r: *Remote, i: usize, left: bool) void {
    const m = r.members.orderedRemove(i);
    defer r.gpa.free(m.name);
    const p: Player = .{ .name = m.name, .ai = m.ai, .local = m.local };
    if (left) {
        r.postLocked(p, .left, "", &.{}) catch {};
        r.logPlayerLocked(.join, p, "left", .{}, false);
    }
    const led = if (r.leader) |name| std.ascii.eqlIgnoreCase(name, m.name) else false;
    if (!led) return;
    if (r.members.items.len == 0) {
        r.setLeaderLocked(.console, .console) catch {};
        return;
    }
    // Members stay in join order.
    const next = r.members.items[0];
    const heir: Player = .{ .name = next.name, .ai = next.ai, .local = next.local };
    r.setLeaderLocked(heir, if (next.local) .console else heir) catch {};
}

/// Makes `to` the leader (the console stands for the local side), posting
/// and logging the change on behalf of `by`.
fn setLeaderLocked(r: *Remote, by: Player, to: Player) !void {
    const new: ?[]u8 = if (to.local and !to.ai) null else try r.gpa.dupe(u8, to.name.?);
    if (r.leader) |old| r.gpa.free(old);
    r.leader = new;
    const name = new orelse "console";
    r.postLocked(by, .leader, name, &.{}) catch {};
    r.logPlayerLocked(.leader, by, "leadership to {s}", .{name}, false);
}

/// Whether `p` leads: the named remote person or AI partner, or anyone on
/// the local side when it leads.
fn leadsLocked(r: *const Remote, p: Player) bool {
    if (r.leader) |name| {
        const n = p.name orelse return false;
        return !p.local and std.ascii.eqlIgnoreCase(name, n);
    }
    return p.local and !p.ai;
}

pub fn leads(r: *Remote, p: Player) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    return r.leadsLocked(p);
}

/// Passes the leadership to the player named `to`, or to the local side
/// for "console". The local side can always take it back.
pub fn passLeadership(r: *Remote, from: Player, to: []const u8) LeaderError!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    if (std.ascii.eqlIgnoreCase(to, "console")) {
        if (!r.leadsLocked(from) and !(from.local and !from.ai)) return error.NotLeader;
        if (r.leader == null) return;
        return r.setLeaderLocked(from, .console);
    }
    if (!r.leadsLocked(from)) return error.NotLeader;
    const i = r.findMember(to) orelse return error.UnknownPlayer;
    const m = r.members.items[i];
    const target: Player = .{ .name = m.name, .ai = m.ai, .local = m.local };
    if (r.leadsLocked(target)) return;
    try r.setLeaderLocked(from, target);
}

/// Kicks a remote person or AI partner. A person's session ends; an AI
/// partner's name is refused from then on.
pub fn kick(r: *Remote, from: Player, name: []const u8) LeaderError!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    if (!r.leadsLocked(from)) return error.NotLeader;
    const i = r.findMember(name) orelse return error.UnknownPlayer;
    const m = r.members.items[i];
    if (m.local) return error.CannotKick;
    if (from.name) |own| if (std.ascii.eqlIgnoreCase(own, m.name)) return error.CannotKick;
    // Removing the member frees its name.
    var name_buf: [64]u8 = undefined;
    const target = name_buf[0..m.name.len];
    @memcpy(target, m.name);
    if (m.ai) {
        try r.banned.append(r.gpa, try r.gpa.dupe(u8, target));
        r.dropGrantLocked(target);
    }
    r.postLocked(from, .kicked, target, &.{}) catch {};
    r.logPlayerLocked(.kick, from, "kicked {s}", .{target}, false);
    r.removeMemberLocked(i, false);
    if (!m.ai) {
        var why_buf: [96]u8 = undefined;
        r.endSessionsLocked(target, std.fmt.bufPrint(&why_buf, "{s} removed you from the game", .{displayName(from)}) catch "You were removed from the game");
    }
}

pub const AccessError = error{ NotAllowed, UnknownPlayer, OutOfMemory };

/// Whether `p` may read the inspector. People are checked by address
/// instead; an AI partner needs `--grant-inspector` or a grant.
pub fn mayInspect(r: *Remote, p: Player) bool {
    if (!p.ai) return true;
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.mayInspectLocked(p.name orelse return false);
}

fn mayInspectLocked(r: *const Remote, name: []const u8) bool {
    if (r.inspector_for_all) return true;
    for (r.inspector_grants.items) |g| if (std.ascii.eqlIgnoreCase(g, name)) return true;
    return false;
}

fn dropGrantLocked(r: *Remote, name: []const u8) void {
    for (r.inspector_grants.items, 0..) |g, i| if (std.ascii.eqlIgnoreCase(g, name)) {
        r.gpa.free(r.inspector_grants.orderedRemove(i));
        return;
    };
}

/// Lets the AI partner `name` read the inspector, or stops it. Only a
/// person on this machine may.
pub fn setInspectorAccess(r: *Remote, from: Player, name: []const u8, grant: bool) AccessError!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    if (!from.local or from.ai) return error.NotAllowed;
    const i = r.findMember(name) orelse return error.UnknownPlayer;
    const m = r.members.items[i];
    if (!m.ai) return error.UnknownPlayer;
    var has = false;
    for (r.inspector_grants.items) |g| has = has or std.ascii.eqlIgnoreCase(g, m.name);
    if (has == grant) return;
    if (grant) {
        try r.inspector_grants.append(r.gpa, try r.gpa.dupe(u8, m.name));
    } else {
        r.dropGrantLocked(m.name);
    }
    r.postLocked(from, if (grant) .granted else .revoked, m.name, &.{}) catch {};
    if (grant) {
        r.logPlayerLocked(.access, from, "let {s} read the inspector", .{m.name}, false);
    } else {
        r.logPlayerLocked(.access, from, "stopped {s} reading the inspector", .{m.name}, false);
    }
}

/// Ends the sessions of the person `name` (or of every remote person but
/// the leader, for null), remembering why.
fn endSessionsLocked(r: *Remote, name: ?[]const u8, why: []const u8) void {
    var i: usize = 0;
    while (i < r.sessions.items.len) {
        const s = r.sessions.items[i];
        const ends = if (name) |n|
            (if (s.name) |sn| std.ascii.eqlIgnoreCase(sn, n) else false)
        else if (r.leader) |leader|
            !(if (s.name) |sn| std.ascii.eqlIgnoreCase(sn, leader) else false)
        else
            true;
        if (!ends) {
            i += 1;
            continue;
        }
        _ = r.sessions.swapRemove(i);
        if (s.name) |sn| {
            if (r.findMember(sn)) |m| if (!r.members.items[m].ai) r.removeMemberLocked(m, false);
            r.gpa.free(sn);
        }
        if (r.kicked.items.len >= max_kicked) r.gpa.free(r.kicked.orderedRemove(0).why);
        const why_copy = r.gpa.dupe(u8, why) catch continue;
        r.kicked.append(r.gpa, .{ .token = s.token, .why = why_copy }) catch r.gpa.free(why_copy);
    }
}

// Remote access: the password and sessions

/// Turns on remote access with `password`.
pub fn setPassword(r: *Remote, password: Password) void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.password = password;
}

pub fn listening(r: *Remote) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.password != null;
}

pub const Login = union(enum) {
    ok: Token,
    wrong,
    /// Too many guesses; try again later.
    slow,
};

/// Checks a password guess from the address `key`, starting a session if
/// it is right.
pub fn login(r: *Remote, key: AddressKey, client: []const u8, guess: []const u8) !Login {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const password = r.password orelse return .wrong;
    const t = r.now();
    const oldest = r.attempts[r.next_attempt];
    if (t - oldest < 1000) return .slow;
    const failure = for (r.failures.items) |*f| {
        if (std.mem.eql(u8, &f.key, &key)) break f;
    } else null;
    if (failure) |f| if (t < f.until) return .slow;
    r.attempts[r.next_attempt] = t;
    r.next_attempt = (r.next_attempt + 1) % r.attempts.len;

    if (!password.matches(guess)) {
        if (failure) |f| {
            f.count += 1;
            f.until = t + @min(@as(i64, 1000) << @intCast(@min(f.count - 1, 16)), max_delay_ms);
        } else {
            try r.failures.append(r.gpa, .{ .key = key, .count = 1, .until = t + 1000 });
        }
        r.logLocked(.login, client, "wrong password", true);
        return .wrong;
    }
    if (failure) |f| f.until = 0;
    var token: Token = undefined;
    try r.io.randomSecure(&token);
    try r.sessions.append(r.gpa, .{ .token = token });
    r.logLocked(.login, client, "gave the password", false);
    return .{ .ok = token };
}

pub const SessionState = union(enum) {
    none,
    /// Ended, by a kick or a new password; why is copied into the caller's
    /// buffer.
    ended: []const u8,
    /// A session, with the name it joined under, if any.
    valid: ?[]const u8,
};

/// Looks up a session cookie, copying any name into `buf`.
pub fn session(r: *Remote, token: Token, buf: []u8) SessionState {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    for (r.sessions.items) |s| {
        if (!std.crypto.timing_safe.eql(Token, s.token, token)) continue;
        const name = s.name orelse return .{ .valid = null };
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return .{ .valid = buf[0..n] };
    }
    for (r.kicked.items) |k| {
        if (!std.crypto.timing_safe.eql(Token, k.token, token)) continue;
        const n = @min(k.why.len, buf.len);
        @memcpy(buf[0..n], k.why[0..n]);
        return .{ .ended = buf[0..n] };
    }
    return .none;
}

/// Gives a remote session its name, which must be free.
pub fn joinSession(r: *Remote, token: Token, name: []const u8) TouchError!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    r.pruneLocked();
    const s = for (r.sessions.items) |*s| {
        if (std.crypto.timing_safe.eql(Token, s.token, token)) break s;
    } else return error.Kicked;
    if (s.name) |old| if (std.ascii.eqlIgnoreCase(old, name)) return;
    for (r.sessions.items) |other| if (other.name) |n| if (std.ascii.eqlIgnoreCase(n, name)) return error.NameTaken;
    if (r.findMember(name) != null) return error.NameTaken;
    const copy = try r.gpa.dupe(u8, name);
    if (s.name) |old| {
        if (r.findMember(old)) |i| r.removeMemberLocked(i, true);
        r.gpa.free(old);
    }
    s.name = copy;
    try r.touchLocked(copy, false, false);
}

pub const PasswordError = error{ NotListening, NotAllowed, EntropyUnavailable, Canceled, OutOfMemory };

/// Copies the password into `buf` for the console, a local client or a
/// leader who is a person, logging the read.
pub fn readPassword(r: *Remote, p: Player, buf: *[Password.max_len]u8, why: []const u8) PasswordError![]const u8 {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    const password = r.password orelse return error.NotListening;
    if (p.ai or !(p.local or r.leadsLocked(p))) return error.NotAllowed;
    r.logPlayerLocked(.password, p, "{s} the password", .{why}, false);
    const text = password.slice();
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

/// Whether `p` may see and change the password: the console, a local
/// client or a leader who is a person, with `--listen`.
pub fn managesPassword(r: *Remote, p: Player) bool {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    return r.password != null and !p.ai and (p.local or r.leadsLocked(p));
}

/// Changes the password, generating one if `new` is null, and ends every
/// remote session but the leader's. The console, local clients and the
/// leader may; an AI leader may only generate one.
pub fn changePassword(r: *Remote, from: Player, new: ?[]const u8) PasswordError!void {
    r.mutex.lockUncancelable(r.io);
    defer r.mutex.unlock(r.io);
    if (r.password == null) return error.NotListening;
    const allowed = (from.local and !from.ai) or (r.leadsLocked(from) and (!from.ai or new == null));
    if (!allowed) return error.NotAllowed;
    r.password = if (new) |text| Password.fromText(text) orelse return error.NotAllowed else try Password.generate(r.io);
    var why_buf: [96]u8 = undefined;
    r.endSessionsLocked(null, std.fmt.bufPrint(&why_buf, "{s} changed the password", .{displayName(from)}) catch "The password changed");
    r.postLocked(from, .password, "", &.{}) catch {};
    r.logPlayerLocked(.password, from, "changed the password", .{}, false);
}

test "remote command and reply" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    var buf: [64]u8 = undefined;

    // Partners send commands only when taking turns.
    r.mode = .turns;
    try std.testing.expectEqual(Line.none, r.takeLine(&buf));
    const id = try r.submit("test", claude, "open mailbox");
    try std.testing.expectError(error.InvalidCommand, r.submit("test", .console, "a\nb"));
    try std.testing.expect(r.pending());

    const line = r.takeLine(&buf);
    try std.testing.expectEqualStrings("open mailbox", line.remote);
    r.capture("Opening the small mailbox reveals a leaflet.\n\n>");
    r.setStatus("West of House", "Score: 0   Moves: 1");

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!try r.writeReply(&out.writer, id));
    r.waiting();
    try std.testing.expect(try r.writeReply(&out.writer, id));
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"echo\":0,\"offset\":60,\"output\":\"Opening the small mailbox reveals a leaflet.\\n\\n>\"," ++
            "\"status\":[\"West of House\",\"Score: 0   Moves: 1\"]}",
        out.written(),
    );

    out.clearRetainingCapacity();
    try r.writeText(&out.writer, 0);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "{\"offset\":60,\"waiting\":true,\"mode\":\"turns\",\"text\":\"open mailbox\\nOpening"));
}

const claude: Player = .{ .name = "Claude", .ai = true, .local = false };

test "keyboard lines come first" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    var buf: [64]u8 = undefined;

    _ = try r.submit("test", .console, "north");
    try r.keyboard.appendSlice(r.gpa, "look\r\n/lead\nin");
    try std.testing.expectEqualStrings("look", r.takeLine(&buf).keyboard);
    try std.testing.expectEqual(ConsoleCommand.lead, r.takeLine(&buf).console);
    try std.testing.expectEqualStrings("north", r.takeLine(&buf).remote);
    try std.testing.expectEqual(Line.none, r.takeLine(&buf));
    r.keyboard_closed = true;
    try std.testing.expectEqualStrings("in", r.takeLine(&buf).keyboard);
    try std.testing.expectEqual(Line.closed, r.takeLine(&buf));

    var events: Io.Writer.Allocating = .init(std.testing.allocator);
    defer events.deinit();
    try r.writeEvents(&events.writer, 1);
    try std.testing.expect(std.mem.indexOf(u8, events.written(), "\"kind\":\"command\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, events.written(), "\"detail\":\"look\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events.written(), "/lead") == null);
}

test "debate mode and discussion" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    var buf: [64]u8 = undefined;

    try std.testing.expectEqual(Mode.debate, r.mode);
    r.mode = .turns;
    try r.setMode(.console, .debate);
    try std.testing.expectError(error.NotYourTurn, r.submit("test", claude, "north"));
    try std.testing.expectError(error.NotLeader, r.setMode(claude, .turns));
    try r.post(claude, .thought, "The mailbox might hold a clue.", &.{ "open mailbox", "north" });
    try std.testing.expectError(error.InvalidPost, r.post(.{ .name = "Gemini", .ai = true, .local = false }, .thought, "", &.{"a\tb"}));
    _ = try r.submit("test", .console, "open mailbox");
    _ = r.takeLine(&buf);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try r.writePosts(&out.writer, 1);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "{\"last\":3,\"mode\":\"debate\",\"inspector_for_all\":false,\"leader\":\"console\",\"players\":[],\"posts\":[{\"seq\":2,"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"suggestions\":[\"open mailbox\",\"north\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ai\":true,\"author\":\"Claude\",\"kind\":\"thought\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ai\":false,\"author\":\"console\",\"kind\":\"command\",\"text\":\"open mailbox\"") != null);

    try std.testing.expect(validName("Claude"));
    try std.testing.expect(validName("GPT-5 (scout)"));
    try std.testing.expect(!validName("You"));
    try std.testing.expect(!validName("Console"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a\tb"));
}

test "leadership and kicks" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    const ana: Player = .{ .name = "Ana", .local = true };
    const bo: Player = .{ .name = "Bo", .local = false };

    try r.touch(ana);
    try r.touch(claude);
    try r.touch(bo);
    try std.testing.expectError(error.NameTaken, r.touch(.{ .name = "ana", .local = false }));
    // The local side leads, every local client a coleader.
    try std.testing.expect(r.leads(ana) and r.leads(.console) and !r.leads(bo));

    try r.passLeadership(ana, "Claude");
    try std.testing.expect(r.leads(claude) and !r.leads(ana));
    try std.testing.expectError(error.NotLeader, r.passLeadership(bo, "Bo"));
    // An AI leader can kick, but not the local side.
    try std.testing.expectError(error.CannotKick, r.kick(claude, "Ana"));
    try r.kick(claude, "Bo");
    try std.testing.expect(r.findMember("Bo") == null);
    // The local side takes it back, and a kicked AI partner stays out.
    try r.passLeadership(.console, "console");
    try r.kick(ana, "Claude");
    try std.testing.expectError(error.Kicked, r.touch(claude));
    try std.testing.expect(r.leads(ana));
}

test "inspector access" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    const ana: Player = .{ .name = "Ana", .local = true };
    const bo: Player = .{ .name = "Bo", .local = false };
    try r.touch(ana);
    try r.touch(bo);
    try r.touch(claude);

    // AI partners need a grant; people are checked by address instead.
    try std.testing.expect(!r.mayInspect(claude) and r.mayInspect(ana));
    // Only a person on this machine grants it, and only to an AI partner.
    try std.testing.expectError(error.NotAllowed, r.setInspectorAccess(bo, "Claude", true));
    try std.testing.expectError(error.NotAllowed, r.setInspectorAccess(claude, "Claude", true));
    try std.testing.expectError(error.UnknownPlayer, r.setInspectorAccess(ana, "Bo", true));
    try r.setInspectorAccess(ana, "claude", true);
    try std.testing.expect(r.mayInspect(claude));
    try std.testing.expectEqual(PostKind.granted, r.posts.items[r.posts.items.len - 1].kind);
    try r.setInspectorAccess(.console, "Claude", false);
    try std.testing.expect(!r.mayInspect(claude));
    // A kick drops the grant along with the partner.
    try r.setInspectorAccess(ana, "Claude", true);
    try r.kick(ana, "Claude");
    try std.testing.expectEqual(@as(usize, 0), r.inspector_grants.items.len);
    // --grant-inspector lets every AI partner.
    r.inspector_for_all = true;
    try std.testing.expect(r.mayInspect(.{ .name = "Gemini", .ai = true, .local = false }));
}

test "first remote person leads with nobody local" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    try r.touch(.{ .name = "Bo", .local = false });
    try r.touch(.{ .name = "Cy", .local = false });
    try std.testing.expect(r.leads(.{ .name = "Bo", .local = false }));
    // The console can always reclaim it.
    try r.passLeadership(.console, "console");
    try std.testing.expect(r.leads(.console));
    // When the leader leaves, the earliest remaining player leads.
    try r.passLeadership(.console, "Cy");
    r.removeMemberLocked(r.findMember("Cy").?, true);
    try std.testing.expect(r.leads(.{ .name = "Bo", .local = false }));
}

test "password and sessions" {
    var r: Remote = .init(std.testing.allocator, std.testing.io);
    defer r.deinit();
    r.setPassword(Password.fromText("amber-otter-glide").?);
    const key: AddressKey = @splat(7);

    try std.testing.expectEqual(Login.wrong, try r.login(key, "test", "amber"));
    // A second guess straight away is too soon.
    try std.testing.expectEqual(Login.slow, try r.login(key, "test", "amber otter glide"));
    r.failures.items[0].until = 0;
    const token = (try r.login(key, "test", "Amber Otter Glide")).ok;

    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), r.session(token, &buf).valid);
    try r.joinSession(token, "Bo");
    try std.testing.expectEqualStrings("Bo", r.session(token, &buf).valid.?);

    const bo: Player = .{ .name = "Bo", .local = false };
    var pw: [Password.max_len]u8 = undefined;
    try std.testing.expect(r.leads(bo));
    try std.testing.expectEqualStrings("amber-otter-glide", try r.readPassword(bo, &pw, "copied"));
    try std.testing.expectError(error.NotAllowed, r.readPassword(claude, &pw, "copied"));

    // A new password ends every remote session but the leader's.
    try r.passLeadership(.console, "console");
    try r.changePassword(.console, "new words here");
    try std.testing.expectEqualStrings("console changed the password", r.session(token, &buf).ended);
    try std.testing.expect(r.password.?.matches("newwordshere"));
}
