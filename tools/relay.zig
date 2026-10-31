//! Relays a model that cannot call tools: it asks the model for one
//! JSON object per turn, plays its command through `POST /command?format=text`,
//! posts its thought to the discussion, and gives the model the game text.
//!
//! usage: relay <model> [--ollama <url>] [--game <url>] [--player <name>]
//!              [--turns <n>] [--log <file>]
//!
//! The log is one JSON object per line (`init`, then a `call` per command),
//! the format `metrics` and `save` read. Use turns mode, so the model may
//! send commands.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const system_prompt =
    "You are playing a text adventure game such as Zork. Each turn, reply with exactly one JSON object " ++
    "and nothing else: {\"command\": \"open mailbox\", \"thought\": \"why you chose it\"}. The command is " ++
    "one short game command, a verb and an object. I will answer with what the game printed. If a command " ++
    "is not understood, use simpler words. If you forget what happened, reply {\"command\": \"look\"}.";

/// The most recent messages sent with each request.
const window = 16;

const Message = struct { role: []const u8, content: []const u8 };

const Options = struct {
    model: []const u8,
    ollama: []const u8 = "http://monolith:11434",
    game: []const u8 = "http://127.0.0.1:9675",
    player: []const u8 = "relay",
    turns: usize = 50,
    log: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) ?Options {
    if (args.len < 2) return null;
    var o: Options = .{ .model = args[1] };
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        const value = args[i + 1];
        if (std.mem.eql(u8, args[i], "--ollama")) {
            o.ollama = value;
        } else if (std.mem.eql(u8, args[i], "--game")) {
            o.game = value;
        } else if (std.mem.eql(u8, args[i], "--player")) {
            o.player = value;
        } else if (std.mem.eql(u8, args[i], "--turns")) {
            o.turns = std.fmt.parseInt(usize, value, 10) catch return null;
        } else if (std.mem.eql(u8, args[i], "--log")) {
            o.log = value;
        } else return null;
    }
    return if (i == args.len) o else null;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var err_buf: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const o = parseArgs(args) orelse {
        try stderr.writeAll("usage: relay <model> [--ollama <url>] [--game <url>] [--player <name>] [--turns <n>] [--log <file>]\n");
        return 2;
    };

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    var history: std.ArrayList(Message) = .empty;
    try history.append(arena, .{ .role = "user", .content = "Begin." });
    var log: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .ev = "init", .model = o.model, .tag = o.player }, .{}, &log.writer);
    try log.writer.writeAll("\n");

    var turn: usize = 0;
    while (turn < o.turns) : (turn += 1) {
        const reply = chat(arena, &client, o, history.items) catch |err| {
            try stderr.print("relay: the model did not answer: {s}\n", .{@errorName(err)});
            break;
        };
        try history.append(arena, .{ .role = "assistant", .content = reply });
        const move = parseMove(arena, reply) orelse {
            try history.append(arena, .{ .role = "user", .content = "Reply with one JSON object: {\"command\": \"...\", \"thought\": \"...\"}" });
            try log.writer.writeAll("{\"ev\":\"prose\"}\n");
            continue;
        };
        if (move.thought.len > 0) postThought(arena, &client, o, move) catch {};
        const text = play(arena, &client, o, move.command) catch |err| {
            try stderr.print("relay: the game did not answer: {s}\n", .{@errorName(err)});
            break;
        };
        try std.json.Stringify.value(.{ .ev = "call", .name = "send_command", .args = .{ .command = move.command }, .res = text }, .{}, &log.writer);
        try log.writer.writeAll("\n");
        try stderr.print("[{d}] {s}\n", .{ turn, move.command });
        try history.append(arena, .{ .role = "user", .content = text });
    }
    if (o.log) |path| try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = log.written() });
    return 0;
}

const Move = struct { command: []const u8 = "", thought: []const u8 = "" };

/// The first JSON object in the model's reply, as a move.
fn parseMove(arena: Allocator, reply: []const u8) ?Move {
    const start = std.mem.indexOfScalar(u8, reply, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, reply, '}') orelse return null;
    if (end < start) return null;
    const parsed = std.json.parseFromSliceLeaky(Move, arena, reply[start .. end + 1], .{ .ignore_unknown_fields = true }) catch return null;
    const command = std.mem.trim(u8, parsed.command, " \t\r\n");
    if (command.len == 0) return null;
    return .{ .command = command, .thought = std.mem.trim(u8, parsed.thought, " \t\r\n") };
}

fn post(arena: Allocator, client: *std.http.Client, url: []const u8, headers: []const std.http.Header, body: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers,
        .response_writer = &out.writer,
    });
    if (@backingInt(result.status) >= 300) return error.BadStatus;
    return out.written();
}

/// One turn of the model's reply, from Ollama.
fn chat(arena: Allocator, client: *std.http.Client, o: Options, history: []const Message) ![]const u8 {
    var messages: std.ArrayList(Message) = .empty;
    try messages.append(arena, .{ .role = "system", .content = system_prompt });
    try messages.appendSlice(arena, history[history.len -| window..]);
    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .model = o.model, .stream = false, .messages = messages.items, .options = .{ .num_ctx = 8192 } }, .{}, &body.writer);
    const url = try std.fmt.allocPrint(arena, "{s}/api/chat", .{o.ollama});
    const answer = try post(arena, client, url, &.{.{ .name = "content-type", .value = "application/json" }}, body.written());
    const Chat = struct { message: struct { content: []const u8 = "" } = .{} };
    const parsed = try std.json.parseFromSliceLeaky(Chat, arena, answer, .{ .ignore_unknown_fields = true });
    return parsed.message.content;
}

/// Sends the command and returns the game text.
fn play(arena: Allocator, client: *std.http.Client, o: Options, command: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(arena, "{s}/command?format=text", .{o.game});
    return post(arena, client, url, &.{.{ .name = "X-Player", .value = o.player }}, command);
}

/// Posts the thought to the discussion, with the command as a suggestion.
fn postThought(arena: Allocator, client: *std.http.Client, o: Options, move: Move) !void {
    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .kind = "thought", .text = move.thought, .suggestions = [_][]const u8{move.command} }, .{}, &body.writer);
    const url = try std.fmt.allocPrint(arena, "{s}/say", .{o.game});
    _ = try post(arena, client, url, &.{.{ .name = "X-Player", .value = o.player }}, body.written());
}

test parseMove {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const move = parseMove(arena, "Sure!\n{\"command\": \"open mailbox\", \"thought\": \"it is here\"}").?;
    try std.testing.expectEqualStrings("open mailbox", move.command);
    try std.testing.expectEqualStrings("it is here", move.thought);
    try std.testing.expect(parseMove(arena, "I would go north.") == null);
    try std.testing.expect(parseMove(arena, "{\"command\": \"\"}") == null);
}

test parseArgs {
    const o = parseArgs(&.{ "relay", "gemma3:12b", "--turns", "5", "--player", "gemma" }).?;
    try std.testing.expectEqual(5, o.turns);
    try std.testing.expectEqualStrings("gemma", o.player);
    try std.testing.expect(parseArgs(&.{"relay"}) == null);
    try std.testing.expect(parseArgs(&.{ "relay", "m", "--turns" }) == null);
}
