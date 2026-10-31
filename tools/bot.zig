//! Plays Zork (or any story) as a tool-calling model through zmachine's
//! MCP server, for MODEL_EVALUATION.md: it opens a session on the simple
//! profile, offers the server's tools to an Ollama model, runs the calls
//! the model makes, and logs them.
//!
//! usage: bot <model> <tag> <turns> [--new] [--text] [--noask] [--reset]
//!            [--ollama <url>] [--game <url>] [--dir <dir>]
//!
//! State is kept in `<dir>/<tag>.json` (default dir `runs-local`), so a
//! later run with the same tag goes on with the same conversation and
//! MCP session; `--new` starts a fresh one. The log, `<dir>/<tag>.log.jsonl`,
//! is one JSON object per line (`init`, then `call`, `prose`, or `http`),
//! the format `metrics` and `save` read.
//!
//!   --text    for a model Ollama gives no tools: the tools go in the prompt
//!             and the model replies with {"tool": ..., "arguments": ...}
//!   --noask   keep going when the model asks the others a question
//!             (otherwise it stops, so a person can answer as the coach)
//!   --reset   restart the story and clear the discussion first

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// The most recent messages sent with each request.
const window = 16;
/// Replies with no tool call in a row before the run stops.
const max_idle = 4;

const ToolCall = struct {
    function: struct {
        name: []const u8 = "",
        arguments: Value = .null,
    } = .{},
};

const Msg = struct {
    role: []const u8,
    content: []const u8 = "",
    tool_name: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
};

const State = struct {
    sid: []const u8,
    instr: []const u8,
    tools: Value,
    msgs: []const Msg,
    n: usize = 0,
};

const Options = struct {
    model: []const u8,
    tag: []const u8,
    turns: usize,
    new: bool = false,
    text: bool = false,
    noask: bool = false,
    reset: bool = false,
    ollama: []const u8 = "http://monolith:11434",
    game: []const u8 = "http://127.0.0.1:9675",
    dir: []const u8 = "runs-local",
};

fn parseArgs(args: []const []const u8) ?Options {
    if (args.len < 4) return null;
    var o: Options = .{
        .model = args[1],
        .tag = args[2],
        .turns = std.fmt.parseInt(usize, args[3], 10) catch return null,
    };
    var i: usize = 4;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--new")) {
            o.new = true;
        } else if (std.mem.eql(u8, arg, "--text")) {
            o.text = true;
        } else if (std.mem.eql(u8, arg, "--noask")) {
            o.noask = true;
        } else if (std.mem.eql(u8, arg, "--reset")) {
            o.reset = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--ollama")) {
            i += 1;
            o.ollama = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--game")) {
            i += 1;
            o.game = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, arg, "--dir")) {
            i += 1;
            o.dir = args[i];
        } else return null;
    }
    return o;
}

const Reply = struct { status: u16, body: []const u8, session: ?[]const u8 = null };

fn post(arena: Allocator, client: *std.http.Client, url: []const u8, headers: []const std.http.Header, body: []const u8) !Reply {
    var req = try client.request(.POST, try std.Uri.parse(url), .{ .redirect_behavior = .unhandled, .extra_headers = headers });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});
    var session: ?[]const u8 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "mcp-session-id")) session = try arena.dupe(u8, h.value);
    }
    const status: u16 = @intCast(@backingInt(response.head.status));
    var out: Io.Writer.Allocating = .init(arena);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&out.writer) catch return response.bodyErr() orelse error.ReadFailed;
    return .{ .status = status, .body = out.written(), .session = session };
}

const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "accept", .value = "application/json, text/event-stream" },
};

/// The model name as a client name: lowercase letters and digits, dashes between.
fn clientName(arena: Allocator, model: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (model) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            try out.append(arena, lower);
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != '-') {
            try out.append(arena, '-');
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    return out.items;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const o = parseArgs(args) orelse {
        try out.writeAll("usage: bot <model> <tag> <turns> [--new] [--text] [--noask] [--reset] [--ollama <url>] [--game <url>] [--dir <dir>]\n");
        return 2;
    };
    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    if (o.reset) {
        for ([_][]const u8{ "restart", "y" }) |line| _ = try post(arena, &client, try join(arena, o.game, "/command"), &.{}, line);
        _ = try post(arena, &client, try join(arena, o.game, "/clear-discussion"), &.{}, "");
    }

    const state_path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ o.dir, o.tag });
    const log_path = try std.fmt.allocPrint(arena, "{s}/{s}.log.jsonl", .{ o.dir, o.tag });
    var log: Io.Writer.Allocating = .init(arena);
    if (Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(256 * 1024 * 1024))) |old| try log.writer.writeAll(old) else |_| {}

    var state: State = loaded: {
        if (!o.new) if (Io.Dir.cwd().readFileAlloc(io, state_path, arena, .limited(64 * 1024 * 1024))) |text| {
            break :loaded try std.json.parseFromSliceLeaky(State, arena, text, .{ .ignore_unknown_fields = true });
        } else |_| {};
        break :loaded try openSession(arena, &client, o, &log.writer);
    };
    var msgs: std.ArrayList(Msg) = .empty;
    try msgs.appendSlice(arena, state.msgs);
    if (msgs.items.len == 0) try msgs.append(arena, .{ .role = "user", .content = "Play the game. Call your tools." });

    var idle: usize = 0;
    var turn: usize = 0;
    while (turn < o.turns) : (turn += 1) {
        const started: Io.Timestamp = .now(io, .awake);
        const reply = chat(arena, &client, o, state, msgs.items) catch |err| {
            try log.writer.print("{{\"ev\":\"http\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
            try out.print("ERR {s}\n", .{@errorName(err)});
            if (err == error.BadStatus and !o.text) {
                try out.writeAll("the model may reject tools; rerun with --text\n");
                break;
            }
            continue;
        };
        const secs = @as(f64, @floatFromInt(started.durationTo(.now(io, .awake)).toMilliseconds())) / 1000.0;
        const content = std.mem.trim(u8, reply.content, " \t\r\n");
        var calls: std.ArrayList(ToolCall) = .empty;
        if (reply.tool_calls) |native| try calls.appendSlice(arena, native);
        if (o.text and calls.items.len == 0) if (textCall(arena, content)) |c| try calls.append(arena, c);
        try msgs.append(arena, .{ .role = "assistant", .content = content, .tool_calls = if (reply.tool_calls) |n| n else null });

        if (calls.items.len == 0) {
            try std.json.Stringify.value(.{ .ev = "prose", .content = content, .secs = secs }, .{}, &log.writer);
            try log.writer.writeByte('\n');
            try out.print("[{d}] ({d:.1}s) PROSE: {s}\n", .{ state.n, secs, firstLine(content, 200) });
            try msgs.append(arena, .{ .role = "user", .content = "Call one of your tools." });
            state.n += 1;
            idle += 1;
            if (idle >= max_idle) {
                try out.writeAll("no tool calls 4 times in a row; stopping\n");
                break;
            }
            continue;
        }
        idle = 0;
        var asked = false;
        for (calls.items) |c| {
            const result = try callTool(arena, &client, o, state.sid, c);
            try std.json.Stringify.value(.{ .ev = "call", .name = c.function.name, .args = c.function.arguments, .res = result, .secs = secs, .thought = content[0..@min(content.len, 300)] }, .{}, &log.writer);
            try log.writer.writeByte('\n');
            try out.print("[{d}] {s} {s} -> {s}{s}\n", .{ state.n, c.function.name, argText(c.function.arguments), firstLine(result, 140), if (secs > 12) " (slow)" else "" });
            if (o.text) {
                try msgs.append(arena, .{ .role = "user", .content = try std.fmt.allocPrint(arena, "Result:\n{s}", .{result}) });
            } else {
                try msgs.append(arena, .{ .role = "tool", .tool_name = c.function.name, .content = result });
            }
            if (std.mem.eql(u8, c.function.name, "tell_players") and std.mem.indexOfScalar(u8, argText(c.function.arguments), '?') != null) asked = true;
        }
        state.n += 1;
        try save(io, arena, state_path, state, msgs.items);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = log.written() });
        if (asked and !o.noask) {
            try out.writeAll("** asked a question; stopping for a hint\n");
            break;
        }
    }
    try save(io, arena, state_path, state, msgs.items);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = log.written() });
    return 0;
}

fn join(arena: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ base, path });
}

fn save(io: Io, arena: Allocator, path: []const u8, state: State, msgs: []const Msg) !void {
    var w: Io.Writer.Allocating = .init(arena);
    var s = state;
    s.msgs = msgs;
    try std.json.Stringify.value(s, .{ .emit_null_optional_fields = false }, &w.writer);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.written() });
}

/// Opens an MCP session on the simple profile and reads its tools.
fn openSession(arena: Allocator, client: *std.http.Client, o: Options, log: *Io.Writer) !State {
    const name = try clientName(arena, o.model);
    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "initialize",
        .params = .{ .protocolVersion = "2025-03-26", .capabilities = .{}, .clientInfo = .{ .name = name, .version = "1" } },
    }, .{}, &body.writer);
    const opened = try post(arena, client, try join(arena, o.game, "/mcp/simple"), &json_headers, body.written());
    const sid = opened.session orelse return error.NoSession;
    const Init = struct { result: struct { instructions: []const u8 = "" } };
    const parsed = try std.json.parseFromSliceLeaky(Init, arena, opened.body, .{ .ignore_unknown_fields = true });

    const session_header = [_]std.http.Header{ json_headers[0], json_headers[1], .{ .name = "Mcp-Session-Id", .value = sid } };
    _ = try post(arena, client, try join(arena, o.game, "/mcp"), &session_header, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    const listed = try post(arena, client, try join(arena, o.game, "/mcp"), &session_header, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    const List = struct { result: struct { tools: Value } };
    const tools = (try std.json.parseFromSliceLeaky(List, arena, listed.body, .{ .ignore_unknown_fields = true })).result.tools;

    try std.json.Stringify.value(.{ .ev = "init", .model = o.model, .tag = o.tag, .instr = parsed.result.instructions, .tools = tools }, .{}, log);
    try log.writeByte('\n');
    return .{ .sid = sid, .instr = parsed.result.instructions, .tools = tools, .msgs = &.{} };
}

const Reply2 = struct {
    content: []const u8 = "",
    tool_calls: ?[]const ToolCall = null,
};

/// One turn of the model's reply, from Ollama.
fn chat(arena: Allocator, client: *std.http.Client, o: Options, state: State, history: []const Msg) !Reply2 {
    var system: Io.Writer.Allocating = .init(arena);
    try system.writer.writeAll(state.instr);
    if (o.text) {
        try system.writer.writeAll("\n\nTools (reply with exactly one JSON object per turn, {\"tool\": name, \"arguments\": {...}}, nothing else):\n");
        try std.json.Stringify.value(state.tools, .{ .whitespace = .indent_1 }, &system.writer);
    }
    var messages: std.ArrayList(Msg) = .empty;
    try messages.append(arena, .{ .role = "system", .content = system.written() });
    try messages.appendSlice(arena, history[history.len -| window..]);

    var body: Io.Writer.Allocating = .init(arena);
    const w = &body.writer;
    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(o.model, .{}, w);
    try w.writeAll(",\"stream\":false,\"options\":{\"num_ctx\":8192},\"messages\":");
    try std.json.Stringify.value(messages.items, .{ .emit_null_optional_fields = false }, w);
    if (!o.text) {
        try w.writeAll(",\"tools\":[");
        for (state.tools.array.items, 0..) |t, i| {
            if (i > 0) try w.writeByte(',');
            const tool = t.object;
            try std.json.Stringify.value(.{ .type = "function", .function = .{
                .name = tool.get("name") orelse .null,
                .description = tool.get("description") orelse .null,
                .parameters = tool.get("inputSchema") orelse .null,
            } }, .{}, w);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');

    const answer = try post(arena, client, try join(arena, o.ollama, "/api/chat"), &.{.{ .name = "content-type", .value = "application/json" }}, body.written());
    if (answer.status >= 300) return error.BadStatus;
    const Chat = struct { message: Reply2 = .{} };
    return (try std.json.parseFromSliceLeaky(Chat, arena, answer.body, .{ .ignore_unknown_fields = true })).message;
}

/// A tool call in a plain-text reply: the first JSON object with a `tool`.
fn textCall(arena: Allocator, content: []const u8) ?ToolCall {
    const start = std.mem.indexOfScalar(u8, content, '{') orelse return null;
    const end = std.mem.lastIndexOfScalar(u8, content, '}') orelse return null;
    if (end < start) return null;
    const Parsed = struct { tool: []const u8 = "", arguments: Value = .null };
    const p = std.json.parseFromSliceLeaky(Parsed, arena, content[start .. end + 1], .{ .ignore_unknown_fields = true }) catch return null;
    if (p.tool.len == 0) return null;
    return .{ .function = .{ .name = p.tool, .arguments = p.arguments } };
}

/// Runs a tool call on the MCP server and returns its text.
fn callTool(arena: Allocator, client: *std.http.Client, o: Options, sid: []const u8, c: ToolCall) ![]const u8 {
    var arguments = c.function.arguments;
    if (arguments == .string) {
        arguments = std.json.parseFromSliceLeaky(Value, arena, arguments.string, .{}) catch return "ERROR bad arguments";
    }
    if (arguments != .object and arguments != .null) return "ERROR bad arguments";
    var body: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .jsonrpc = "2.0",
        .id = 9,
        .method = "tools/call",
        .params = .{ .name = c.function.name, .arguments = if (arguments == .null) Value{ .object = .empty } else arguments },
    }, .{}, &body.writer);
    const headers = [_]std.http.Header{ json_headers[0], json_headers[1], .{ .name = "Mcp-Session-Id", .value = sid } };
    const answer = try post(arena, client, try join(arena, o.game, "/mcp"), &headers, body.written());
    const Call = struct { result: ?struct { content: []const struct { text: []const u8 = "" } } = null, @"error": ?Value = null };
    const parsed = std.json.parseFromSliceLeaky(Call, arena, answer.body, .{ .ignore_unknown_fields = true }) catch return "ERROR unreadable reply";
    if (parsed.@"error") |e| {
        var w: Io.Writer.Allocating = .init(arena);
        try w.writer.writeAll("ERROR ");
        try std.json.Stringify.value(e, .{}, &w.writer);
        return w.written();
    }
    var text: Io.Writer.Allocating = .init(arena);
    if (parsed.result) |r| for (r.content) |part| try text.writer.writeAll(part.text);
    return text.written();
}

/// The `command` or `text` argument of a call, or empty.
fn argText(arguments: Value) []const u8 {
    if (arguments != .object) return "";
    for ([_][]const u8{ "command", "text" }) |key| {
        if (arguments.object.get(key)) |v| if (v == .string) return v.string;
    }
    return "";
}

fn firstLine(text: []const u8, limit: usize) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..@min(end, limit)];
}

test parseArgs {
    const o = parseArgs(&.{ "bot", "qwen3:14b", "qwen-r1", "40", "--new", "--noask", "--dir", "d" }).?;
    try std.testing.expectEqual(40, o.turns);
    try std.testing.expect(o.new and o.noask and !o.text and !o.reset);
    try std.testing.expectEqualStrings("d", o.dir);
    try std.testing.expect(parseArgs(&.{ "bot", "m", "t" }) == null);
    try std.testing.expect(parseArgs(&.{ "bot", "m", "t", "x" }) == null);
    try std.testing.expect(parseArgs(&.{ "bot", "m", "t", "5", "--bogus" }) == null);
}

test clientName {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("qwen3-14b", try clientName(arena_state.allocator(), "Qwen3:14b"));
    try std.testing.expectEqualStrings("gpt-oss-20b", try clientName(arena_state.allocator(), "gpt-oss:20b"));
}

test textCall {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const c = textCall(arena_state.allocator(), "Sure {\"tool\": \"send_command\", \"arguments\": {\"command\": \"look\"}}").?;
    try std.testing.expectEqualStrings("send_command", c.function.name);
    try std.testing.expectEqualStrings("look", argText(c.function.arguments));
    try std.testing.expect(textCall(arena_state.allocator(), "no json here") == null);
}
