//! A Model Context Protocol server that lets an AI partner, such as
//! Claude, play a game running with `--web [port]` alongside the person at
//! the keyboard and any other AI partners. Each partner runs its own server
//! and names itself with the `introduce` tool. It speaks JSON-RPC over
//! standard input and output, one message per line, and talks to the
//! game's web server on 127.0.0.1.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const json = std.json;
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");
const Group = @import("poly").Group;

const protocol_version = "2025-06-18";

const instructions =
    \\You are playing an interactive fiction game (a Z-machine story such as
    \\Zork) together with one or more people. They see the game in a
    \\terminal (the console), or on the game's web page with
    \\everyone's thoughts beside it; several people may be playing at once,
    \\some on other machines. Other AI partners may be playing too. Everyone's
    \\thoughts and messages come with their names, and you can agree or
    \\argue with them.
    \\
    \\Start with introduce, giving the name you go by (such as Claude), so the
    \\others know who you are; then read_game.
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
    \\Think out loud with share_thoughts in either mode: what you noticed,
    \\what you think the puzzle is, and what you would try. Keep it short.
    \\
    \\Play fair: know only what the game text tells you. The web server's
    \\object inspector shows hidden game state (objects, attributes,
    \\globals, the map). You may read it with read_inspector only when a
    \\person on the console's machine lets you (read_game says so), and
    \\every read is logged. When you use it, say so in the discussion, and
    \\don't spoil puzzles the others want to solve.
;

/// One line, since each message is one line.
const tools_json = oneLine(
    \\[{"name":"introduce","description":"Say who you are before playing: the name you go by, such as Claude. Your thoughts, messages and commands appear under it.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Your name, 1 to 32 characters, such as \"Claude\"."}},"required":["name"]}},
    \\{"name":"read_game","description":"Read the game text printed since you last looked (the whole recent game the first time), the status line, the mode, who leads and plays, and any messages from the others.","inputSchema":{"type":"object","properties":{}},"annotations":{"readOnlyHint":true}},
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
    gpa: Allocator,
    io: Io,
    port: u16,
    /// This partner's name, sent as X-Player, once it has introduced
    /// itself.
    name: ?[]const u8 = null,
    /// How much of the game text and discussion this partner has seen.
    offset: ?u64 = null,
    post_seq: u64 = 0,
    /// Whether this partner led when it last looked, to say when that
    /// changes.
    led: ?bool = null,
};

const Result = struct {
    text: []const u8,
    is_error: bool = false,
};

const Transcript = struct {
    offset: u64,
    waiting: bool,
    mode: []const u8,
    text: []const u8,
    status: []const []const u8,
};

const Post = struct {
    seq: u64,
    ai: bool = false,
    author: []const u8,
    kind: []const u8,
    text: []const u8,
    suggestions: []const []const u8,
};

const Member = struct {
    name: []const u8,
    ai: bool = false,
    local: bool = false,
    leader: bool = false,
    inspector: bool = false,
};

const Discussion = struct {
    last: u64,
    mode: []const u8,
    inspector_for_all: bool = false,
    leader: []const u8 = "console",
    players: []const Member = &.{},
    posts: []const Post,
};

const Reply = struct {
    id: u64,
    echo: u64 = 0,
    offset: u64 = 0,
    output: []const u8 = "",
    status: []const []const u8 = &.{},
    pending: bool = false,
};

/// Serves MCP requests from standard input until it closes.
pub fn run(gpa: Allocator, io: Io, port: u16) !void {
    var session: Session = .{ .gpa = gpa, .io = io, .port = port };
    defer if (session.name) |name| gpa.free(name);
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);
    var out_buf: [8192]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const w = &stdout.interface;

    while (try stdin.interface.takeDelimiter('\n')) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try handle(&session, arena.allocator(), line, w);
        // The client went away.
        w.flush() catch return;
    }
}

fn handle(s: *Session, arena: Allocator, line: []const u8, w: *Io.Writer) !void {
    const message = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch
        return writeError(w, .null, -32700, "parse error");
    if (message != .object) return writeError(w, .null, -32600, "invalid request");
    const obj = message.object;
    const method_value = obj.get("method") orelse return; // a response; we send no requests
    // Notifications, such as notifications/initialized, have no id and
    // get no response.
    const id = obj.get("id") orelse return;
    if (method_value != .string) return writeError(w, id, -32600, "invalid request");
    const method = method_value.string;
    const params: ?json.ObjectMap = if (obj.get("params")) |p| (if (p == .object) p.object else null) else null;

    if (std.mem.eql(u8, method, "initialize")) {
        const version = if (params) |p| (if (p.get("protocolVersion")) |v| (if (v == .string) v.string else null) else null) else null;
        var out: Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"protocolVersion\":");
        try writeString(&out.writer, version orelse protocol_version);
        try out.writer.writeAll(",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"zmachine\",\"version\":\"" ++
            build_options.version ++ "\"},\"instructions\":");
        try writeString(&out.writer, instructions);
        try out.writer.writeAll("}");
        return writeResult(w, id, out.written());
    }
    if (std.mem.eql(u8, method, "ping")) return writeResult(w, id, "{}");
    if (std.mem.eql(u8, method, "tools/list")) return writeResult(w, id, "{\"tools\":" ++ tools_json ++ "}");
    if (std.mem.eql(u8, method, "tools/call")) {
        const p = params orelse return writeError(w, id, -32602, "missing params");
        const name = p.get("name") orelse return writeError(w, id, -32602, "missing tool name");
        if (name != .string) return writeError(w, id, -32602, "missing tool name");
        const args: ?json.ObjectMap = if (p.get("arguments")) |a| (if (a == .object) a.object else null) else null;
        const result = call(s, arena, name.string, args) catch |err| switch (err) {
            error.UnknownTool => return writeError(w, id, -32602, "unknown tool"),
            error.ConnectionRefused => Result{
                .text = try std.fmt.allocPrint(arena, "Cannot reach the game on port {d}. Is zmachine running with --web {d}?", .{ s.port, s.port }),
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
    if (std.mem.eql(u8, name, "introduce")) {
        const player = stringArg(args, "name") orelse
            return .{ .text = "introduce needs your name.", .is_error = true };
        return introduce(s, arena, std.mem.trim(u8, player, " "));
    }
    // Every request names the partner, so nothing is sent until then.
    if (s.name == null) return .{
        .text = "Introduce yourself first: call introduce with the name you go by, such as Claude.",
        .is_error = true,
    };
    if (std.mem.eql(u8, name, "read_game")) return readGame(s, arena);
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

fn introduce(s: *Session, arena: Allocator, name: []const u8) !Result {
    if (!Group.validName(name)) return .{
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
    const reply = try json.parseFromSliceLeaky(Reply, arena, response.body, .{ .ignore_unknown_fields = true });

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    // Show anything the others did since this partner last looked.
    if (s.offset) |seen| if (reply.echo > seen) {
        const t = try transcript(s, arena, seen);
        const missed = t.text[0..@min(t.text.len, reply.echo - seen)];
        if (std.mem.trim(u8, missed, " \n>").len > 0) {
            try w.print("--- Before your command ---\n{s}\n\n", .{missed});
        }
    };
    try w.print(">{s}\n{s}\n", .{ command, reply.output });
    if (reply.status.len == 2 and reply.status[0].len > 0) {
        try w.print("\n[{s} | {s}]\n", .{ reply.status[0], reply.status[1] });
    }
    s.offset = reply.offset;
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

const Snapshot = struct {
    location: u16 = 0,
    objects: []const Object = &.{},
    changed: []const u16 = &.{},
    globals: []const u16 = &.{},
    rooms: []const Room = &.{},
    edges: []const Edge = &.{},

    const Object = struct {
        id: u16,
        name: []const u8,
        parent: u16 = 0,
        sibling: u16 = 0,
        child: u16 = 0,
        attrs: []const u16 = &.{},
        props: []const Property = &.{},
    };
    const Property = struct { n: u16, d: []const u8 };
    const Room = struct { id: u16, name: []const u8 };
    const Edge = struct { from: u16, to: u16, dir: []const u8 };

    fn get(snap: Snapshot, id: u16) ?Object {
        if (id == 0 or id > snap.objects.len) return null;
        return snap.objects[id - 1];
    }

    fn label(snap: Snapshot, w: *Io.Writer, id: u16) !void {
        const o = snap.get(id) orelse return w.print("#{d}", .{id});
        try w.print("#{d} {s}", .{ id, if (o.name.len > 0) o.name else "(unnamed)" });
    }
};

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
    const snap = try json.parseFromSliceLeaky(Snapshot, arena, response.body, .{ .ignore_unknown_fields = true });
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
        try snap.label(w, snap.location);
        try w.writeAll("\nIn it:\n");
        var lines: usize = 0;
        if (snap.get(snap.location)) |room| try writeTree(w, snap, room.child, 1, &lines);
        if (snap.changed.len > 0) {
            try w.writeAll("Changed this turn:");
            for (snap.changed, 0..) |id, i| {
                try w.writeAll(if (i > 0) ", " else " ");
                try snap.label(w, id);
            }
            try w.writeAll("\n");
        }
        try w.print("Map ({d} rooms visited):\n", .{snap.rooms.len});
        for (snap.edges) |e| {
            try w.writeAll("  ");
            try snap.label(w, e.from);
            try w.print(" --{s}--> ", .{e.dir});
            try snap.label(w, e.to);
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
        try snap.label(w, id);
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
    try snap.label(w, o.id);
    try w.writeAll("\nIn: ");
    try snap.label(w, o.parent);
    try w.writeAll("\nHolds:");
    var id = o.child;
    var guard: usize = 0;
    while (snap.get(id)) |c| : (id = c.sibling) {
        guard += 1;
        if (guard > snap.objects.len) break;
        try w.writeAll(" ");
        try snap.label(w, id);
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
    return json.parseFromSliceLeaky(Transcript, arena, response.body, .{ .ignore_unknown_fields = true });
}

/// Reads the discussion after `since`; with `wait`, holds on until there
/// is something new or the server's long-poll times out.
fn discussion(s: *Session, arena: Allocator, since: u64, wait: bool) !Discussion {
    const path = try std.fmt.allocPrint(arena, "/discussion?since={d}{s}", .{ since, if (wait) "&wait=1" else "" });
    const response = try request(s, arena, "GET", path, "");
    if (response.status != 200) return error.BadResponse;
    return json.parseFromSliceLeaky(Discussion, arena, response.body, .{ .ignore_unknown_fields = true });
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
    try std.testing.expectEqual(@as(usize, 10), parsed.value.array.items.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, tools_json, '\n') == null);
}
