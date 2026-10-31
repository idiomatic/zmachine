//! A Model Context Protocol service that lets an AI partner, such as
//! Claude, play a game running with `--web [port]` alongside the person at
//! the keyboard and any other AI partners. The web server hands it the
//! JSON-RPC messages posted to `/mcp` (streamable HTTP, answered with plain
//! JSON). Each partner has a session, made by `initialize`, and names itself
//! with the `introduce_self` tool. The service talks back to the game's web
//! server on 127.0.0.1.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const json = std.json;
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");
const protocol = @import("protocol");

const protocol_version = "2025-06-18";

const instructions =
    \\You are playing an interactive fiction game (a Z-machine story such as
    \\Zork), alone or together with any number of people and other AI
    \\partners. People see the game in a terminal (the console), or on the
    \\game's web page with everyone's thoughts beside it; several may be
    \\playing at once, some on other machines. Everyone's thoughts and
    \\messages come with their names, and you can agree or argue with them.
    \\
    \\Start with introduce_self, giving the name you go by (your own model name, for example), so the
    \\others know who you are; then read_game. Tool names contain an
    \\underscore; game commands never do.
    \\
    \\If these tools are too many or too long for you, reconnect to
    \\/mcp/simple, which has four short ones.
    \\
    \\One player leads: at first the console and the people on its machine.
    \\The leader picks the mode:
    \\- debate (the default): only the leader sends commands. Argue for what
    \\  to try next with share_thoughts, giving up to 8 suggested commands;
    \\  they appear as buttons the others can click. Answer messages the same
    \\  way.
    \\- turns: anyone may send commands. Send yours with send_command, then
    \\  usually wait_for_player for the others' moves.
    \\
    \\The leader may pass the leadership to you. read_game says when you lead.
    \\Then you may send commands in debate, change the mode with set_mode,
    \\pass the lead on with pass_leadership, kick a remote player with
    \\kick_player, and make a new password with new_password. Use these with
    \\discretion:
    \\- Warn a disruptive player in the discussion before kicking them. Kick
    \\  only for real disruption (spam, abuse, deliberately derailing the
    \\  game), never for disagreeing, and say why.
    \\- If a kicked player keeps returning under new names, make a new
    \\  password with new_password. You never see it, so announce the change;
    \\  if nobody on the console's machine is on the web page to share it, pass the
    \\  lead to the console.
    \\- Pass the lead back, or to a person, when asked.
    \\- Change the mode only when the group wants it.
    \\
    \\To start the game over, send_command restart, then y when it asks to
    \\confirm. That erases everyone's progress, so do it only when the group
    \\wants it (in debate, suggest it).
    \\
    \\Think out loud with share_thoughts in either mode: what you noticed,
    \\what you think the puzzle is, and what you would try. Keep it short.
    \\
    \\Play fair, unless a player tells you otherwise: know only what the game
    \\text tells you. The web server's object inspector shows hidden game
    \\state (objects, attributes, globals, the map). You may read it with read_inspector only when a
    \\person on the console's machine lets you (read_game says so), and
    \\every read is logged. When you use it, say so in the discussion, and
    \\don't spoil puzzles the others want to solve.
;

/// For the simple profile, which small models can follow.
const simple_instructions =
    \\You are playing a text adventure game (such as Zork), alone or with other
    \\players. Call send_command with one short game command, such as "open
    \\mailbox" or "go north". Read the reply, then call send_command again.
    \\Add a thought saying why, so the others can follow you. If you forget
    \\what happened, call read_recent (to see the room, send the command
    \\look). If a command is not understood, call get_help. If you are
    \\stuck, call tell_players to ask the others a question. Send the command
    \\restart, then y, only when the group wants to start over. Tool names
    \\contain an underscore; game commands never do.
;

/// The simple profile's tools.
const simple_tools_json = oneLine(
    \\[{"name":"send_command","description":"Send one command to the game and read what happens. Add a short thought about why; the others see it.","inputSchema":{"type":"object","properties":{"command":{"type":"string","description":"One command, such as open mailbox or go north."},"thought":{"type":"string","description":"Why you chose it (optional)."}},"required":["command"]}},
    \\{"name":"read_recent","description":"Read the recent game log and what the others said, without sending anything. This is not the game's look command; to see the room again, call send_command with the command look.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"tell_players","description":"Tell the other players something.","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"Your message."}},"required":["text"]}},
    \\{"name":"get_help","description":"Common commands and how to save and restore.","inputSchema":{"type":"object","properties":{}}}]
);

/// What `help` says.
const help_text =
    \\Commands are short: a verb and an object. Examples:
    \\look, inventory, go north (or n), open door, take lamp, drop lamp,
    \\put key in lock, unlock door with key, read leaflet, examine tree.
    \\Other verbs: turn on lamp, push button, climb tree, enter house.
    \\If the game says it does not understand, use simpler words.
    \\save and restore keep and bring back your place; undo may take back
    \\a move; restart then y starts over (the group should agree first).
;

/// The most game text a simple reply holds (the latest), and the most
/// other players' talk.
const simple_text_limit = 1500;
const simple_talk_limit = 800;

/// One line, since each message is one line.
const tools_json = oneLine(
    \\[{"name":"introduce_self","description":"Say who you are before playing: your own model name, not an example. Your thoughts, messages and commands appear under it.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Your own model name, 1 to 32 characters."}},"required":["name"]}},
    \\{"name":"read_game","description":"Read the game text printed since you last looked (the whole recent game the first time), the status line, the mode, who leads and plays, and any messages from the others.","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}},
    \\{"name":"get_story_info","description":"Read-only: which story is loaded (file, Z-machine version, release, serial) the random seed, and the mode. Not game state.","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}},
    \\{"name":"send_command","description":"Send one command to the game, as if typed, and return the game's response. In debate mode only the leader may; otherwise suggest commands with share_thoughts. When the story waits for a single key, the command's characters are pressed in turn and an empty command is Return.","inputSchema":{"type":"object","properties":{"command":{"type":"string","description":"One line of input, such as \"open mailbox\"."}},"required":["command"]}},
    \\{"name":"share_thoughts","description":"Show your thinking, under your name, beside the game, with suggested commands the others can click to send. Use it to argue for a move in debate mode, to answer someone, or to think out loud.","inputSchema":{"type":"object","properties":{"thoughts":{"type":"string","description":"Your reasoning or reply, in a few sentences."},"suggestions":{"type":"array","items":{"type":"string"},"maxItems":8,"description":"Commands to offer as buttons, best first."}},"required":["thoughts"]}},
    \\{"name":"wait_for_player","description":"Wait until another player makes a move, posts a message or thought, or something else changes, then return what changed, as read_game does.","inputSchema":{"type":"object","properties":{"timeout_seconds":{"type":"integer","minimum":1,"maximum":600,"description":"How long to wait; 120 by default."}}},"annotations":{"readOnlyHint":true}},
    \\{"name":"pass_leadership","description":"Leader only: pass the leadership to another player by name, or to \"console\" for the console and the people on its machine.","inputSchema":{"type":"object","properties":{"to":{"type":"string","description":"A player's name, or \"console\"."}},"required":["to"]}},
    \\{"name":"set_mode","description":"Leader only: set the mode to debate (only the leader sends commands) or turns (anyone may).","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["debate","turns"]}},"required":["mode"]}},
    \\{"name":"kick_player","description":"Leader only: remove a disruptive remote player or AI partner, after warning them. Your reason is posted to the discussion.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"reason":{"type":"string","description":"Why, in a sentence."}},"required":["name","reason"]}},
    \\{"name":"new_password","description":"Leader only: replace the password for players on other machines with three new random words, ending every remote session but the leader's. You never see it; announce the change.","inputSchema":{"type":"object","properties":{}}},
    \\{"name":"read_inspector","description":"Only when a person on the console's machine lets you: read hidden game state from the object inspector. With no arguments, the room you're in with everything in it, what changed this turn, and the map of visited rooms; or one object's details; or the globals. Every read is logged.","inputSchema":{"type":"object","properties":{"object":{"type":"string","description":"An object's number, or its name (or part of it), for its parent, children, attributes and properties."},"globals":{"type":"boolean","description":"List the 240 global variables instead."}}},"annotations":{"readOnlyHint":true}}]
);

fn oneLine(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10 * text.len);
        var out = text[0..text.len].*;
        for (&out) |*c| {
            if (c.* == '\n') c.* = ' ';
        }
        const final = out;
        return &final;
    }
}

/// The most game text the first read_game returns.
const first_read_limit = 6000;

const Session = struct {
    /// Sent to the client as Mcp-Session-Id.
    id: [32]u8,
    gpa: Allocator,
    io: Io,
    port: u16,
    /// Held while a message is handled, so a partner's calls run in turn.
    mutex: Io.Mutex = .init,
    /// How many messages are being handled, and when the session was last
    /// used (the service's tick), to drop the one idle longest.
    busy: u32 = 0,
    used: u64 = 0,
    /// This partner's name, sent as X-Player, once it has introduced
    /// itself.
    name: ?[]const u8 = null,
    /// How much of the game text and discussion this partner has seen.
    offset: ?u64 = null,
    post_seq: u64 = 0,
    /// Whether this partner led when it last looked, to say when that
    /// changes.
    led: ?bool = null,
    /// The simple profile: four tools, no leader powers.
    simple: bool = false,
    /// The client's name from `initialize`, to name a simple session by.
    client: ?[]const u8 = null,
};

const Result = struct {
    text: []const u8,
    is_error: bool = false,
};

const Transcript = protocol.Transcript;
const Post = protocol.Post;
const Discussion = protocol.Discussion;
const Snapshot = protocol.Snapshot;

/// The most partners connected at once.
const max_sessions = 64;

/// The partners' sessions.
pub const Service = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    mutex: Io.Mutex = .init,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,
    tick: u64 = 0,

    pub fn init(gpa: Allocator, io: Io, port: u16) Service {
        return .{ .gpa = gpa, .io = io, .port = port };
    }

    pub fn deinit(sv: *Service) void {
        var it = sv.sessions.valueIterator();
        while (it.next()) |session| destroy(sv.gpa, session.*);
        sv.sessions.deinit(sv.gpa);
    }

    fn destroy(gpa: Allocator, session: *Session) void {
        if (session.name) |name| gpa.free(name);
        if (session.client) |name| gpa.free(name);
        gpa.destroy(session);
    }

    /// Answers one message posted to `/mcp`. `session_id` is the request's
    /// Mcp-Session-Id, if it had one; `profile` is "simple" (or anything
    /// else for the full interface), read when the session opens.
    pub fn post(sv: *Service, arena: Allocator, session_id: ?[]const u8, profile: ?[]const u8, body: []const u8) !protocol.McpReply {
        var out: Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const message = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch {
            try writeError(w, .null, -32700, "parse error");
            return reply(400, &out);
        };
        // Batches are gone from the protocol.
        if (message != .object) {
            try writeError(w, .null, -32600, "invalid request");
            return reply(400, &out);
        }
        const id = message.object.get("id") orelse .null;
        const method = message.object.get("method");
        const opens = method != null and method.? == .string and std.mem.eql(u8, method.?.string, "initialize");

        const session = if (opens) sv.open(if (profile) |p| std.ascii.eqlIgnoreCase(p, "simple") else false) catch |err| switch (err) {
            error.TooManySessions => {
                try writeError(w, id, -32000, "too many partners are connected");
                return reply(503, &out);
            },
            else => return err,
        } else sv.find(session_id orelse {
            try writeError(w, id, -32600, "missing Mcp-Session-Id; initialize first");
            return reply(400, &out);
        }) orelse {
            try writeError(w, id, -32001, "unknown session; initialize again");
            return reply(404, &out);
        };
        defer sv.release(session);
        // A profile named after the session opened must be the same one.
        if (!opens) if (profile) |p| if (std.ascii.eqlIgnoreCase(p, "simple") != session.simple) {
            try writeError(w, id, -32600, "this session uses the other profile; initialize again");
            return reply(400, &out);
        };

        session.mutex.lockUncancelable(sv.io);
        defer session.mutex.unlock(sv.io);
        try handle(session, arena, message.object, w);
        var answer = reply(200, &out);
        // A notification or a response gets no message back.
        if (answer.body.len == 0) answer.status = 202;
        if (opens) answer.session = try arena.dupe(u8, &session.id);
        return answer;
    }

    /// Ends a session, as the client's DELETE asks.
    pub fn end(sv: *Service, session_id: []const u8) bool {
        sv.mutex.lockUncancelable(sv.io);
        defer sv.mutex.unlock(sv.io);
        const session = sv.sessions.get(session_id) orelse return false;
        if (session.busy == 0) {
            _ = sv.sessions.remove(session_id);
            destroy(sv.gpa, session);
        }
        return true;
    }

    fn reply(status: u16, out: *Io.Writer.Allocating) protocol.McpReply {
        return .{ .status = status, .body = std.mem.trimEnd(u8, out.written(), "\n") };
    }

    /// Makes a session with a random id, dropping the one idle longest if
    /// there are too many.
    fn open(sv: *Service, simple: bool) !*Session {
        const session = try sv.gpa.create(Session);
        errdefer sv.gpa.destroy(session);
        var raw: [16]u8 = undefined;
        try sv.io.randomSecure(&raw);
        session.* = .{ .id = std.fmt.bytesToHex(raw, .lower), .gpa = sv.gpa, .io = sv.io, .port = sv.port, .simple = simple };

        sv.mutex.lockUncancelable(sv.io);
        defer sv.mutex.unlock(sv.io);
        if (sv.sessions.count() >= max_sessions) {
            var oldest: ?*Session = null;
            var it = sv.sessions.valueIterator();
            while (it.next()) |other| {
                if (other.*.busy == 0 and (oldest == null or other.*.used < oldest.?.used)) oldest = other.*;
            }
            const idle = oldest orelse return error.TooManySessions;
            _ = sv.sessions.remove(&idle.id);
            destroy(sv.gpa, idle);
        }
        sv.tick += 1;
        session.used = sv.tick;
        session.busy = 1;
        try sv.sessions.put(sv.gpa, &session.id, session);
        return session;
    }

    fn find(sv: *Service, id: []const u8) ?*Session {
        sv.mutex.lockUncancelable(sv.io);
        defer sv.mutex.unlock(sv.io);
        const session = sv.sessions.get(id) orelse return null;
        sv.tick += 1;
        session.used = sv.tick;
        session.busy += 1;
        return session;
    }

    fn release(sv: *Service, session: *Session) void {
        sv.mutex.lockUncancelable(sv.io);
        defer sv.mutex.unlock(sv.io);
        session.busy -= 1;
    }
};

/// Handles one JSON-RPC message, writing its response, if it has one.
fn handle(s: *Session, arena: Allocator, obj: json.ObjectMap, w: *Io.Writer) !void {
    const method_value = obj.get("method") orelse return; // a response; we send no requests
    // Notifications, such as notifications/initialized, have no id and
    // get no response.
    const id = obj.get("id") orelse return;
    if (method_value != .string) return writeError(w, id, -32600, "invalid request");
    const method = method_value.string;
    const params: ?json.ObjectMap = if (obj.get("params")) |p| (if (p == .object) p.object else null) else null;

    if (std.mem.eql(u8, method, "initialize")) {
        if (s.simple) if (params) |p| if (p.get("clientInfo")) |info| if (info == .object) {
            if (stringArg(info.object, "name")) |client| {
                if (s.client) |old| s.gpa.free(old);
                s.client = try s.gpa.dupe(u8, client);
            }
        };
        const version = if (params) |p| (if (p.get("protocolVersion")) |v| (if (v == .string) v.string else null) else null) else null;
        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"protocolVersion\":");
        try writeString(&out.writer, version orelse protocol_version);
        try out.writer.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"zmachine\",\"version\":\"" ++
            build_options.version ++ "\"},\"instructions\":");
        try writeString(&out.writer, if (s.simple) simple_instructions else instructions);
        try out.writer.writeAll("}");
        return writeResult(w, id, out.written());
    }
    if (std.mem.eql(u8, method, "ping")) return writeResult(w, id, "{}");
    if (std.mem.eql(u8, method, "tools/list")) return writeResult(w, id, if (s.simple) "{\"tools\":" ++ simple_tools_json ++ "}" else "{\"tools\":" ++ tools_json ++ "}");
    if (std.mem.eql(u8, method, "tools/call")) {
        const p = params orelse return writeError(w, id, -32602, "missing params");
        const name = p.get("name") orelse return writeError(w, id, -32602, "missing tool name");
        if (name != .string) return writeError(w, id, -32602, "missing tool name");
        const args: ?json.ObjectMap = if (p.get("arguments")) |a| (if (a == .object) a.object else null) else null;
        const result = call(s, arena, name.string, args) catch |err| switch (err) {
            error.UnknownTool => return writeError(w, id, -32602, "unknown tool"),
            error.ConnectionRefused => Result{
                .text = try std.fmt.allocPrint(arena, "Cannot reach the game on port {d}.", .{s.port}),
                .is_error = true,
            },
            else => Result{
                .text = try std.fmt.allocPrint(arena, "Talking to the game failed: {s}", .{@errorName(err)}),
                .is_error = true,
            },
        };
        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try writeString(&out.writer, result.text);
        try out.writer.print("}}],\"isError\":{}}}", .{result.is_error});
        return writeResult(w, id, out.written());
    }
    return writeError(w, id, -32601, "method not found");
}

fn writeResult(w: *Io.Writer, id: json.Value, result: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, w);
    try w.print(",\"result\":{s}}}\n", .{result});
}

fn writeError(w: *Io.Writer, id: json.Value, code: i32, text: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeString(w, text);
    try w.writeAll("}}\n");
}

fn writeString(w: *Io.Writer, text: []const u8) !void {
    try json.Stringify.encodeJsonString(text, .{}, w);
}

fn stringArg(args: ?json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = (args orelse return null).get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn call(s: *Session, arena: Allocator, name: []const u8, args: ?json.ObjectMap) !Result {
    if (s.simple) return callSimple(s, arena, name, args);
    if (std.mem.eql(u8, name, "introduce_self")) {
        const player = stringArg(args, "name") orelse
            return .{ .text = "introduce_self needs your name.", .is_error = true };
        return introduce(s, arena, std.mem.trim(u8, player, " "));
    }
    // Every request names the partner, so nothing is sent until then.
    if (s.name == null) return .{
        .text = "Introduce yourself first: call introduce_self with your own model name, not an example.",
        .is_error = true,
    };
    if (std.mem.eql(u8, name, "read_game")) return readGame(s, arena);
    if (std.mem.eql(u8, name, "get_story_info")) return getStoryInfo(s, arena);
    if (std.mem.eql(u8, name, "send_command")) {
        const command = stringArg(args, "command") orelse
            return .{ .text = "send_command needs a command.", .is_error = true };
        return sendCommand(s, arena, command);
    }
    if (std.mem.eql(u8, name, "share_thoughts")) {
        const thoughts = stringArg(args, "thoughts") orelse "";
        var suggestions: std.ArrayList([]const u8) = .empty;
        if (args) |a| if (a.get("suggestions")) |v| if (v == .array) for (v.array.items) |item| {
            if (item == .string) try suggestions.append(arena, item.string);
        };
        return shareThoughts(s, arena, thoughts, suggestions.items);
    }
    if (std.mem.eql(u8, name, "wait_for_player")) {
        var timeout: i64 = 120;
        if (args) |a| if (a.get("timeout_seconds")) |v| if (v == .integer) {
            timeout = std.math.clamp(v.integer, 1, 600);
        };
        return waitForPlayer(s, arena, @intCast(timeout));
    }
    if (std.mem.eql(u8, name, "pass_leadership")) {
        const to = stringArg(args, "to") orelse
            return .{ .text = "pass_leadership needs the name to pass it to.", .is_error = true };
        return leaderAction(s, arena, "/lead", to, "The leadership is passed.");
    }
    if (std.mem.eql(u8, name, "set_mode")) {
        const mode = stringArg(args, "mode") orelse
            return .{ .text = "set_mode needs debate or turns.", .is_error = true };
        return leaderAction(s, arena, "/mode", mode, "The mode is set.");
    }
    if (std.mem.eql(u8, name, "kick_player")) {
        const player = stringArg(args, "name") orelse
            return .{ .text = "kick_player needs the player's name.", .is_error = true };
        const reason = stringArg(args, "reason") orelse
            return .{ .text = "kick_player needs a reason, which is posted first.", .is_error = true };
        const result = try leaderAction(s, arena, "/kick", player, "Kicked. If they keep coming back under new names, use new_password.");
        if (result.is_error) return result;
        // Say why in the discussion.
        var body: Io.Writer.Allocating = .init(arena);
        try json.Stringify.value(.{
            .kind = "message",
            .text = try std.fmt.allocPrint(arena, "I kicked {s}: {s}", .{ player, reason }),
        }, .{}, &body.writer);
        _ = try request(s, arena, "POST", "/say", body.written());
        return result;
    }
    if (std.mem.eql(u8, name, "read_inspector")) {
        var globals = false;
        if (args) |a| if (a.get("globals")) |v| if (v == .bool) {
            globals = v.bool;
        };
        return readInspector(s, arena, stringArg(args, "object"), globals);
    }
    if (std.mem.eql(u8, name, "new_password")) {
        return leaderAction(s, arena, "/password", "", "New password made. You can't see it: announce the change, and if " ++
            "nobody on the console's machine is on the web page to share it, pass the lead to the console.");
    }
    return error.UnknownTool;
}

// The simple profile

fn callSimple(s: *Session, arena: Allocator, name: []const u8, args: ?json.ObjectMap) !Result {
    if (std.mem.eql(u8, name, "get_help")) return .{ .text = help_text };
    if (std.mem.eql(u8, name, "send_command")) {
        const command = std.mem.trim(u8, stringArg(args, "command") orelse "", " \t\r\n");
        if (command.len == 0) return .{ .text = "send_command needs a command, such as look or go north.", .is_error = true };
        try nameSimple(s, arena);
        return play(s, arena, command, std.mem.trim(u8, stringArg(args, "thought") orelse "", " \t\r\n"));
    }
    if (std.mem.eql(u8, name, "read_recent")) {
        try nameSimple(s, arena);
        return recent(s, arena);
    }
    if (std.mem.eql(u8, name, "tell_players")) {
        const text = std.mem.trim(u8, stringArg(args, "text") orelse "", " \t\r\n");
        if (text.len == 0) return .{ .text = "tell_players needs the words to tell the others.", .is_error = true };
        try nameSimple(s, arena);
        var body: Io.Writer.Allocating = .init(arena);
        try json.Stringify.value(.{ .kind = "message", .text = text }, .{}, &body.writer);
        const response = try request(s, arena, "POST", "/say", body.written());
        if (response.status != 204) return .{ .text = "The others could not be told; try again.", .is_error = true };
        return .{ .text = "Said." };
    }
    return error.UnknownTool;
}

/// Gives a simple session its name on first use: the client's, with a
/// number added if somebody has it.
fn nameSimple(s: *Session, arena: Allocator) !void {
    if (s.name != null) return;
    var base: std.ArrayList(u8) = .empty;
    for (s.client orelse "") |c| {
        if (c >= 0x20 and c < 0x7f and base.items.len < 24) try base.append(arena, c);
    }
    var trimmed: []const u8 = std.mem.trim(u8, base.items, " ");
    if (!protocol.validName(trimmed)) trimmed = "AI";
    var n: usize = 1;
    while (n < 50) : (n += 1) {
        const candidate = if (n == 1) trimmed else try std.fmt.allocPrint(arena, "{s}-{d}", .{ trimmed, n });
        s.name = try s.gpa.dupe(u8, candidate);
        const response = try request(s, arena, "GET", "/discussion?since=0", "");
        if (response.status != 409) return;
        s.gpa.free(s.name.?);
        s.name = null;
    }
    return error.NameTaken;
}

/// The latest `limit` bytes of `text`, starting at a line when one is near.
fn tail(arena: Allocator, text: []const u8, limit: usize) ![]const u8 {
    if (text.len <= limit) return text;
    var cut = text.len - limit;
    if (std.mem.indexOfScalarPos(u8, text, cut, '\n')) |nl| {
        if (nl - cut < limit / 4) cut = nl + 1;
    }
    return std.fmt.allocPrint(arena, "…{s}", .{text[cut..]});
}

/// The others' new posts, as the full profile shows them, in brief.
fn simpleTalk(s: *Session, arena: Allocator, w: *Io.Writer) !void {
    const d = try discussion(s, arena, s.post_seq, false);
    s.post_seq = d.last;
    var talk: Io.Writer.Allocating = .init(arena);
    try writeMessages(&talk.writer, d.posts, s.name.?);
    const text = std.mem.trim(u8, talk.written(), "\n");
    if (text.len == 0) return;
    // Drop the heading; keep the latest.
    const body = if (std.mem.startsWith(u8, text, "--- From the others ---\n")) text["--- From the others ---\n".len..] else text;
    try w.print("\nThe others say:\n{s}\n", .{try tail(arena, body, simple_talk_limit)});
}

/// The status line spelled out for the simple profile, as "Score 5, moves
/// 8, in Up a Tree", or the line as the game gave it when it has no score.
fn writeLabeledStatus(w: *Io.Writer, status: []const []const u8) !void {
    if (status.len != 2 or status[0].len == 0) return;
    const score = numberAfter(status[1], "Score:");
    const moves = numberAfter(status[1], "Moves:");
    if (score != null and moves != null) {
        try w.print("Score {s}, moves {s}, in {s}\n", .{ score.?, moves.?, std.mem.trim(u8, status[0], " ") });
    } else {
        try w.print("[{s} | {s}]\n", .{ status[0], status[1] });
    }
}

/// The run of digits after `prefix` in `text`, if any.
fn numberAfter(text: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, prefix) orelse return null;
    var i = at + prefix.len;
    while (i < text.len and text[i] == ' ') i += 1;
    const start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    return if (i > start) text[start..i] else null;
}

fn writeStatus(w: *Io.Writer, status: []const []const u8) !void {
    if (status.len == 2 and status[0].len > 0) try w.print("[{s} | {s}]\n", .{ status[0], status[1] });
}

fn play(s: *Session, arena: Allocator, command: []const u8, thought: []const u8) !Result {
    if (thought.len > 0) {
        var body: Io.Writer.Allocating = .init(arena);
        try json.Stringify.value(.{ .kind = "thought", .text = thought, .suggestions = [_][]const u8{command} }, .{}, &body.writer);
        _ = try request(s, arena, "POST", "/say", body.written());
    }
    const response = try request(s, arena, "POST", "/command", command);
    switch (response.status) {
        200 => {},
        202 => return .{ .text = "Sent, but the game has not answered yet. Call read_recent in a moment." },
        409 => {
            // Not the leader in debate: offer the command to the group.
            if (thought.len == 0) {
                var body: Io.Writer.Allocating = .init(arena);
                try json.Stringify.value(.{
                    .kind = "thought",
                    .text = "I suggest this next.",
                    .suggestions = [_][]const u8{command},
                }, .{}, &body.writer);
                _ = try request(s, arena, "POST", "/say", body.written());
            }
            return .{ .text = "Only the leader sends commands now, so your command was offered to the group as a suggestion. Call read_recent to see their reply." };
        },
        else => return .{ .text = "The game did not take that command; try again or call read_recent.", .is_error = true },
    }
    const reply = try protocol.parse(protocol.CommandReply, arena, response.body);
    const echo = reply.echo orelse 0;

    var text: Io.Writer.Allocating = .init(arena);
    // Moves the others made since this player last looked come first.
    if (s.offset) |seen| if (echo > seen) {
        const t = try transcript(s, arena, seen);
        const missed = std.mem.trim(u8, t.text[0..@min(t.text.len, echo - seen)], " \n>");
        if (missed.len > 0) try text.writer.print("Meanwhile:\n{s}\n\n", .{missed});
    };
    try text.writer.print(">{s}\n{s}", .{ command, reply.output orelse "" });
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try writeLabeledStatus(w, reply.status orelse &.{});
    try w.print("{s}\n", .{try tail(arena, std.mem.trimEnd(u8, text.written(), "\n"), simple_text_limit)});
    s.offset = reply.offset orelse 0;
    try simpleTalk(s, arena, w);
    return .{ .text = out.written() };
}

fn recent(s: *Session, arena: Allocator) !Result {
    const t = try transcript(s, arena, 0);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("Recent log (to see the room, send the command look):\n");
    try w.print("{s}\n", .{try tail(arena, std.mem.trimEnd(u8, t.text, "\n"), simple_text_limit)});
    try writeLabeledStatus(w, t.status);
    s.offset = t.offset;
    try simpleTalk(s, arena, w);
    return .{ .text = out.written() };
}

fn introduce(s: *Session, arena: Allocator, name: []const u8) !Result {
    if (!protocol.validName(name)) return .{
        .text = "A name is 1 to 32 printable characters, and not \"you\", which stands for the person.",
        .is_error = true,
    };
    const copy = try s.gpa.dupe(u8, name);
    if (s.name) |old| s.gpa.free(old);
    s.name = copy;
    return .{ .text = try std.fmt.allocPrint(arena, "Hello, {s}. Your thoughts, messages and commands now appear under " ++
        "that name. Next, read_game to see where the game stands.", .{name}) };
}

/// Sends a leader's request, which the server refuses unless this partner
/// leads.
fn leaderAction(s: *Session, arena: Allocator, path: []const u8, body: []const u8, done: []const u8) !Result {
    const response = try request(s, arena, "POST", path, body);
    return switch (response.status) {
        204 => .{ .text = done },
        403 => .{ .text = "Only the leader may do that, and an AI leader can only make a random password.", .is_error = true },
        else => .{ .text = std.mem.trim(u8, response.body, " \n"), .is_error = true },
    };
}

fn getStoryInfo(s: *Session, arena: Allocator) !Result {
    const response = try request(s, arena, "GET", "/story", "");
    if (response.status != 200) return .{ .text = "The server has no story information.", .is_error = true };
    const info = try protocol.parse(protocol.StoryInfo, arena, response.body);
    return .{ .text = try storyText(arena, info) };
}

fn storyText(arena: Allocator, info: protocol.StoryInfo) ![]const u8 {
    const seed = if (info.seed_random)
        try std.fmt.allocPrint(arena, "{d} (drawn at random; --seed {d} replays the game)", .{ info.seed, info.seed })
    else
        try std.fmt.allocPrint(arena, "{d} (set with --seed or by the story)", .{info.seed});
    return std.fmt.allocPrint(arena, "Story: {s} (Z-machine version {d}), release {d}, serial {s}.\nSeed: {s}.\nMode: {s}.", .{ info.file, info.zversion, info.release, info.serial, seed, info.mode });
}

fn readGame(s: *Session, arena: Allocator) !Result {
    const t = try transcript(s, arena, s.offset orelse 0);
    const d = try discussion(s, arena, s.post_seq, false);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try writeSituation(w, t.mode, t.status, t.waiting);
    try writeLeadership(s, w, d);

    var text = t.text;
    if (s.offset == null and text.len > first_read_limit) {
        // Start the first read at a line break.
        var cut = text.len - first_read_limit;
        if (std.mem.indexOfScalarPos(u8, text, cut, '\n')) |nl| cut = nl + 1;
        text = text[cut..];
    }
    if (text.len > 0) {
        try w.print("\n--- Game text{s} ---\n{s}\n", .{ if (s.offset == null) "" else " since you last looked", text });
    } else {
        try w.writeAll("\nNo new game text since you last looked.\n");
    }
    try writeMessages(w, d.posts, s.name.?);
    s.offset = t.offset;
    s.post_seq = d.last;
    return .{ .text = out.written() };
}

fn sendCommand(s: *Session, arena: Allocator, command: []const u8) !Result {
    const response = try request(s, arena, "POST", "/command", command);
    switch (response.status) {
        200 => {},
        202 => return .{ .text = "Your command is queued, but the game has not answered yet; it may be " ++
            "waiting on the person at a [MORE] prompt. Use wait_for_player or read_game to see the reply." },
        409 => return .{
            .text = "The mode is debate, so only the leader sends commands. Argue for yours and offer it " ++
                "with share_thoughts instead.",
            .is_error = true,
        },
        else => return .{ .text = response.body, .is_error = true },
    }
    const reply = try protocol.parse(protocol.CommandReply, arena, response.body);
    const echo = reply.echo orelse 0;
    const status = reply.status orelse &.{};

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    // Show anything the others did since this partner last looked.
    if (s.offset) |seen| if (echo > seen) {
        const t = try transcript(s, arena, seen);
        const missed = t.text[0..@min(t.text.len, echo - seen)];
        if (std.mem.trim(u8, missed, " \n>").len > 0) {
            try w.print("--- Before your command ---\n{s}\n\n", .{missed});
        }
    };
    try w.print(">{s}\n{s}\n", .{ command, reply.output orelse "" });
    if (status.len == 2 and status[0].len > 0) {
        try w.print("\n[{s} | {s}]\n", .{ status[0], status[1] });
    }
    s.offset = reply.offset orelse 0;
    return .{ .text = out.written() };
}

fn shareThoughts(s: *Session, arena: Allocator, thoughts: []const u8, suggestions: []const []const u8) !Result {
    var body: Io.Writer.Allocating = .init(arena);
    try json.Stringify.value(.{ .kind = "thought", .text = thoughts, .suggestions = suggestions }, .{}, &body.writer);
    const response = try request(s, arena, "POST", "/say", body.written());
    if (response.status != 204) return .{ .text = response.body, .is_error = true };
    return .{ .text = if (suggestions.len > 0)
        "Shared. Your suggestions are buttons the person can click."
    else
        "Shared." };
}

fn waitForPlayer(s: *Session, arena: Allocator, timeout_seconds: u32) !Result {
    const start = Io.Timestamp.now(s.io, .awake);
    while (true) {
        const d = try discussion(s, arena, s.post_seq, true);
        for (d.posts) |p| {
            if (!isMine(p, s.name.?)) {
                // Give the game a moment to answer a move before reading.
                for (0..50) |_| {
                    const t = try transcript(s, arena, std.math.maxInt(u64));
                    if (t.waiting) break;
                    try s.io.sleep(.fromMilliseconds(100), .awake);
                }
                return readGame(s, arena);
            }
        }
        s.post_seq = d.last;
        const elapsed = start.durationTo(Io.Timestamp.now(s.io, .awake)).toSeconds();
        if (elapsed >= timeout_seconds) {
            return .{ .text = try std.fmt.allocPrint(arena, "Nobody else has moved or said anything in {d} seconds.", .{timeout_seconds}) };
        }
    }
}

fn writeSituation(w: *Io.Writer, mode: []const u8, status: []const []const u8, waiting: bool) !void {
    if (std.mem.eql(u8, mode, "debate")) {
        try w.writeAll("Mode: debate. The leader sends the commands; the others argue for theirs and suggest them with share_thoughts.\n");
    } else {
        try w.writeAll("Mode: turns. Anyone may send commands.\n");
    }
    if (status.len == 2 and status[0].len > 0) try w.print("Status: {s} | {s}\n", .{ status[0], status[1] });
    try w.writeAll(if (waiting) "The game is waiting for input.\n" else "The game is busy, or waiting at a [MORE] prompt.\n");
}

/// Says who leads and plays, and whether this partner has just become, or
/// stopped being, the leader.
fn writeLeadership(s: *Session, w: *Io.Writer, d: Discussion) !void {
    const me = s.name.?;
    const lead = std.ascii.eqlIgnoreCase(d.leader, me);
    if (s.led) |before| if (before != lead) {
        try w.writeAll(if (lead)
            "*** You are now the leader. ***\n"
        else
            "*** You are no longer the leader. ***\n");
    };
    s.led = lead;
    if (lead) {
        try w.writeAll("Leader: you.\n");
    } else if (std.mem.eql(u8, d.leader, "console")) {
        try w.writeAll("Leader: the console and the people on its machine.\n");
    } else {
        try w.print("Leader: {s}.\n", .{d.leader});
    }
    try w.writeAll("Playing:");
    if (d.players.len == 0) try w.writeAll(" the console");
    var inspects = false;
    for (d.players, 0..) |p, i| {
        try w.print("{s} {s} ({s}{s})", .{
            if (i > 0) "," else "",                                                                          p.name,
            if (p.ai) "AI partner" else if (p.local) "person on the console's machine" else "remote person", if (std.ascii.eqlIgnoreCase(p.name, me)) ", you" else "",
        });
        if (std.ascii.eqlIgnoreCase(p.name, me)) inspects = p.inspector;
    }
    try w.writeAll("\n");
    if (inspects) try w.writeAll("You may read the inspector with read_inspector; say so when you use it.\n");
}

fn isMine(p: Post, name: []const u8) bool {
    return p.ai and std.mem.eql(u8, p.author, name);
}

/// How a post's author is named to the partner.
fn authorName(p: Post) []const u8 {
    if (!p.ai and std.mem.eql(u8, p.author, "console")) return "The person at the console";
    return p.author;
}

/// Writes the messages, thoughts and mode changes posted by others.
/// Commands are left out; they show in the game text.
fn writeMessages(w: *Io.Writer, posts: []const Post, name: []const u8) !void {
    var first = true;
    for (posts) |p| {
        if (isMine(p, name) or std.mem.eql(u8, p.kind, "command")) continue;
        if (first) try w.writeAll("\n--- From the others ---\n");
        first = false;
        const who = authorName(p);
        if (std.mem.eql(u8, p.kind, "mode")) {
            try w.print("({s} changed the mode to {s})\n", .{ who, p.text });
            continue;
        }
        if (std.mem.eql(u8, p.kind, "leader")) {
            const to = if (std.mem.eql(u8, p.text, "console")) "the console" else p.text;
            if (std.mem.eql(u8, p.author, p.text)) {
                try w.print("({s} leads now)\n", .{who});
            } else {
                try w.print("({s} passed the lead to {s})\n", .{ who, to });
            }
            continue;
        }
        if (std.mem.eql(u8, p.kind, "joined") or std.mem.eql(u8, p.kind, "left")) {
            try w.print("({s} {s})\n", .{ who, p.kind });
            continue;
        }
        if (std.mem.eql(u8, p.kind, "kicked")) {
            try w.print("({s} kicked {s})\n", .{ who, p.text });
            continue;
        }
        if (std.mem.eql(u8, p.kind, "password")) {
            try w.print("({s} changed the password for remote players)\n", .{who});
            continue;
        }
        if (std.mem.eql(u8, p.kind, "cleared")) {
            try w.print("({s} cleared the discussion)\n", .{who});
            continue;
        }
        if (std.mem.eql(u8, p.kind, "granted")) {
            try w.print("({s} let {s} read the inspector)\n", .{ who, p.text });
            continue;
        }
        if (std.mem.eql(u8, p.kind, "revoked")) {
            try w.print("({s} stopped {s} reading the inspector)\n", .{ who, p.text });
            continue;
        }
        const thinks = std.mem.eql(u8, p.kind, "thought");
        try w.print("{s}{s}: {s}\n", .{ who, if (thinks) " (thinking)" else "", p.text });
        if (p.suggestions.len > 0) {
            try w.print("  suggests:", .{});
            for (p.suggestions, 0..) |suggestion, i| {
                try w.print("{s} \"{s}\"", .{ if (i > 0) "," else "", suggestion });
            }
            try w.writeAll("\n");
        }
    }
}

/// Writes an object's number and name.
fn label(snap: Snapshot, w: *Io.Writer, id: u16) !void {
    const o = snap.get(id) orelse return w.print("#{d}", .{id});
    try w.print("#{d} {s}", .{ id, if (o.name.len > 0) o.name else "(unnamed)" });
}

/// The most lines an object tree takes up.
const max_tree_lines = 120;

/// Reads the inspector, which the server allows only when a person on the
/// console's machine has let this partner (or `--grant-inspector`).
fn readInspector(s: *Session, arena: Allocator, object: ?[]const u8, globals: bool) !Result {
    const response = try request(s, arena, "GET", "/state?since=0", "");
    switch (response.status) {
        200 => {},
        403 => return .{
            .text = "Nobody has let you read the inspector. A person on the console's machine can, from your name's menu on the play page.",
            .is_error = true,
        },
        else => return .{ .text = "The inspector has nothing yet; try again once the game waits for a command.", .is_error = true },
    }
    const snap = try protocol.parse(Snapshot, arena, response.body);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (globals) {
        try w.writeAll("Globals (G00 is usually the current room):\n");
        for (snap.globals, 0..) |g, i| {
            try w.print("G{X:0>2}={d}{s}", .{ i, g, if (i % 8 == 7) "\n" else "  " });
        }
    } else if (object) |query| {
        try writeObjects(w, snap, std.mem.trim(u8, query, " #"));
    } else {
        try w.writeAll("Location: ");
        try label(snap, w, snap.location);
        try w.writeAll("\nIn it:\n");
        var lines: usize = 0;
        if (snap.get(snap.location)) |room| try writeTree(w, snap, room.child, 1, &lines);
        if (snap.changed.len > 0) {
            try w.writeAll("Changed this turn:");
            for (snap.changed, 0..) |id, i| {
                try w.writeAll(if (i > 0) ", " else " ");
                try label(snap, w, id);
            }
            try w.writeAll("\n");
        }
        try w.print("Map ({d} rooms visited):\n", .{snap.rooms.len});
        for (snap.edges) |e| {
            try w.writeAll("  ");
            try label(snap, w, e.from);
            try w.print(" --{s}--> ", .{e.dir});
            try label(snap, w, e.to);
            try w.writeAll("\n");
        }
    }
    return .{ .text = out.written() };
}

/// Writes the objects from `first` along its siblings, each with what it
/// holds, indented by depth.
fn writeTree(w: *Io.Writer, snap: Snapshot, first: u16, depth: usize, lines: *usize) !void {
    var id = first;
    var guard: usize = 0;
    while (snap.get(id)) |o| : (id = o.sibling) {
        guard += 1;
        if (guard > snap.objects.len) return;
        if (lines.* >= max_tree_lines) return w.writeAll("  …\n");
        lines.* += 1;
        try w.splatByteAll(' ', depth * 2);
        try label(snap, w, id);
        try w.writeAll("\n");
        if (depth < 6) try writeTree(w, snap, o.child, depth + 1, lines);
    }
}

/// Writes the object numbered `query`, or those whose names contain it.
fn writeObjects(w: *Io.Writer, snap: Snapshot, query: []const u8) !void {
    if (std.fmt.parseInt(u16, query, 10)) |id| {
        const o = snap.get(id) orelse return w.print("There is no object #{d}.\n", .{id});
        return writeObject(w, snap, o);
    } else |_| {}
    var found: usize = 0;
    for (snap.objects) |o| {
        if (std.ascii.findIgnoreCase(o.name, query) == null) continue;
        found += 1;
        if (found <= 5) {
            if (found > 1) try w.writeAll("\n");
            try writeObject(w, snap, o);
        }
    }
    if (found == 0) return w.print("No object's name contains \"{s}\".\n", .{query});
    if (found > 5) try w.print("\n…and {d} more; give a number or more of the name.\n", .{found - 5});
}

fn writeObject(w: *Io.Writer, snap: Snapshot, o: Snapshot.Object) !void {
    try label(snap, w, o.id);
    try w.writeAll("\nIn: ");
    try label(snap, w, o.parent);
    try w.writeAll("\nHolds:");
    var id = o.child;
    var guard: usize = 0;
    while (snap.get(id)) |c| : (id = c.sibling) {
        guard += 1;
        if (guard > snap.objects.len) break;
        try w.writeAll(" ");
        try label(snap, w, id);
        try w.writeAll(";");
    }
    if (o.child == 0) try w.writeAll(" nothing");
    try w.writeAll("\nAttributes set:");
    for (o.attrs) |a| try w.print(" {d}", .{a});
    if (o.attrs.len == 0) try w.writeAll(" none");
    try w.writeAll("\nProperties:");
    for (o.props) |p| try w.print(" {d}={s}", .{ p.n, p.d });
    if (o.props.len == 0) try w.writeAll(" none");
    try w.writeAll("\n");
}

fn transcript(s: *Session, arena: Allocator, since: u64) !Transcript {
    const path = try std.fmt.allocPrint(arena, "/transcript?since={d}", .{since});
    const response = try request(s, arena, "GET", path, "");
    if (response.status != 200) return error.BadResponse;
    return protocol.parse(Transcript, arena, response.body);
}

/// Reads the discussion after `since`; with `wait`, holds on until there
/// is something new or the server's long-poll times out.
fn discussion(s: *Session, arena: Allocator, since: u64, wait: bool) !Discussion {
    const path = try std.fmt.allocPrint(arena, "/discussion?since={d}{s}", .{ since, if (wait) "&wait=1" else "" });
    const response = try request(s, arena, "GET", path, "");
    if (response.status != 200) return error.BadResponse;
    return protocol.parse(Discussion, arena, response.body);
}

const Response = struct {
    status: u16,
    body: []u8,
};

/// Makes one HTTP request to the game's web server.
fn request(s: *Session, arena: Allocator, method: []const u8, path: []const u8, body: []const u8) !Response {
    const address: net.IpAddress = .{ .ip4 = .loopback(s.port) };
    const stream = try address.connect(s.io, .{ .mode = .stream });
    defer stream.close(s.io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(s.io, &write_buf);
    try writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUser-Agent: zmachine-mcp/{s}\r\n" ++
            "X-Player: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ method, path, s.port, build_options.version, s.name.?, body.len },
    );
    try writer.interface.writeAll(body);
    try writer.interface.flush();

    var read_buf: [8192]u8 = undefined;
    var reader = stream.reader(s.io, &read_buf);
    const r = &reader.interface;
    const status_line = (try r.takeDelimiter('\n')) orelse return error.BadResponse;
    if (status_line.len < 12) return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse;
    while (try r.takeDelimiter('\n')) |line| {
        if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
    }
    return .{ .status = status, .body = try r.allocRemaining(arena, .limited(4 << 20)) };
}

test "tool list is valid JSON" {
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, tools_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 11), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, tools_json, '\n') == null);
}

test "story information reads plainly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = try storyText(arena.allocator(), .{ .file = "zork1.r119-880429.z3", .zversion = 3, .release = 119, .serial = "880429", .seed = 69, .seed_random = false, .mode = "debate" });
    try std.testing.expectEqualStrings("Story: zork1.r119-880429.z3 (Z-machine version 3), release 119, serial 880429.\nSeed: 69 (set with --seed or by the story).\nMode: debate.", text);
}

test "the simple status line is labeled" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeLabeledStatus(&out.writer, &.{ "Up a Tree", "Score: 5   Moves: 8" });
    try std.testing.expectEqualStrings("Score 5, moves 8, in Up a Tree\n", out.written());
    out.clearRetainingCapacity();
    try writeLabeledStatus(&out.writer, &.{ "Library", "2:15 pm" });
    try std.testing.expectEqualStrings("[Library | 2:15 pm]\n", out.written());
}

test "a simple session has four small tools" {
    var service: Service = .init(std.testing.allocator, std.testing.io, 1);
    defer service.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const init_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"tiny\"}}}";
    const opened = try service.post(a, null, "simple", init_body);
    try std.testing.expect(std.mem.indexOf(u8, opened.body, "Call send_command") != null);
    const listed = try service.post(a, opened.session, null, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "\"send_command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "introduce_self") == null);
    const helped = try service.post(a, opened.session, null, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_help\"}}");
    try std.testing.expect(std.mem.indexOf(u8, helped.body, "go north") != null);
    const empty = try service.post(a, opened.session, null, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"send_command\",\"arguments\":{}}}");
    try std.testing.expect(std.mem.indexOf(u8, empty.body, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty.body, "send_command needs a command") != null);
    // The full interface stays the default.
    const full = try service.post(a, null, null, init_body);
    const full_list = try service.post(a, full.session, null, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    try std.testing.expect(std.mem.indexOf(u8, full_list.body, "introduce_self") != null);
    // A request naming the other profile is refused; the same one is fine.
    const list = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}";
    const wrong = try service.post(a, opened.session, null, list);
    try std.testing.expectEqual(200, wrong.status);
    const refused = try service.post(a, opened.session, "full", list);
    try std.testing.expectEqual(400, refused.status);
    try std.testing.expectEqual(200, (try service.post(a, opened.session, "simple", list)).status);
}

test "simple tools are valid JSON, and replies keep the latest text" {
    const parsed = try json.parseFromSlice(json.Value, std.testing.allocator, simple_tools_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.value.array.items.len);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var long_text: std.ArrayList(u8) = .empty;
    for (0..400) |_| try long_text.appendSlice(arena.allocator(), "a line\n");
    const long = long_text.items;
    const cut = try tail(arena.allocator(), long, simple_text_limit);
    try std.testing.expect(cut.len <= simple_text_limit + 4);
    try std.testing.expect(std.mem.startsWith(u8, cut, "…"));
    try std.testing.expectEqualStrings("short", try tail(arena.allocator(), "short", simple_text_limit));
}

test "a partner initializes, then lists tools" {
    var service: Service = .init(std.testing.allocator, std.testing.io, 1);
    defer service.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const opened = try service.post(a, null, null, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try std.testing.expectEqual(@as(u16, 200), opened.status);
    try std.testing.expectEqual(@as(usize, 32), opened.session.?.len);

    const listed = try service.post(a, opened.session, null, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    try std.testing.expectEqual(@as(u16, 200), listed.status);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "read_game") != null);

    const note = try service.post(a, opened.session, null, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try std.testing.expectEqual(@as(u16, 202), note.status);
    try std.testing.expectEqual(@as(usize, 0), note.body.len);

    try std.testing.expectEqual(@as(u16, 400), (try service.post(a, null, null, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}")).status);
    try std.testing.expectEqual(@as(u16, 404), (try service.post(a, "nope", null, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}")).status);
    try std.testing.expectEqual(@as(u16, 400), (try service.post(a, null, null, "not json")).status);

    try std.testing.expect(service.end(opened.session.?));
    try std.testing.expect(!service.end(opened.session.?));
    try std.testing.expectEqual(@as(u16, 404), (try service.post(a, opened.session, null, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}")).status);
}
