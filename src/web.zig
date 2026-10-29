//! A small embedded HTTP server for playing together, and for the live
//! object inspector and map.
//!
//! Routes:
//!   GET /                 the play page: the game beside the discussion
//!                         (or the password page for a remote player
//!                         without a session). `?password=` gives the
//!                         password and redirects to `/`, so an invite link
//!                         joins in one click
//!   GET /inspector        the inspector page (local only)
//!   GET /state?since=N    the latest snapshot, held open until it is newer
//!                         than generation N (long polling; local only)
//!   POST /erase-map       erase the map at the next snapshot (local only)
//!   POST /grant-inspector let the AI partner the body names read /state
//!   POST /revoke-inspector  stop it (both for people on this machine only)
//!   GET /me               who the server takes you for, and whether you lead
//!   POST /login           give the password (remote players, with `--listen`)
//!   POST /join            choose a name (people on the play page)
//!   POST /command         send the body as a line of input and return the
//!                         game's reply
//!   GET /transcript?since=N[&wait=1]
//!                         the game text since offset N, as a player sees it;
//!                         with `wait`, held open until there is some
//!   POST /say             add a thought or message, with suggested
//!                         commands, to the discussion (JSON body)
//!   GET /discussion?since=N[&wait=1]
//!                         the mode, the leader, the players and the
//!                         discussion after post N; with `wait`, held open
//!                         until there is something new
//!   POST /mode            the leader sets the mode: `debate` (the default)
//!                         or `turns`
//!   POST /lead            pass the leadership to the named player, or to
//!                         the local side with `console`
//!   POST /kick            the leader kicks the named remote player
//!   GET /invite           an invite link carrying the password, for local
//!                         clients and a human leader (with `--listen`)
//!   POST /password        change the password to the body, or generate one
//!                         if it is empty
//!   GET /random-password  three random words to suggest as a new password,
//!                         changing nothing
//!   GET /log              the audit log page, open to every player
//!   GET /events?since=N   audit log events after N (long polling)
//!
//! A request comes from an AI partner when it has `X-Player: <name>` (AI
//! partners connect from this machine). Otherwise it comes from a person:
//! on this machine, named by `X-Person`, or on another machine, named by
//! the session its cookie names.
//!
//! The inspector shows what a player cannot see, so opening it and reading
//! its snapshots are logged as suspicious. Requests from other web sites
//! (by their Origin or Host headers) are refused and logged.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const Inspector = @import("Inspector.zig");
const Password = @import("Password.zig");
const Remote = @import("Remote.zig");

const index_html = @embedFile("inspector.html");
const log_html = @embedFile("log.html");
const play_html = @embedFile("play.html");
const login_html = @embedFile("login.html");

/// How long a long-poll request waits for a new snapshot.
const poll_timeout_ms = 20_000;
const poll_interval_ms = 100;

const session_cookie = "zmachine_session";

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    inspector: *Inspector,
    remote: *Remote,
    port: u16,
    /// The address given with `--listen`, or null to listen on 127.0.0.1
    /// only. An unspecified address (such as 0.0.0.0) accepts any Host.
    listen_address: ?[]const u8,
    listen_any: bool,
    listener: net.Server,

    /// Binds to `port` on the loopback interface, or on `listen_address`.
    pub fn listen(gpa: Allocator, io: Io, inspector: *Inspector, remote: *Remote, port: u16, listen_address: ?[]const u8) !Server {
        const address: net.IpAddress = if (listen_address) |text|
            try net.IpAddress.parse(text, port)
        else
            .{ .ip4 = .loopback(port) };
        return .{
            .gpa = gpa,
            .io = io,
            .inspector = inspector,
            .remote = remote,
            .port = port,
            .listen_address = listen_address,
            .listen_any = if (listen_address != null) isUnspecified(address) else false,
            .listener = try address.listen(io, .{ .reuse_address = true }),
        };
    }

    /// Accepts connections forever, one thread per connection.
    pub fn serve(s: *Server) void {
        while (true) {
            const stream = s.listener.accept(s.io) catch |err| {
                std.log.warn("web: accept failed: {s}", .{@errorName(err)});
                continue;
            };
            const thread = std.Thread.spawn(.{}, handle, .{ s, stream }) catch {
                stream.close(s.io);
                continue;
            };
            thread.detach();
        }
    }

    fn handle(s: *Server, stream: net.Stream) void {
        defer stream.close(s.io);
        respond(s, stream) catch {};
    }

    fn respond(s: *Server, stream: net.Stream) !void {
        var read_buf: [4096]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(s.io, &read_buf);
        var writer = stream.writer(s.io, &write_buf);
        const r = &reader.interface;
        const w = &writer.interface;

        const request_line = (try r.takeDelimiter('\n')) orelse return;
        var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, request_line, "\r"), ' ');
        const method = try s.gpa.dupe(u8, parts.next() orelse return);
        defer s.gpa.free(method);
        const target = try s.gpa.dupe(u8, parts.next() orelse return);
        defer s.gpa.free(target);

        var headers: Headers = .{};
        defer headers.deinit(s.gpa);
        while (try r.takeDelimiter('\n')) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) break;
            try headers.add(s.gpa, line);
        }
        const peer = stream.socket.address;
        const local = isLoopback(peer);
        const agent = headers.user_agent orelse "unknown client";

        const query_start = std.mem.indexOfScalar(u8, target, '?');
        const path = target[0 .. query_start orelse target.len];
        const query = if (query_start) |q| target[q + 1 ..] else "";

        // Refuse requests from web pages on other sites, including ones
        // that reach the port by rebinding their DNS name.
        if (!s.allowedHost(headers.host, local) or !allowedOrigin(headers.origin, headers.host)) {
            var detail_buf: [256]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "{s} {s} from {s}", .{
                method, path, headers.origin orelse headers.host orelse "?",
            }) catch path;
            s.remote.log(.refused, agent, detail, true);
            return sendResponse(w, "403 Forbidden", "text/plain", "forbidden\n");
        }

        // Work out who is asking.
        var name_buf: [64]u8 = undefined;
        var token: ?Remote.Token = null;
        var player: Remote.Player = .console;
        if (headers.ai()) |name| {
            if (!Remote.validName(name)) {
                return sendResponse(w, "400 Bad Request", "text/plain", "X-Player names an AI partner in 1 to 32 printable characters\n");
            }
            if (!local) return s.refuse(w, agent, method, path, "AI partners connect from this machine\n");
            player = .{ .name = name, .ai = true, .local = false };
        } else if (local) {
            if (headers.person_name) |name| {
                if (!Remote.validName(name)) {
                    return sendResponse(w, "400 Bad Request", "text/plain", "a name is 1 to 32 printable characters\n");
                }
                player = .{ .name = name, .local = true };
            }
        } else {
            // A remote person: the password page, or a session.
            if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/login")) {
                const body = (try readBody(r, w, &headers)) orelse return;
                return s.login(w, peer, agent, body);
            }
            token = headers.session();
            const state: Remote.SessionState = if (token) |t| s.remote.session(t, &name_buf) else .none;
            // An invite link: give its password, then drop it from the
            // address bar.
            if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/")) if (queryValue(query, "password")) |raw| {
                if (state == .valid) return redirectHome(w, "");
                var decoded: [Password.max_len * 3]u8 = undefined;
                return s.loginFromLink(w, peer, agent, percentDecode(&decoded, raw));
            };
            switch (state) {
                .none => {
                    if (std.mem.eql(u8, path, "/")) {
                        return sendResponse(w, "200 OK", "text/html; charset=utf-8", login_html);
                    }
                    return sendResponse(w, "401 Unauthorized", "text/plain", "give the password at / first\n");
                },
                .ended => |why| {
                    if (std.mem.eql(u8, path, "/")) {
                        return sendResponse(w, "200 OK", "text/html; charset=utf-8", login_html);
                    }
                    return sendResponse(w, "410 Gone", "text/plain", why);
                },
                .valid => |name| player = .{ .name = name, .local = false },
            }
        }
        var client_buf: [256]u8 = undefined;
        const client = if (player.name) |name|
            std.fmt.bufPrint(&client_buf, "{s} via {s}{s}", .{ name, agent, if (player.local or player.ai) "" else " (remote)" }) catch agent
        else
            agent;

        // The inspector shows what players can't see. The audit log is open
        // to everyone, so leaders and the others see the same record.
        const local_only = std.mem.eql(u8, path, "/inspector") or std.mem.eql(u8, path, "/state") or
            std.mem.eql(u8, path, "/erase-map");
        if (local_only and !local) return s.refuse(w, client, method, path, "this page is only for this machine\n");
        // AI partners read the inspector's snapshots, and only when let.
        if (local_only and player.ai) {
            if (!std.mem.eql(u8, path, "/state")) return s.refuse(w, client, method, path, "AI partners only read the inspector's snapshots\n");
            if (!s.remote.mayInspect(player)) return s.refuse(w, client, method, path, "nobody has let you read the inspector\n");
        }
        // This machine needs no password; drop one from an invite link.
        if (local and std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/") and queryValue(query, "password") != null) {
            return redirectHome(w, "");
        }

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/join")) {
            const body = (try readBody(r, w, &headers)) orelse return;
            return s.join(w, player, token, std.mem.trim(u8, body, " \t\r\n"));
        }
        if (player.name != null) {
            s.remote.touch(player) catch |err| switch (err) {
                error.NameTaken => return sendResponse(w, "409 Conflict", "text/plain", "that name is taken\n"),
                error.Kicked => return s.refuse(w, client, method, path, "you were removed from the game\n"),
                else => return err,
            };
        } else if (!local and std.mem.eql(u8, method, "POST")) {
            return sendResponse(w, "403 Forbidden", "text/plain", "choose a name with POST /join first\n");
        }

        if (std.mem.eql(u8, method, "POST")) {
            const body = (try readBody(r, w, &headers)) orelse return;
            const text = std.mem.trim(u8, body, " \t\r\n");
            if (std.mem.eql(u8, path, "/command")) return s.command(w, text, player, client);
            if (std.mem.eql(u8, path, "/say")) return s.say(w, body, player);
            if (std.mem.eql(u8, path, "/mode")) {
                const mode = std.meta.stringToEnum(Remote.Mode, text) orelse
                    return sendResponse(w, "400 Bad Request", "text/plain", "the mode is debate or turns\n");
                s.remote.setMode(player, mode) catch |err| return leaderError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/lead")) {
                s.remote.passLeadership(player, text) catch |err| return leaderError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/kick")) {
                s.remote.kick(player, text) catch |err| return leaderError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/grant-inspector") or std.mem.eql(u8, path, "/revoke-inspector")) {
                const grant = std.mem.eql(u8, path, "/grant-inspector");
                s.remote.setInspectorAccess(player, text, grant) catch |err| return switch (err) {
                    error.NotAllowed => sendResponse(w, "403 Forbidden", "text/plain", "only people on this machine may do that\n"),
                    error.UnknownPlayer => sendResponse(w, "404 Not Found", "text/plain", "no AI partner playing has that name\n"),
                    error.OutOfMemory => error.OutOfMemory,
                };
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/erase-map")) {
                s.inspector.eraseMap();
                s.remote.log(.inspector, client, "erased the inspector's map", false);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/password")) {
                s.remote.changePassword(player, if (text.len > 0) text else null) catch |err| return passwordError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
        }
        if (!std.mem.eql(u8, method, "GET")) {
            return sendResponse(w, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        }

        if (std.mem.eql(u8, path, "/inspector")) {
            s.remote.log(.inspector, client, "opened the object inspector", true);
            return sendResponse(w, "200 OK", "text/html; charset=utf-8", index_html);
        }
        if (std.mem.eql(u8, path, "/state")) {
            const since = parseSince(query);
            var waited: u32 = 0;
            while (true) {
                if (try s.inspector.latest(s.gpa, since)) |json| {
                    defer s.gpa.free(json);
                    var detail_buf: [64]u8 = undefined;
                    const detail = std.fmt.bufPrint(&detail_buf, "read the object tree and globals (since {d})", .{since}) catch "";
                    s.remote.log(.snapshot, client, detail, true);
                    return sendResponse(w, "200 OK", "application/json", json);
                }
                if (waited >= poll_timeout_ms) {
                    return sendResponse(w, "204 No Content", "application/json", "");
                }
                try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                waited += poll_interval_ms;
            }
        }
        if (std.mem.eql(u8, path, "/")) {
            return sendResponse(w, "200 OK", "text/html; charset=utf-8", play_html);
        }
        if (std.mem.eql(u8, path, "/me")) {
            var out: Io.Writer.Allocating = .init(s.gpa);
            defer out.deinit();
            try out.writer.writeAll("{\"name\":");
            if (player.name) |name| try std.json.Stringify.encodeJsonString(name, .{}, &out.writer) else try out.writer.writeAll("null");
            try out.writer.print(",\"ai\":{},\"local\":{},\"leader\":{},\"listening\":{}}}", .{
                player.ai, player.local, s.remote.leads(player), s.remote.listening(),
            });
            return sendResponse(w, "200 OK", "application/json", out.written());
        }
        if (std.mem.eql(u8, path, "/random-password")) {
            if (!s.remote.managesPassword(player)) return passwordError(w, if (s.remote.listening()) error.NotAllowed else error.NotListening);
            const password = Password.generate(s.io) catch |err| return passwordError(w, err);
            return sendResponse(w, "200 OK", "text/plain; charset=utf-8", password.slice());
        }
        if (std.mem.eql(u8, path, "/invite")) {
            var buf: [Password.max_len]u8 = undefined;
            const password = s.remote.readPassword(player, &buf, "fetched an invite link with") catch |err| return passwordError(w, err);
            var host_buf: [128]u8 = undefined;
            const host = s.inviteHost(headers.host, local, &host_buf) orelse
                return sendResponse(w, "503 Service Unavailable", "text/plain", "could not tell this machine's address\n");
            var out: Io.Writer.Allocating = .init(s.gpa);
            defer out.deinit();
            try out.writer.print("http://{s}/?password=", .{host});
            try percentEncode(&out.writer, password);
            return sendResponse(w, "200 OK", "text/plain; charset=utf-8", out.written());
        }
        if (std.mem.eql(u8, path, "/transcript")) {
            const since = parseSince(query);
            if (queryValue(query, "wait") != null) {
                var waited: u32 = 0;
                while (s.remote.textOffset() <= since and waited < poll_timeout_ms) {
                    try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                    waited += poll_interval_ms;
                }
            }
            var out: Io.Writer.Allocating = .init(s.gpa);
            defer out.deinit();
            try s.remote.writeText(&out.writer, since);
            return sendResponse(w, "200 OK", "application/json", out.written());
        }
        if (std.mem.eql(u8, path, "/discussion")) {
            const since = parseSince(query);
            var waited: u32 = 0;
            while (queryValue(query, "wait") != null and s.remote.lastPost() <= since and waited < poll_timeout_ms) {
                try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                waited += poll_interval_ms;
            }
            var out: Io.Writer.Allocating = .init(s.gpa);
            defer out.deinit();
            try s.remote.writePosts(&out.writer, since);
            return sendResponse(w, "200 OK", "application/json", out.written());
        }
        if (std.mem.eql(u8, path, "/log")) {
            return sendResponse(w, "200 OK", "text/html; charset=utf-8", log_html);
        }
        if (std.mem.eql(u8, path, "/events")) {
            const since = parseSince(query);
            var waited: u32 = 0;
            while (s.remote.lastEvent() <= since and waited < poll_timeout_ms) {
                try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                waited += poll_interval_ms;
            }
            var out: Io.Writer.Allocating = .init(s.gpa);
            defer out.deinit();
            try s.remote.writeEvents(&out.writer, since);
            return sendResponse(w, "200 OK", "application/json", out.written());
        }
        return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
    }

    /// Refuses a request, logging it as suspicious.
    fn refuse(s: *Server, w: *Io.Writer, client: []const u8, method: []const u8, path: []const u8, why: []const u8) !void {
        var detail_buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s} {s}: {s}", .{ method, path, std.mem.trimEnd(u8, why, "\n") }) catch path;
        s.remote.log(.refused, client, detail, true);
        return sendResponse(w, "403 Forbidden", "text/plain", why);
    }

    /// Checks a remote player's password, setting a session cookie if it
    /// is right.
    fn login(s: *Server, w: *Io.Writer, peer: net.IpAddress, agent: []const u8, body: []const u8) !void {
        if (!s.remote.listening()) return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
        var client_buf: [256]u8 = undefined;
        const client = std.fmt.bufPrint(&client_buf, "{f} via {s}", .{ peer, agent }) catch agent;
        switch (try s.remote.login(addressKey(peer), client, std.mem.trim(u8, body, " \t\r\n"))) {
            .ok => |token| {
                var cookie_buf: [128]u8 = undefined;
                return sendResponseHeaders(w, "204 No Content", "text/plain", try sessionCookie(&cookie_buf, token), "");
            },
            .wrong => return sendResponse(w, "401 Unauthorized", "text/plain", "wrong password\n"),
            .slow => return sendResponse(w, "429 Too Many Requests", "text/plain", "too many tries; wait a little\n"),
        }
    }

    /// Gives the password from an invite link. Right, it sets the session
    /// cookie and redirects to `/`; wrong, it shows the password page.
    fn loginFromLink(s: *Server, w: *Io.Writer, peer: net.IpAddress, agent: []const u8, guess: []const u8) !void {
        if (!s.remote.listening()) return redirectHome(w, "");
        var client_buf: [256]u8 = undefined;
        const client = std.fmt.bufPrint(&client_buf, "{f} via {s} (invite link)", .{ peer, agent }) catch agent;
        switch (try s.remote.login(addressKey(peer), client, guess)) {
            .ok => |token| {
                var cookie_buf: [128]u8 = undefined;
                return redirectHome(w, try sessionCookie(&cookie_buf, token));
            },
            .wrong, .slow => return sendResponse(w, "200 OK", "text/html; charset=utf-8", login_html),
        }
    }

    /// The host:port for invite links: the `--listen` address if it names
    /// one, the Host a remote requester used, or else the address this
    /// machine uses to reach the network.
    fn inviteHost(s: *const Server, request_host: ?[]const u8, local: bool, buf: []u8) ?[]const u8 {
        if (s.listen_address) |address| if (!s.listen_any) {
            const v6 = std.mem.indexOfScalar(u8, address, ':') != null;
            return std.fmt.bufPrint(buf, "{s}{s}{s}:{d}", .{ if (v6) "[" else "", address, if (v6) "]" else "", s.port }) catch null;
        };
        if (!local) if (request_host) |host| return host;
        // Connecting a UDP socket sends nothing, but makes the system pick
        // the local address it would use (192.0.2.1 is a documentation
        // address).
        const probe: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 192, 0, 2, 1 }, .port = 9 } };
        const stream = probe.connect(s.io, .{ .mode = .dgram }) catch return null;
        defer stream.close(s.io);
        return switch (stream.socket.address) {
            .ip4 => |a| if (isUnspecified(stream.socket.address) or a.bytes[0] == 127)
                null
            else
                std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], s.port }) catch null,
            .ip6 => null,
        };
    }

    /// Gives a person on the play page a name.
    fn join(s: *Server, w: *Io.Writer, player: Remote.Player, token: ?Remote.Token, name: []const u8) !void {
        if (player.ai) return sendResponse(w, "400 Bad Request", "text/plain", "AI partners are named by X-Player\n");
        if (!Remote.validName(name)) return sendResponse(w, "400 Bad Request", "text/plain", "a name is 1 to 32 printable characters\n");
        const result = if (token) |t| s.remote.joinSession(t, name) else s.remote.touch(.{ .name = name, .local = true });
        result catch |err| switch (err) {
            error.NameTaken => return sendResponse(w, "409 Conflict", "text/plain", "that name is taken\n"),
            error.Kicked => return sendResponse(w, "403 Forbidden", "text/plain", "you were removed from the game\n"),
            else => return err,
        };
        return sendResponse(w, "204 No Content", "text/plain", "");
    }

    /// Queues a command and replies with the game's response once it waits
    /// for input again.
    fn command(s: *Server, w: *Io.Writer, text: []const u8, player: Remote.Player, client: []const u8) !void {
        const id = s.remote.submit(client, player, text) catch |err| switch (err) {
            error.InvalidCommand => return sendResponse(
                w,
                "400 Bad Request",
                "text/plain",
                "a command is one line of printable text\n",
            ),
            error.NotYourTurn => return sendResponse(
                w,
                "409 Conflict",
                "text/plain",
                "in debate mode only the leader sends commands; suggest yours with POST /say\n",
            ),
            else => return err,
        };

        var out: Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        var waited: u32 = 0;
        while (!try s.remote.writeReply(&out.writer, id)) {
            if (waited >= poll_timeout_ms) {
                // Still queued or still running; the text will appear in
                // /transcript.
                out.clearRetainingCapacity();
                try out.writer.print("{{\"id\":{d},\"pending\":true}}", .{id});
                return sendResponse(w, "202 Accepted", "application/json", out.written());
            }
            try s.io.sleep(.fromMilliseconds(poll_interval_ms / 4), .awake);
            waited += poll_interval_ms / 4;
        }
        return sendResponse(w, "200 OK", "application/json", out.written());
    }

    /// Adds a thought or message to the discussion. The body is JSON:
    /// `{"text": "...", "suggestions": ["..."], "kind": "thought"}`.
    fn say(s: *Server, w: *Io.Writer, body: []const u8, player: Remote.Player) !void {
        const Say = struct {
            text: []const u8 = "",
            suggestions: []const []const u8 = &.{},
            kind: Remote.PostKind = .message,
        };
        const parsed = std.json.parseFromSlice(Say, s.gpa, body, .{ .ignore_unknown_fields = true }) catch
            return sendResponse(w, "400 Bad Request", "text/plain", "expected {\"text\": ..., \"suggestions\": [...]}\n");
        defer parsed.deinit();
        const v = parsed.value;
        s.remote.post(player, v.kind, v.text, v.suggestions) catch |err| switch (err) {
            error.InvalidPost => return sendResponse(
                w,
                "400 Bad Request",
                "text/plain",
                "a post is a thought or message with text or suggested commands (one line each, at most 8)\n",
            ),
            else => return err,
        };
        return sendResponse(w, "204 No Content", "text/plain", "");
    }

    /// Whether a Host header names this server. On this machine it is
    /// 127.0.0.1 or localhost; from elsewhere it is the `--listen` address,
    /// or any name when listening on all addresses.
    fn allowedHost(s: *const Server, host: ?[]const u8, local: bool) bool {
        const h = host orelse return true;
        var buf: [96]u8 = undefined;
        if (local) for ([_][]const u8{ "127.0.0.1", "localhost" }) |name| {
            const expected = std.fmt.bufPrint(&buf, "{s}:{d}", .{ name, s.port }) catch continue;
            if (std.ascii.eqlIgnoreCase(h, expected)) return true;
        };
        const address = s.listen_address orelse return false;
        if (s.listen_any) return true;
        const expected = std.fmt.bufPrint(&buf, "{s}:{d}", .{ address, s.port }) catch return false;
        return std.ascii.eqlIgnoreCase(h, expected);
    }
};

/// A page may only call the server from the server's own pages: its
/// Origin, if it sends one, must name the same host.
fn allowedOrigin(origin: ?[]const u8, host: ?[]const u8) bool {
    const o = origin orelse return true;
    const prefix = "http://";
    const h = host orelse return false;
    return std.mem.startsWith(u8, o, prefix) and std.ascii.eqlIgnoreCase(o[prefix.len..], h);
}

/// The header that sets the session cookie. Lax, not Strict, so it is sent
/// when an invite link opened from another site redirects to `/`; it still
/// isn't sent with requests other sites make.
fn sessionCookie(buf: []u8, token: Remote.Token) ![]const u8 {
    return std.fmt.bufPrint(buf, "Set-Cookie: {s}={s}; Path=/; HttpOnly; SameSite=Lax\r\n", .{
        session_cookie, &std.fmt.bytesToHex(token, .lower),
    });
}

/// Redirects to the play page, with any `extra` header lines.
fn redirectHome(w: *Io.Writer, extra: []const u8) !void {
    var buf: [192]u8 = undefined;
    const headers = try std.fmt.bufPrint(&buf, "Location: /\r\n{s}", .{extra});
    return sendResponseHeaders(w, "303 See Other", "text/plain", headers, "");
}

/// Writes `text` for a query string, escaping all but unreserved characters.
fn percentEncode(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// Decodes a query string value into `buf`: `%XX` escapes, and `+` as a
/// space. Anything that doesn't fit is cut off.
fn percentDecode(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < buf.len) : (n += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                buf[n] = byte;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[n] = if (text[i] == '+') ' ' else text[i];
        i += 1;
    }
    return buf[0..n];
}

fn leaderError(w: *Io.Writer, err: Remote.LeaderError) !void {
    return switch (err) {
        error.NotLeader => sendResponse(w, "403 Forbidden", "text/plain", "only the leader may do that\n"),
        error.UnknownPlayer => sendResponse(w, "404 Not Found", "text/plain", "nobody playing has that name\n"),
        error.CannotKick => sendResponse(w, "409 Conflict", "text/plain", "the console and local players can't be kicked\n"),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn passwordError(w: *Io.Writer, err: Remote.PasswordError) !void {
    return switch (err) {
        error.NotListening => sendResponse(w, "404 Not Found", "text/plain", "there is no password without --listen\n"),
        error.NotAllowed => sendResponse(w, "403 Forbidden", "text/plain", "only this machine and the leader may do that\n"),
        else => sendResponse(w, "503 Service Unavailable", "text/plain", "could not make a password\n"),
    };
}

fn isLoopback(address: net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(@as([15]u8, @splat(0)) ++ [_]u8{1})) or
            // An IPv4 loopback address mapped into IPv6.
            (std.mem.eql(u8, a.bytes[0..12], &(@as([10]u8, @splat(0)) ++ [_]u8{ 0xff, 0xff })) and a.bytes[12] == 127),
    };
}

fn isUnspecified(address: net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| std.mem.allEqual(u8, &a.bytes, 0),
        .ip6 => |a| std.mem.allEqual(u8, &a.bytes, 0),
    };
}

/// The address without its port, for counting password guesses.
fn addressKey(address: net.IpAddress) Remote.AddressKey {
    var key: Remote.AddressKey = @splat(0);
    switch (address) {
        .ip4 => |a| @memcpy(key[0..4], &a.bytes),
        .ip6 => |a| key = a.bytes,
    }
    return key;
}

/// Reads a request body of at most 4KiB, or responds with an error and
/// returns null.
fn readBody(r: *Io.Reader, w: *Io.Writer, headers: *const Headers) !?[]const u8 {
    const length = headers.content_length orelse {
        try sendResponse(w, "411 Length Required", "text/plain", "length required\n");
        return null;
    };
    if (length > 4096) {
        try sendResponse(w, "413 Content Too Large", "text/plain", "body too long\n");
        return null;
    }
    return try r.take(length);
}

/// The request headers the server looks at.
const Headers = struct {
    host: ?[]u8 = null,
    origin: ?[]u8 = null,
    user_agent: ?[]u8 = null,
    content_length: ?usize = null,
    player_name: ?[]u8 = null,
    person_name: ?[]u8 = null,
    cookie: ?[]u8 = null,

    /// The AI partner named by X-Player, or null for a person.
    fn ai(h: *const Headers) ?[]const u8 {
        const name = h.player_name orelse return null;
        return if (std.ascii.eqlIgnoreCase(name, "you")) null else name;
    }

    /// The session token from the cookie, if any.
    fn session(h: *const Headers) ?Remote.Token {
        var cookies = std.mem.tokenizeScalar(u8, h.cookie orelse return null, ';');
        while (cookies.next()) |raw| {
            const c = std.mem.trim(u8, raw, " ");
            const prefix = session_cookie ++ "=";
            if (!std.mem.startsWith(u8, c, prefix)) continue;
            var token: Remote.Token = undefined;
            const bytes = std.fmt.hexToBytes(&token, c[prefix.len..]) catch return null;
            if (bytes.len != token.len) return null;
            return token;
        }
        return null;
    }

    fn add(h: *Headers, gpa: Allocator, line: []const u8) !void {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const slot = if (std.ascii.eqlIgnoreCase(name, "host"))
            &h.host
        else if (std.ascii.eqlIgnoreCase(name, "origin"))
            &h.origin
        else if (std.ascii.eqlIgnoreCase(name, "user-agent"))
            &h.user_agent
        else if (std.ascii.eqlIgnoreCase(name, "x-player"))
            &h.player_name
        else if (std.ascii.eqlIgnoreCase(name, "x-person"))
            &h.person_name
        else if (std.ascii.eqlIgnoreCase(name, "cookie"))
            &h.cookie
        else {
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                h.content_length = std.fmt.parseInt(usize, value, 10) catch null;
            }
            return;
        };
        if (slot.*) |old| gpa.free(old);
        slot.* = try gpa.dupe(u8, value[0..@min(value.len, 1000)]);
    }

    fn deinit(h: *Headers, gpa: Allocator) void {
        for ([_]?[]u8{ h.host, h.origin, h.user_agent, h.player_name, h.person_name, h.cookie }) |v| if (v) |slice| gpa.free(slice);
    }
};

fn parseSince(query: []const u8) u64 {
    return std.fmt.parseInt(u64, queryValue(query, "since") orelse return 0, 10) catch 0;
}

fn queryValue(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..eq], name)) return if (eq < pair.len) pair[eq + 1 ..] else "";
    }
    return null;
}

fn sendResponse(w: *Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    return sendResponseHeaders(w, status, content_type, "", body);
}

/// Sends a response with `extra` header lines, each ending in CRLF.
fn sendResponseHeaders(w: *Io.Writer, status: []const u8, content_type: []const u8, extra: []const u8, body: []const u8) !void {
    try w.print(
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}" ++
            "Cache-Control: no-store\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len, extra },
    );
    try w.writeAll(body);
    try w.flush();
}

test Headers {
    var h: Headers = .{};
    defer h.deinit(std.testing.allocator);
    try h.add(std.testing.allocator, "Host: 127.0.0.1:8080");
    try h.add(std.testing.allocator, "content-length: 12");
    try h.add(std.testing.allocator, "User-Agent:  curl/8.7.1 ");
    try std.testing.expectEqual(@as(?[]const u8, null), h.ai());
    try h.add(std.testing.allocator, "X-Player: Claude");
    try std.testing.expectEqualStrings("Claude", h.ai().?);
    try std.testing.expectEqualStrings("127.0.0.1:8080", h.host.?);
    try std.testing.expectEqualStrings("curl/8.7.1", h.user_agent.?);
    try std.testing.expectEqual(@as(?usize, 12), h.content_length);
    try std.testing.expectEqual(@as(?[]u8, null), h.origin);
    try std.testing.expectEqual(@as(?Remote.Token, null), h.session());
    try h.add(std.testing.allocator, "Cookie: theme=dark; zmachine_session=000102030405060708090a0b0c0d0e0f");
    try std.testing.expectEqual(@as(u8, 15), h.session().?[15]);
}

test parseSince {
    try std.testing.expectEqual(@as(u64, 42), parseSince("since=42"));
    try std.testing.expectEqual(@as(u64, 7), parseSince("x=1&since=7"));
    try std.testing.expectEqual(@as(u64, 0), parseSince(""));
    try std.testing.expectEqualStrings("", queryValue("since=3&wait", "wait").?);
    try std.testing.expectEqual(@as(?[]const u8, null), queryValue("waiting=1", "wait"));
}

test percentDecode {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("amber otter-glide", percentDecode(&buf, "amber+otter%2Dglide"));
    try std.testing.expectEqualStrings("50%", percentDecode(&buf, "50%"));
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try percentEncode(&out.writer, "yo-yo & co");
    try std.testing.expectEqualStrings("yo-yo%20%26%20co", out.written());
}

test isLoopback {
    try std.testing.expect(isLoopback(.{ .ip4 = .loopback(80) }));
    try std.testing.expect(!isLoopback(try net.IpAddress.parse("192.168.1.5", 80)));
    try std.testing.expect(isLoopback(try net.IpAddress.parse("::1", 80)));
    try std.testing.expect(isLoopback(try net.IpAddress.parse("::ffff:127.0.0.1", 80)));
    try std.testing.expect(isUnspecified(try net.IpAddress.parse("0.0.0.0", 80)));
    try std.testing.expect(allowedOrigin(null, null));
    try std.testing.expect(allowedOrigin("http://10.0.0.2:9675", "10.0.0.2:9675"));
    try std.testing.expect(!allowedOrigin("http://evil.example", "10.0.0.2:9675"));
}
