//! The rules of playing together: the players and who leads them, the
//! mode, kicks, inspector access, the discussion, remote access and the
//! audit log. Plain logic under one lock, with the time and randomness
//! from a `World`, so tests can step the clock.
//!
//! Callers that also hold the hub's lock take it first.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Access = @import("Access.zig");
const AuditLog = @import("AuditLog.zig");
const Discussion = @import("Discussion.zig");
const Password = @import("Password.zig");
const Players = @import("Players.zig");
const World = @import("world.zig").World;
const protocol = @import("protocol");

const Group = @This();

gpa: Allocator,
/// For the lock only; the time and randomness come from `world`.
io: Io,
world: World,
/// Guards everything below, which the interpreter, keyboard and server
/// threads share.
mutex: Io.Mutex = .init,

mode: Mode = .debate,
players: Players = .{},
discussion: Discussion = .{},
access: Access = .{},
audit: AuditLog = .{},
/// Who sent the latest command, for blaming a restart on them.
actor_name: [64]u8 = undefined,
actor_len: ?usize = null,
actor_ai: bool = false,

pub const Player = Players.Player;
pub const PostKind = Discussion.PostKind;
pub const Kind = AuditLog.Kind;
pub const Token = Access.Token;
pub const AddressKey = Access.AddressKey;
pub const Login = Access.Login;
pub const SessionState = Access.SessionState;
pub const validName = Players.validName;

pub const max_command = 200;
/// A person who hasn't been heard from in a minute has left; the play
/// page asks for something at least every 20 seconds. AI partners may
/// think for longer.
const person_timeout_ms = 60_000;
const partner_timeout_ms = 10 * 60_000;

/// How the players share the game.
pub const Mode = enum {
    /// Only the leader sends commands; the others argue and suggest them.
    /// The default.
    debate,
    /// Anyone may send commands; they take turns.
    turns,
};

pub fn init(gpa: Allocator, io: Io, world: World) Group {
    return .{ .gpa = gpa, .io = io, .world = world };
}

pub fn deinit(g: *Group) void {
    g.players.deinit(g.gpa);
    g.discussion.deinit(g.gpa);
    g.access.deinit(g.gpa);
    g.audit.deinit(g.gpa);
}

fn lock(g: *Group) void {
    g.mutex.lockUncancelable(g.io);
}

fn unlock(g: *Group) void {
    g.mutex.unlock(g.io);
}

/// Whether `text` can be a command: one line of printable text.
pub fn validCommand(text: []const u8) bool {
    if (text.len > max_command) return false;
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

// The audit log

/// What an event from this machine says it came from.
pub const local_address = "this machine";

/// Records an event in the audit log.
pub fn log(g: *Group, kind: Kind, client: []const u8, detail: []const u8, suspicious: bool) void {
    g.logFrom(kind, client, "", detail, suspicious);
}

/// Records an event from the address `from` ("this machine" or a remote
/// address).
pub fn logFrom(g: *Group, kind: Kind, client: []const u8, from: []const u8, detail: []const u8, suspicious: bool) void {
    g.lock();
    defer g.unlock();
    g.audit.add(g.gpa, g.world.now(), kind, client, from, detail, suspicious);
}

/// Logs an event about `p`, naming them.
fn logPlayerLocked(g: *Group, kind: Kind, p: Player, comptime fmt: []const u8, args: anytype, suspicious: bool) void {
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    g.audit.add(g.gpa, g.world.now(), kind, displayName(p), "", detail, suspicious);
}

fn displayName(p: Player) []const u8 {
    return p.name orelse "console";
}

/// The sequence number of the latest event, or 0.
pub fn lastEvent(g: *Group) u64 {
    g.lock();
    defer g.unlock();
    return g.audit.last();
}

/// The events after `since`, copied into `arena`. A client not on this
/// machine sees "remote" in place of a remote address.
pub fn events(g: *Group, arena: Allocator, since: u64, show_addresses: bool) Allocator.Error!protocol.Events {
    g.lock();
    defer g.unlock();
    var list: std.ArrayList(protocol.Event) = .empty;
    for (g.audit.events.items) |e| {
        if (e.seq <= since) continue;
        try list.append(arena, .{
            .seq = e.seq,
            .time = e.time,
            .kind = @tagName(e.kind),
            .suspicious = e.suspicious,
            .client = try arena.dupe(u8, e.client),
            .from = if (show_addresses or e.from.len == 0 or std.mem.eql(u8, e.from, local_address)) try arena.dupe(u8, e.from) else "remote",
            .detail = try arena.dupe(u8, e.detail),
        });
    }
    return .{ .last = g.audit.last(), .events = list.items };
}

// Commands and the discussion

/// Whether `p` may send commands now: anyone taking turns, only the
/// leader in debate.
pub fn maySend(g: *Group, p: Player) bool {
    g.lock();
    defer g.unlock();
    return g.mode == .turns or g.players.leads(p);
}

/// Notes a line the game took: typed at the keyboard (logged, by the
/// console) or a command from the web by `author`.
pub fn heard(g: *Group, author: Player, line: []const u8, keyboard: bool) void {
    g.lock();
    defer g.unlock();
    if (keyboard) g.audit.add(g.gpa, g.world.now(), .keyboard, "keyboard", "", line, false);
    g.postLocked(author, .command, line, &.{}) catch {};
    g.actor_len = if (author.name) |n| @min(n.len, g.actor_name.len) else null;
    if (author.name) |n| @memcpy(g.actor_name[0..g.actor_len.?], n[0..g.actor_len.?]);
    g.actor_ai = author.ai;
}

/// The game restarted: posts and logs it under whoever sent the latest
/// command, which confirmed it, or the console.
pub fn restarted(g: *Group) void {
    g.lock();
    defer g.unlock();
    const by: Player = if (g.actor_len) |n| .{ .name = g.actor_name[0..n], .ai = g.actor_ai } else .console;
    g.postLocked(by, .restarted, "", &.{}) catch {};
    g.audit.add(g.gpa, g.world.now(), .game, displayName(by), "", "restarted the game", false);
}

pub const PostError = error{ InvalidPost, OutOfMemory };

/// Adds a thought or message to the discussion.
pub fn post(g: *Group, author: Player, kind: PostKind, text: []const u8, suggestions: []const []const u8) PostError!void {
    if (kind != .thought and kind != .message) return error.InvalidPost;
    if (text.len > Discussion.max_post or !std.unicode.utf8ValidateSlice(text)) return error.InvalidPost;
    if (suggestions.len > Discussion.max_suggestions) return error.InvalidPost;
    for (suggestions) |s| if (s.len == 0 or !validCommand(s)) return error.InvalidPost;
    if (text.len == 0 and suggestions.len == 0) return error.InvalidPost;
    g.lock();
    defer g.unlock();
    try g.postLocked(author, kind, text, suggestions);
}

fn postLocked(g: *Group, author: Player, kind: PostKind, text: []const u8, suggestions: []const []const u8) !void {
    try g.discussion.add(g.gpa, g.world.now(), author.name, author.ai, kind, text, suggestions);
}

pub const LeaderError = error{ NotLeader, UnknownPlayer, CannotKick, OutOfMemory };

/// Sets the mode; only the leader may.
pub fn setMode(g: *Group, from: Player, mode: Mode) LeaderError!void {
    g.lock();
    defer g.unlock();
    if (!g.players.leads(from)) return error.NotLeader;
    if (g.mode == mode) return;
    g.mode = mode;
    g.postLocked(from, .mode, @tagName(mode), &.{}) catch {};
}

pub fn currentMode(g: *Group) Mode {
    g.lock();
    defer g.unlock();
    return g.mode;
}

/// The sequence number of the latest post, or 0.
pub fn lastPost(g: *Group) u64 {
    g.lock();
    defer g.unlock();
    return g.discussion.last();
}

/// The mode, the leader, the players and the posts after `since`, copied
/// into `arena`.
pub fn discussionSince(g: *Group, arena: Allocator, since: u64) Allocator.Error!protocol.Discussion {
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    const members = try arena.alloc(protocol.Member, g.players.members.items.len);
    for (g.players.members.items, members) |m, *out| out.* = .{
        .name = try arena.dupe(u8, m.name),
        .ai = m.ai,
        .local = m.local,
        .leader = g.players.leads(m.player()),
        .inspector = m.ai and g.players.mayInspect(m.name),
    };
    var posts: std.ArrayList(protocol.Post) = .empty;
    for (g.discussion.posts.items) |p| {
        if (p.seq <= since) continue;
        const suggestions = try arena.alloc([]const u8, p.suggestions.len);
        for (p.suggestions, suggestions) |text, *out| out.* = try arena.dupe(u8, text);
        try posts.append(arena, .{
            .seq = p.seq,
            .time = p.time,
            .ai = p.ai,
            .author = try arena.dupe(u8, p.author orelse "console"),
            .kind = @tagName(p.kind),
            .text = try arena.dupe(u8, p.text),
            .suggestions = suggestions,
        });
    }
    return .{
        .last = g.discussion.last(),
        .mode = @tagName(g.mode),
        .inspector_for_all = g.players.inspector_for_all,
        .leader = try arena.dupe(u8, g.players.leader orelse "console"),
        .players = members,
        .posts = posts.items,
    };
}

// Players and leadership

pub const TouchError = error{ NameTaken, Kicked, OutOfMemory };

/// Notes that a named player is here, adding them the first time. A name
/// belongs to one player at a time; AI partners who were kicked stay out.
pub fn touch(g: *Group, p: Player) TouchError!void {
    const name = p.name orelse return;
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    try g.touchLocked(name, p.ai, p.local);
}

fn touchLocked(g: *Group, name: []const u8, ai: bool, local: bool) TouchError!void {
    const players = &g.players;
    if (players.find(name)) |i| {
        const m = &players.members.items[i];
        if (m.ai != ai or m.local != local) return error.NameTaken;
        m.seen = g.world.now();
        return;
    }
    if (ai and players.isBanned(name)) return error.Kicked;
    const copy = try g.gpa.dupe(u8, name);
    errdefer g.gpa.free(copy);
    try players.members.append(g.gpa, .{ .name = copy, .ai = ai, .local = local, .order = players.next_order, .seen = g.world.now() });
    players.next_order += 1;
    const p: Player = .{ .name = copy, .ai = ai, .local = local };
    g.postLocked(p, .joined, "", &.{}) catch {};
    // AI partners connect from this machine but never count as local, so
    // only people are said to be local or remote.
    g.logPlayerLocked(.join, p, "joined ({s})", .{
        if (ai) "AI partner" else if (local) "person, local" else "person, remote",
    }, false);
    // With nobody local on the play page, the first remote person leads.
    if (!ai and !local and players.leader == null and !players.anyLocalPerson()) g.setLeaderLocked(p, p) catch {};
}

/// Drops players who have gone quiet, choosing a new leader if the
/// leader was one of them.
fn pruneLocked(g: *Group) void {
    const t = g.world.now();
    var i: usize = 0;
    while (i < g.players.members.items.len) {
        const m = g.players.members.items[i];
        const timeout: i64 = if (m.ai) partner_timeout_ms else person_timeout_ms;
        if (t - m.seen < timeout) {
            i += 1;
            continue;
        }
        g.removeMemberLocked(i, true);
    }
}

/// Removes member `i`; if they led, the earliest remaining player leads.
fn removeMemberLocked(g: *Group, i: usize, left: bool) void {
    const players = &g.players;
    const m = players.members.orderedRemove(i);
    defer g.gpa.free(m.name);
    const p = m.player();
    if (left) {
        g.postLocked(p, .left, "", &.{}) catch {};
        g.logPlayerLocked(.join, p, "left", .{}, false);
    }
    const led = if (players.leader) |name| std.ascii.eqlIgnoreCase(name, m.name) else false;
    if (!led) return;
    if (players.members.items.len == 0) {
        g.setLeaderLocked(.console, .console) catch {};
        return;
    }
    // Members stay in join order.
    const heir = players.members.items[0].player();
    g.setLeaderLocked(heir, if (heir.local) .console else heir) catch {};
}

/// Makes `to` the leader (the console stands for the local side), posting
/// and logging the change on behalf of `by`.
fn setLeaderLocked(g: *Group, by: Player, to: Player) !void {
    const new: ?[]u8 = if (to.local and !to.ai) null else try g.gpa.dupe(u8, to.name.?);
    if (g.players.leader) |old| g.gpa.free(old);
    g.players.leader = new;
    const name = new orelse "console";
    g.postLocked(by, .leader, name, &.{}) catch {};
    g.logPlayerLocked(.leader, by, "leadership to {s}", .{name}, false);
}

pub fn leads(g: *Group, p: Player) bool {
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    return g.players.leads(p);
}

/// Passes the leadership to the player named `to`, or to the local side
/// for "console". The local side can always take it back.
pub fn passLeadership(g: *Group, from: Player, to: []const u8) LeaderError!void {
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    if (std.ascii.eqlIgnoreCase(to, "console")) {
        if (!g.players.leads(from) and !(from.local and !from.ai)) return error.NotLeader;
        if (g.players.leader == null) return;
        return g.setLeaderLocked(from, .console);
    }
    if (!g.players.leads(from)) return error.NotLeader;
    const i = g.players.find(to) orelse return error.UnknownPlayer;
    const target = g.players.members.items[i].player();
    if (g.players.leads(target)) return;
    try g.setLeaderLocked(from, target);
}

/// Kicks a remote person or AI partner. A person's session ends; an AI
/// partner's name is refused from then on.
pub fn kick(g: *Group, from: Player, name: []const u8) LeaderError!void {
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    if (!g.players.leads(from)) return error.NotLeader;
    const i = g.players.find(name) orelse return error.UnknownPlayer;
    const m = g.players.members.items[i];
    if (m.local) return error.CannotKick;
    if (from.name) |own| if (std.ascii.eqlIgnoreCase(own, m.name)) return error.CannotKick;
    // Removing the member frees its name.
    var name_buf: [64]u8 = undefined;
    const target = name_buf[0..m.name.len];
    @memcpy(target, m.name);
    if (m.ai) {
        try g.players.banned.append(g.gpa, try g.gpa.dupe(u8, target));
        g.players.dropGrant(g.gpa, target);
    }
    g.postLocked(from, .kicked, target, &.{}) catch {};
    g.logPlayerLocked(.kick, from, "kicked {s}", .{target}, false);
    g.removeMemberLocked(i, false);
    if (!m.ai) {
        var why_buf: [96]u8 = undefined;
        g.endSessionsLocked(target, std.fmt.bufPrint(&why_buf, "{s} removed you from the game", .{displayName(from)}) catch "You were removed from the game");
    }
}

// The inspector

pub const AccessError = error{ NotAllowed, UnknownPlayer, OutOfMemory };

/// Lets every AI partner read the inspector (`--grant-inspector`).
pub fn grantInspectorToAll(g: *Group) void {
    g.lock();
    defer g.unlock();
    g.players.inspector_for_all = true;
}

/// Whether `p` may read the inspector. People are checked by address
/// instead; an AI partner needs `--grant-inspector` or a grant.
pub fn mayInspect(g: *Group, p: Player) bool {
    if (!p.ai) return true;
    g.lock();
    defer g.unlock();
    return g.players.mayInspect(p.name orelse return false);
}

/// Lets the AI partner `name` read the inspector, or stops it. Only a
/// person on this machine may.
pub fn setInspectorAccess(g: *Group, from: Player, name: []const u8, grant: bool) AccessError!void {
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    if (!from.local or from.ai) return error.NotAllowed;
    const i = g.players.find(name) orelse return error.UnknownPlayer;
    const m = g.players.members.items[i];
    if (!m.ai) return error.UnknownPlayer;
    if (g.players.granted(m.name) == grant) return;
    if (grant) {
        try g.players.inspector_grants.append(g.gpa, try g.gpa.dupe(u8, m.name));
    } else {
        g.players.dropGrant(g.gpa, m.name);
    }
    g.postLocked(from, if (grant) .granted else .revoked, m.name, &.{}) catch {};
    if (grant) {
        g.logPlayerLocked(.access, from, "let {s} read the inspector", .{m.name}, false);
    } else {
        g.logPlayerLocked(.access, from, "stopped {s} reading the inspector", .{m.name}, false);
    }
}

/// Clears the discussion, leaving a post that says who did. Only the
/// console and people on this machine may; it has nothing to do with a
/// restart.
pub fn clearDiscussion(g: *Group, from: Player) AccessError!void {
    g.lock();
    defer g.unlock();
    if (!from.local or from.ai) return error.NotAllowed;
    g.discussion.clear(g.gpa);
    g.postLocked(from, .cleared, "", &.{}) catch {};
    g.logPlayerLocked(.game, from, "cleared the discussion", .{}, false);
}

// Remote access: the password and sessions

/// Ends the sessions of the person `name` (or of every remote person but
/// the leader, for null), remembering why.
fn endSessionsLocked(g: *Group, name: ?[]const u8, why: []const u8) void {
    const sessions = &g.access.sessions;
    var i: usize = 0;
    while (i < sessions.items.len) {
        const s = sessions.items[i];
        const ends = if (name) |n|
            (if (s.name) |sn| std.ascii.eqlIgnoreCase(sn, n) else false)
        else if (g.players.leader) |leader|
            !(if (s.name) |sn| std.ascii.eqlIgnoreCase(sn, leader) else false)
        else
            true;
        if (!ends) {
            i += 1;
            continue;
        }
        if (g.access.end(g.gpa, i, why)) |sn| {
            if (g.players.find(sn)) |m| if (!g.players.members.items[m].ai) g.removeMemberLocked(m, false);
            g.gpa.free(sn);
        }
    }
}

/// Turns on remote access with `password`.
pub fn setPassword(g: *Group, password: Password) void {
    g.lock();
    defer g.unlock();
    g.access.password = password;
}

pub fn listening(g: *Group) bool {
    g.lock();
    defer g.unlock();
    return g.access.password != null;
}

/// Checks a password guess from the address `key`, starting a session if
/// it is right.
pub fn login(g: *Group, key: AddressKey, client: []const u8, from: []const u8, guess: []const u8) !Login {
    g.lock();
    defer g.unlock();
    const result = try g.access.login(g.gpa, g.world, key, guess);
    switch (result) {
        .ok => g.audit.add(g.gpa, g.world.now(), .login, client, from, "gave the password", false),
        .wrong => if (g.access.password != null) g.audit.add(g.gpa, g.world.now(), .login, client, from, "wrong password", true),
        .slow => {},
    }
    return result;
}

/// Looks up a session cookie, copying any name into `buf`.
pub fn session(g: *Group, token: Token, buf: []u8) SessionState {
    g.lock();
    defer g.unlock();
    return g.access.session(token, buf);
}

/// Gives a remote session its name, which must be free.
pub fn joinSession(g: *Group, token: Token, name: []const u8) TouchError!void {
    g.lock();
    defer g.unlock();
    g.pruneLocked();
    const s = g.access.find(token) orelse return error.Kicked;
    if (s.name) |old| if (std.ascii.eqlIgnoreCase(old, name)) return;
    if (g.access.nameTaken(name)) return error.NameTaken;
    if (g.players.find(name) != null) return error.NameTaken;
    const copy = try g.gpa.dupe(u8, name);
    if (s.name) |old| {
        if (g.players.find(old)) |i| g.removeMemberLocked(i, true);
        g.gpa.free(old);
    }
    s.name = copy;
    try g.touchLocked(copy, false, false);
}

pub const PasswordError = error{ NotListening, NotAllowed, EntropyUnavailable, OutOfMemory };

/// Copies the password into `buf` for the console, a local client or a
/// leader who is a person, logging the read.
pub fn readPassword(g: *Group, p: Player, buf: *[Password.max_len]u8, why: []const u8) PasswordError![]const u8 {
    g.lock();
    defer g.unlock();
    const password = g.access.password orelse return error.NotListening;
    if (p.ai or !(p.local or g.players.leads(p))) return error.NotAllowed;
    g.logPlayerLocked(.password, p, "{s} the password", .{why}, false);
    const text = password.slice();
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

/// Whether `p` may see and change the password: the console, a local
/// client or a leader who is a person, with `--listen`.
pub fn managesPassword(g: *Group, p: Player) bool {
    g.lock();
    defer g.unlock();
    return g.access.password != null and !p.ai and (p.local or g.players.leads(p));
}

/// Changes the password, generating one if `new` is null, and ends every
/// remote session but the leader's. The console, local clients and the
/// leader may; an AI leader may only generate one.
pub fn changePassword(g: *Group, from: Player, new: ?[]const u8) PasswordError!void {
    g.lock();
    defer g.unlock();
    if (g.access.password == null) return error.NotListening;
    const allowed = (from.local and !from.ai) or (g.players.leads(from) and (!from.ai or new == null));
    if (!allowed) return error.NotAllowed;
    g.access.password = if (new) |text| Password.fromText(text) orelse return error.NotAllowed else try Password.generate(g.world);
    var why_buf: [96]u8 = undefined;
    g.endSessionsLocked(null, std.fmt.bufPrint(&why_buf, "{s} changed the password", .{displayName(from)}) catch "The password changed");
    g.postLocked(from, .password, "", &.{}) catch {};
    g.logPlayerLocked(.password, from, "changed the password", .{}, false);
}
