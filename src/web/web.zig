//! A small embedded HTTP server for playing together, and for the live
//! object inspector and map.
//!
//! Routes:
//!   GET /                 the play page: the game beside the discussion
//!                         (or the password page for a remote player
//!                         without a session). `?password=` gives the
//!                         password and redirects to `/`, so an invite link
//!                         joins in one click
//!   /inspector, /state and /erase-map
//!                         the inspector's routes (`Routes`; local only)
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
//!   GET /events?since=N   audit log events after N (long polling)
//!   POST /mcp             a message for an AI partner's MCP session
//!                         (streamable HTTP, this machine only); DELETE
//!                         ends the session
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

const Group = @import("poly").Group;
const Hub = @import("hub").Hub;
const Password = @import("poly").Password;
const protocol = @import("protocol");

const play_html = @embedFile("play.html");
const login_html = @embedFile("login.html");

/// How long a long-poll request waits for something new.
const poll_timeout_ms = 20_000;
const poll_interval_ms = 100;

const session_cookie = "zmachine_session";

/// Routes another module serves, such as the inspector's. They answer only
/// this machine, and AI partners only `ai_path`, when let read the
/// inspector.
pub const Routes = struct {
    context: *anyopaque,
    paths: []const []const u8,
    ai_path: []const u8,
    /// Answers a request for one of `paths`, or returns null for a method
    /// it doesn't take.
    handle: *const fn (context: *anyopaque, arena: Allocator, method: []const u8, path: []const u8, query: []const u8) anyerror!?Answer,

    fn owns(r: Routes, path: []const u8) bool {
        for (r.paths) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

/// The MCP service, which answers messages posted to `/mcp`.
pub const Mcp = struct {
    context: *anyopaque,
    /// Answers a message; `session` is the request's Mcp-Session-Id and
    /// `profile` the interface asked for ("simple"), when it opens one.
    post: *const fn (context: *anyopaque, arena: Allocator, session: ?[]const u8, profile: ?[]const u8, body: []const u8) anyerror!protocol.McpReply,
    /// Ends a session, returning whether there was one.
    end: *const fn (context: *anyopaque, session: []const u8) bool,
};

pub const Answer = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    /// What to note in the audit log, if anything.
    log: ?Log = null,

    pub const Log = struct {
        kind: Group.Kind,
        detail: []const u8,
        suspicious: bool,
    };
};

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    routes: Routes,
    /// Set before `serve`, or null to have no `/mcp`.
    mcp: ?Mcp = null,
    hub: *Hub,
    group: *Group,
    port: u16,
    /// The address given with `--listen`, or null to listen on 127.0.0.1
    /// only. An unspecified address (such as 0.0.0.0) accepts any Host.
    listen_address: ?[]const u8,
    listen_any: bool,
    listener: net.Server,
    /// With a specific `--listen` address, the loopback listener too, so
    /// this machine (and the MCP server) can still connect.
    loopback: ?net.Server,

    /// Binds to `port` on the loopback interface and, with
    /// `listen_address`, on that address as well. What the game takes
    /// from `hub` goes to `group`'s discussion and audit log.
    pub fn listen(gpa: Allocator, io: Io, routes: Routes, hub: *Hub, group: *Group, port: u16, listen_address: ?[]const u8) !Server {
        const loopback: net.IpAddress = .{ .ip4 = .loopback(port) };
        const address: net.IpAddress = if (listen_address) |text| try net.IpAddress.parse(text, port) else loopback;
        const listener = try address.listen(io, .{ .reuse_address = true });
        // 0.0.0.0 already covers the loopback address; `::` may, depending
        // on the system, so a clash there is no error.
        const also_loopback = listen_address != null and !(address == .ip4 and isUnspecified(address));
        const extra: ?net.Server = if (also_loopback) loopback.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse => if (isUnspecified(address)) null else return err,
            else => return err,
        } else null;
        hub.hooks = .{ .context = group, .taken = taken };
        return .{
            .gpa = gpa,
            .io = io,
            .routes = routes,
            .hub = hub,
            .group = group,
            .port = port,
            .listen_address = listen_address,
            .listen_any = if (listen_address != null) isUnspecified(address) else false,
            .listener = listener,
            .loopback = extra,
        };
    }

    /// Accepts connections forever, one thread per connection, on every
    /// listener.
    pub fn serve(s: *Server) void {
        if (s.loopback) |*extra| {
            if (std.Thread.spawn(.{}, acceptLoop, .{ s, extra })) |thread| thread.detach() else |_| {}
        }
        acceptLoop(s, &s.listener);
    }

    fn acceptLoop(s: *Server, listener: *net.Server) void {
        while (true) {
            const stream = listener.accept(s.io) catch |err| {
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
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

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
        var from_buf: [64]u8 = undefined;
        const from = fromText(&from_buf, peer);

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
            s.group.logFrom(.refused, agent, from, detail, true);
            return sendResponse(w, "403 Forbidden", "text/plain", "forbidden\n");
        }

        // Work out who is asking.
        var name_buf: [64]u8 = undefined;
        var token: ?Group.Token = null;
        var player: Group.Player = .console;
        if (headers.ai()) |name| {
            if (!Group.validName(name)) {
                return sendResponse(w, "400 Bad Request", "text/plain", "X-Player names an AI partner in 1 to 32 printable characters\n");
            }
            if (!local) return s.refuse(w, .{ .client = agent, .from = from }, method, path, "AI partners connect from this machine\n");
            player = .{ .name = name, .ai = true, .local = false };
        } else if (local) {
            if (headers.person_name) |name| {
                if (!Group.validName(name)) {
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
            const state: Group.SessionState = if (token) |t| s.group.session(t, &name_buf) else .none;
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
        const who: Who = .{ .client = client, .from = from };

        // The inspector shows what players can't see. The audit log is open
        // to everyone, so leaders and the others see the same record.
        const local_only = s.routes.owns(path);
        if (local_only and !local) return s.refuse(w, who, method, path, "this page is only for this machine\n");
        // AI partners read the inspector's snapshots, and only when let.
        if (local_only and player.ai) {
            if (!std.mem.eql(u8, path, s.routes.ai_path)) return s.refuse(w, who, method, path, "AI partners only read the inspector's snapshots\n");
            if (!s.group.mayInspect(player)) return s.refuse(w, who, method, path, "nobody has let you read the inspector\n");
        }
        if (std.mem.eql(u8, path, "/mcp")) return s.mcpRoute(w, r, &headers, null, method, local, who);
        if (std.mem.startsWith(u8, path, "/mcp/")) {
            const profile = path["/mcp/".len..];
            if (!std.mem.eql(u8, profile, "simple")) return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
            return s.mcpRoute(w, r, &headers, profile, method, local, who);
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
            s.group.touch(player) catch |err| switch (err) {
                error.NameTaken => return sendResponse(w, "409 Conflict", "text/plain", "that name is taken\n"),
                error.Kicked => return s.refuse(w, who, method, path, "you were removed from the game\n"),
                else => return err,
            };
        } else if (!local and std.mem.eql(u8, method, "POST")) {
            return sendResponse(w, "403 Forbidden", "text/plain", "choose a name with POST /join first\n");
        }

        if (std.mem.eql(u8, method, "POST")) {
            const body = (try readBody(r, w, &headers)) orelse return;
            const text = std.mem.trim(u8, body, " \t\r\n");
            if (std.mem.eql(u8, path, "/command")) return s.command(w, arena, text, player, who, std.mem.eql(u8, queryValue(query, "format") orelse "", "text"));
            if (std.mem.eql(u8, path, "/say")) return s.say(w, body, player);
            if (std.mem.eql(u8, path, "/clear-discussion")) {
                s.group.clearDiscussion(player) catch |err| switch (err) {
                    error.NotAllowed => return s.refuse(w, who, method, path, "only this machine clears the discussion\n"),
                    else => return err,
                };
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/mode")) {
                const mode = std.meta.stringToEnum(Group.Mode, text) orelse
                    return sendResponse(w, "400 Bad Request", "text/plain", "the mode is debate or turns\n");
                s.group.setMode(player, mode) catch |err| return leaderError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/lead")) {
                s.group.passLeadership(player, text) catch |err| return leaderError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/kick")) {
                s.group.kick(player, text) catch |err| return leaderError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (std.mem.eql(u8, path, "/grant-inspector") or std.mem.eql(u8, path, "/revoke-inspector")) {
                const grant = std.mem.eql(u8, path, "/grant-inspector");
                s.group.setInspectorAccess(player, text, grant) catch |err| return switch (err) {
                    error.NotAllowed => sendResponse(w, "403 Forbidden", "text/plain", "only people on this machine may do that\n"),
                    error.UnknownPlayer => sendResponse(w, "404 Not Found", "text/plain", "no AI partner playing has that name\n"),
                    error.OutOfMemory => error.OutOfMemory,
                };
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            if (local_only) if (try s.routes.handle(s.routes.context, arena, method, path, query)) |answer| return s.send(w, who, answer);
            if (std.mem.eql(u8, path, "/password")) {
                s.group.changePassword(player, if (text.len > 0) text else null) catch |err| return passwordError(w, err);
                return sendResponse(w, "204 No Content", "text/plain", "");
            }
            return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
        }
        if (!std.mem.eql(u8, method, "GET")) {
            return sendResponse(w, "405 Method Not Allowed", "text/plain", "method not allowed\n");
        }

        if (local_only) if (try s.routes.handle(s.routes.context, arena, method, path, query)) |answer| return s.send(w, who, answer);
        if (std.mem.eql(u8, path, "/")) {
            return sendResponse(w, "200 OK", "text/html; charset=utf-8", play_html);
        }
        if (std.mem.eql(u8, path, "/me")) {
            return sendJson(w, arena, protocol.Me{
                .name = player.name,
                .ai = player.ai,
                .local = player.local,
                .leader = s.group.leads(player),
                .listening = s.group.listening(),
            });
        }
        if (std.mem.eql(u8, path, "/random-password")) {
            if (!s.group.managesPassword(player)) return passwordError(w, if (s.group.listening()) error.NotAllowed else error.NotListening);
            const password = Password.generate(s.group.world) catch |err| return passwordError(w, err);
            return sendResponse(w, "200 OK", "text/plain; charset=utf-8", password.slice());
        }
        if (std.mem.eql(u8, path, "/invite")) {
            var buf: [Password.max_len]u8 = undefined;
            const password = s.group.readPassword(player, &buf, "fetched an invite link with") catch |err| return passwordError(w, err);
            var host_buf: [128]u8 = undefined;
            const host = s.inviteHost(headers.host, local, &host_buf) orelse
                return sendResponse(w, "503 Service Unavailable", "text/plain", "could not tell this machine's address\n");
            var out: Io.Writer.Allocating = .init(s.gpa);
            defer out.deinit();
            try out.writer.print("http://{s}/?password=", .{host});
            try percentEncode(&out.writer, password);
            return sendResponse(w, "200 OK", "text/plain; charset=utf-8", out.written());
        }
        if (std.mem.eql(u8, path, "/story")) {
            const story = (try s.hub.storyInfo(arena)) orelse return sendResponse(w, "404 Not Found", "text/plain", "no story is loaded\n");
            return sendJson(w, arena, protocol.StoryInfo{
                .file = story.file,
                .zversion = story.zversion,
                .release = story.release,
                .serial = &story.serial,
                .seed = story.seed,
                .seed_random = story.seed_random,
                .mode = @tagName(s.group.currentMode()),
            });
        }
        if (std.mem.eql(u8, path, "/transcript")) {
            const since = parseSince(query);
            if (queryValue(query, "wait") != null) {
                var waited: u32 = 0;
                // A client ahead of the game (the program restarted) is answered at once.
                while (s.hub.textOffset() == since and waited < poll_timeout_ms) {
                    try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                    waited += poll_interval_ms;
                }
            }
            const t = try s.hub.textSince(arena, since);
            if (std.mem.eql(u8, queryValue(query, "format") orelse "", "text"))
                return sendResponse(w, "200 OK", "text/plain; charset=utf-8", plainTail(t.text));
            return sendJson(w, arena, protocol.Transcript{
                .offset = t.offset,
                .waiting = t.waiting,
                .mode = @tagName(s.group.currentMode()),
                .text = t.text,
                .status = &t.status,
            });
        }
        if (std.mem.eql(u8, path, "/discussion")) {
            const since = parseSince(query);
            var waited: u32 = 0;
            while (queryValue(query, "wait") != null and s.group.lastPost() == since and waited < poll_timeout_ms) {
                try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                waited += poll_interval_ms;
            }
            return sendJson(w, arena, try s.group.discussionSince(arena, since));
        }
        if (std.mem.eql(u8, path, "/events")) {
            const since = parseSince(query);
            var waited: u32 = 0;
            while (s.group.lastEvent() == since and waited < poll_timeout_ms) {
                try s.io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
                waited += poll_interval_ms;
            }
            return sendJson(w, arena, try s.group.events(arena, since, local));
        }
        return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
    }

    /// Serves the MCP endpoint (`/mcp`, or `/mcp/simple` for the simple
    /// profile) to partners on this machine. Their game
    /// requests come back through the other routes, named by X-Player.
    fn mcpRoute(s: *Server, w: *Io.Writer, r: *Io.Reader, headers: *const Headers, path_profile: ?[]const u8, method: []const u8, local: bool, who: Who) !void {
        const mcp = s.mcp orelse return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
        if (!local) return s.refuse(w, who, method, "/mcp", "MCP clients connect from this machine\n");
        if (std.mem.eql(u8, method, "DELETE")) {
            const session = headers.mcp_session orelse return sendResponse(w, "400 Bad Request", "text/plain", "missing Mcp-Session-Id\n");
            if (!mcp.end(mcp.context, session)) return sendResponse(w, "404 Not Found", "text/plain", "unknown session\n");
            return sendResponse(w, "204 No Content", "text/plain", "");
        }
        // The service sends no messages of its own, so there is no stream
        // to GET.
        if (!std.mem.eql(u8, method, "POST")) return sendResponseHeaders(w, "405 Method Not Allowed", "text/plain", "Allow: POST, DELETE\r\n", "use POST\n");
        const body = (try readBody(r, w, headers)) orelse return;
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const answer = try mcp.post(mcp.context, arena, headers.mcp_session, path_profile orelse headers.mcp_profile, body);
        const status = switch (answer.status) {
            200 => "200 OK",
            202 => "202 Accepted",
            404 => "404 Not Found",
            503 => "503 Service Unavailable",
            else => "400 Bad Request",
        };
        var extra_buf: [96]u8 = undefined;
        const extra = if (answer.session) |id| try std.fmt.bufPrint(&extra_buf, "Mcp-Session-Id: {s}\r\n", .{id}) else "";
        return sendResponseHeaders(w, status, "application/json", extra, answer.body);
    }

    /// Sends another module's answer, noting it in the audit log.
    fn send(s: *Server, w: *Io.Writer, who: Who, answer: Answer) !void {
        if (answer.log) |l| s.group.logFrom(l.kind, who.client, who.from, l.detail, l.suspicious);
        return sendResponse(w, answer.status, answer.content_type, answer.body);
    }

    /// Refuses a request, logging it as suspicious.
    fn refuse(s: *Server, w: *Io.Writer, who: Who, method: []const u8, path: []const u8, why: []const u8) !void {
        var detail_buf: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "{s} {s}: {s}", .{ method, path, std.mem.trimEnd(u8, why, "\n") }) catch path;
        s.group.logFrom(.refused, who.client, who.from, detail, true);
        return sendResponse(w, "403 Forbidden", "text/plain", why);
    }

    /// Checks a remote player's password, setting a session cookie if it
    /// is right.
    fn login(s: *Server, w: *Io.Writer, peer: net.IpAddress, agent: []const u8, body: []const u8) !void {
        if (!s.group.listening()) return sendResponse(w, "404 Not Found", "text/plain", "not found\n");
        var from_buf: [64]u8 = undefined;
        switch (try s.group.login(addressKey(peer), agent, fromText(&from_buf, peer), std.mem.trim(u8, body, " \t\r\n"))) {
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
        if (!s.group.listening()) return redirectHome(w, "");
        var from_buf: [64]u8 = undefined;
        var client_buf: [256]u8 = undefined;
        const client = std.fmt.bufPrint(&client_buf, "{s} (invite link)", .{agent}) catch agent;
        switch (try s.group.login(addressKey(peer), client, fromText(&from_buf, peer), guess)) {
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

    /// The invite link for the console, which asks no one: `http://<host>/?password=<password>`.
    pub fn consoleInviteLink(s: *const Server, buf: []u8, password: []const u8) ?[]const u8 {
        var host_buf: [128]u8 = undefined;
        const host = s.inviteHost(null, true, &host_buf) orelse return null;
        var w: Io.Writer = .fixed(buf);
        w.print("http://{s}/?password=", .{host}) catch return null;
        percentEncode(&w, password) catch return null;
        return w.buffered();
    }

    /// Gives a person on the play page a name.
    fn join(s: *Server, w: *Io.Writer, player: Group.Player, token: ?Group.Token, name: []const u8) !void {
        if (player.ai) return sendResponse(w, "400 Bad Request", "text/plain", "AI partners are named by X-Player\n");
        if (!Group.validName(name)) return sendResponse(w, "400 Bad Request", "text/plain", "a name is 1 to 32 printable characters\n");
        const result = if (token) |t| s.group.joinSession(t, name) else s.group.touch(.{ .name = name, .local = true });
        result catch |err| switch (err) {
            error.NameTaken => return sendResponse(w, "409 Conflict", "text/plain", "that name is taken\n"),
            error.Kicked => return sendResponse(w, "403 Forbidden", "text/plain", "you were removed from the game\n"),
            else => return err,
        };
        return sendResponse(w, "204 No Content", "text/plain", "");
    }

    /// Queues a command and replies with the game's response once it waits
    /// for input again. With `plain` the reply is only the game text, for
    /// a client that cannot read JSON.
    fn command(s: *Server, w: *Io.Writer, arena: Allocator, text: []const u8, player: Group.Player, who: Who, plain: bool) !void {
        if (!Group.validCommand(text)) return sendResponse(
            w,
            "400 Bad Request",
            "text/plain",
            "a command is one line of printable text\n",
        );
        if (!s.group.maySend(player)) return sendResponse(
            w,
            "409 Conflict",
            "text/plain",
            "in debate mode only the leader sends commands; suggest yours with POST /say\n",
        );
        const id = try s.hub.submit(.{ .name = player.name, .ai = player.ai }, text);
        s.group.logFrom(.command, who.client, who.from, text, false);

        var waited: u32 = 0;
        while (true) {
            if (try s.hub.takeAnswer(arena, id)) |a| if (plain) return sendResponse(w, "200 OK", "text/plain; charset=utf-8", a.output) else return sendJson(w, arena, protocol.CommandReply{
                .id = id,
                .echo = a.echo,
                .offset = a.offset,
                .output = a.output,
                .status = &a.status,
            });
            if (waited >= poll_timeout_ms) {
                // Still queued or still running; the text will appear in
                // /transcript.
                if (plain) return sendResponse(w, "202 Accepted", "text/plain; charset=utf-8", "The game has not answered yet; try GET /transcript?format=text again shortly.\n");
                return sendJsonStatus(w, arena, "202 Accepted", protocol.CommandReply{ .id = id, .pending = true });
            }
            try s.io.sleep(.fromMilliseconds(poll_interval_ms / 4), .awake);
            waited += poll_interval_ms / 4;
        }
    }

    /// Adds a thought or message to the discussion. The body is JSON:
    /// `{"text": "...", "suggestions": ["..."], "kind": "thought"}`.
    fn say(s: *Server, w: *Io.Writer, body: []const u8, player: Group.Player) !void {
        const Say = struct {
            text: []const u8 = "",
            suggestions: []const []const u8 = &.{},
            kind: Group.PostKind = .message,
        };
        const parsed = std.json.parseFromSlice(Say, s.gpa, body, .{ .ignore_unknown_fields = true }) catch
            return sendResponse(w, "400 Bad Request", "text/plain", "expected {\"text\": ..., \"suggestions\": [...]}\n");
        defer parsed.deinit();
        const v = parsed.value;
        s.group.post(player, v.kind, v.text, v.suggestions) catch |err| switch (err) {
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

/// Notes each line the game takes in the discussion, and keyboard lines in
/// the audit log.
fn taken(context: *anyopaque, sender: ?Hub.Sender, line: []const u8) void {
    const group: *Group = @ptrCast(@alignCast(context));
    if (sender) |s| {
        group.heard(.{ .name = s.name, .ai = s.ai, .local = false }, line, false);
    } else {
        group.heard(.console, line, true);
    }
}

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
fn sessionCookie(buf: []u8, token: Group.Token) ![]const u8 {
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

fn leaderError(w: *Io.Writer, err: Group.LeaderError) !void {
    return switch (err) {
        error.NotLeader => sendResponse(w, "403 Forbidden", "text/plain", "only the leader may do that\n"),
        error.UnknownPlayer => sendResponse(w, "404 Not Found", "text/plain", "nobody playing has that name\n"),
        error.CannotKick => sendResponse(w, "409 Conflict", "text/plain", "the console and local players can't be kicked\n"),
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn passwordError(w: *Io.Writer, err: Group.PasswordError) !void {
    return switch (err) {
        error.NotListening => sendResponse(w, "404 Not Found", "text/plain", "there is no password without --listen\n"),
        error.NotAllowed => sendResponse(w, "403 Forbidden", "text/plain", "only this machine and the leader may do that\n"),
        else => sendResponse(w, "503 Service Unavailable", "text/plain", "could not make a password\n"),
    };
}

/// Who a request is from, as the audit log records it: the client's
/// description, and its address ("this machine" if local).
const Who = struct {
    client: []const u8,
    from: []const u8,
};

/// The address without its port, or "this machine" for a local one.
fn fromText(buf: []u8, address: net.IpAddress) []const u8 {
    if (isLoopback(address)) return Group.local_address;
    const text = std.fmt.bufPrint(buf, "{f}", .{address}) catch return "remote";
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return text;
    return std.mem.trim(u8, text[0..colon], "[]");
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
fn addressKey(address: net.IpAddress) Group.AddressKey {
    var key: Group.AddressKey = @splat(0);
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
    mcp_session: ?[]u8 = null,
    mcp_profile: ?[]u8 = null,

    /// The AI partner named by X-Player, or null for a person.
    fn ai(h: *const Headers) ?[]const u8 {
        const name = h.player_name orelse return null;
        return if (std.ascii.eqlIgnoreCase(name, "you")) null else name;
    }

    /// The session token from the cookie, if any.
    fn session(h: *const Headers) ?Group.Token {
        var cookies = std.mem.tokenizeScalar(u8, h.cookie orelse return null, ';');
        while (cookies.next()) |raw| {
            const c = std.mem.trim(u8, raw, " ");
            const prefix = session_cookie ++ "=";
            if (!std.mem.startsWith(u8, c, prefix)) continue;
            var token: Group.Token = undefined;
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
        else if (std.ascii.eqlIgnoreCase(name, "mcp-session-id"))
            &h.mcp_session
        else if (std.ascii.eqlIgnoreCase(name, "mcp-profile"))
            &h.mcp_profile
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
        for ([_]?[]u8{ h.host, h.origin, h.user_agent, h.player_name, h.person_name, h.cookie, h.mcp_session, h.mcp_profile }) |v| if (v) |slice| gpa.free(slice);
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

/// Sends `value`, one of the `protocol` replies, as JSON.
fn sendJson(w: *Io.Writer, arena: Allocator, value: anytype) !void {
    return sendJsonStatus(w, arena, "200 OK", value);
}

fn sendJsonStatus(w: *Io.Writer, arena: Allocator, status: []const u8, value: anytype) !void {
    return sendResponse(w, status, "application/json", try protocol.allocWrite(arena, value));
}

/// The last few thousand bytes of `text`, starting at a character, for a
/// client that reads plain text.
fn plainTail(text: []const u8) []const u8 {
    const limit = 4000;
    if (text.len <= limit) return text;
    var start = text.len - limit;
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    return text[start..];
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

test plainTail {
    try std.testing.expectEqualStrings("short", plainTail("short"));
    var long: [6000]u8 = undefined;
    @memset(long[0..3000], 'a');
    for (0..1500) |k| @memcpy(long[3000 + 2 * k ..][0..2], "é");
    const tail = plainTail(&long);
    try std.testing.expect(tail.len <= 4000);
    try std.testing.expect(std.unicode.utf8ValidateSlice(tail));
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
    try std.testing.expectEqual(@as(?Group.Token, null), h.session());
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
