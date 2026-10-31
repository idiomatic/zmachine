//! Console commands, typed at the keyboard with `--web` in place of a line
//! of input: `/lead`, `/password`, `/showpassword`, `/mode`, `/clear`,
//! `/help`, `/who`, `/promote`, `/kick`, `/grant`, `/revoke`, `/say`, `/log`
//! and `/invite`. The game never sees them.

const std = @import("std");

const Group = @import("poly").Group;
const Hub = @import("hub").Hub;
const Password = @import("poly").Password;
const Screen = @import("console").Screen;
const Server = @import("web").Server;

/// What the commands act on.
pub const Context = struct {
    group: *Group,
    server: *const Server,
};

/// The commands, for `Screen.commands`.
pub fn commands(context: *Context) Screen.Commands {
    return .{ .context = context, .run = run };
}

fn run(context: *anyopaque, s: *Screen, name: []const u8) Screen.Error!void {
    const c: *Context = @ptrCast(@alignCast(context));
    const g = c.group;
    const split = std.mem.indexOfAny(u8, name, " \t") orelse name.len;
    const command = std.meta.stringToEnum(Hub.ConsoleCommand, name[0..split]) orelse return;
    const args = std.mem.trim(u8, name[split..], " \t");
    const note: ?[]const u8 = switch (command) {
        .lead => if (g.leads(.console))
            "The console already leads."
        else if (g.passLeadership(.console, "console")) |_|
            "The console leads again."
        else |_|
            "Could not take back the leadership.",
        .password => try password(s, g),
        .showpassword => try showPassword(s, g),
        .mode => mode(g, args),
        .clear => clear(g),
        .help => try help(s),
        .who => try who(s, g),
        .promote => promote(g, args),
        .kick => kick(g, args),
        .grant => access(g, args, true),
        .revoke => access(g, args, false),
        .say => say(g, args),
        .log => try showLog(s, g, args),
        .invite => try invite(s, g, c.server),
    };
    if (note) |text| try s.note(text);
}

/// `/mode [debate|turns]`: shows or sets the mode. The console is on this
/// machine; it sets the mode only while the local side leads.
fn mode(g: *Group, args: []const u8) []const u8 {
    if (args.len == 0) return if (g.currentMode() == .debate)
        "Mode: debate (only the leader sends commands)."
    else
        "Mode: turns (anyone sends commands).";
    const wanted = std.meta.stringToEnum(Group.Mode, args) orelse return "Use /mode debate or /mode turns.";
    g.setMode(.console, wanted) catch return "Only the leader sets the mode; /lead takes the lead back.";
    return if (wanted == .debate) "Mode set to debate." else "Mode set to turns.";
}

/// `/clear`: clears the discussion, which has nothing to do with a restart.
fn clear(g: *Group) []const u8 {
    g.clearDiscussion(.console) catch return "Could not clear the discussion.";
    return "Discussion cleared.";
}

/// `/password`: asks for a new password without echoing it; an empty one
/// generates a new password.
fn password(s: *Screen, g: *Group) Screen.Error!?[]const u8 {
    if (!g.listening()) return "There is no password without --listen.";
    var buf: [Password.max_len + 1]u8 = undefined;
    const text = try s.readHidden("New password (Return to generate one): ", &buf);
    g.changePassword(.console, if (text.len > 0) text else null) catch |err| return switch (err) {
        error.NotAllowed => "That password is too long.",
        else => "Could not change the password.",
    };
    return if (text.len > 0)
        "Password changed. Remote players need the new one."
    else
        "New password made; type /showpassword to see it. Remote players need the new one.";
}

/// `/showpassword`: shows the password on the bottom row until a key is
/// pressed. The terminal has just echoed the command, so the cursor is on
/// a fresh line.
fn showPassword(s: *Screen, g: *Group) Screen.Error!?[]const u8 {
    if (!g.listening()) return "There is no password without --listen.";
    if (!s.ansi) return "The password shows only on a full-screen terminal; copy an invite link with ⚭ on the play page here.";
    var buf: [Password.max_len]u8 = undefined;
    const text = g.readPassword(.console, &buf, "showed") catch return "Could not read the password.";
    var line_buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, " Password: {s}   (press a key to hide it)", .{text}) catch text;
    try s.flashBottom(line);
    return null;
}

/// `/help`: the commands.
fn help(s: *Screen) Screen.Error!?[]const u8 {
    for ([_][]const u8{
        "/help  /who  /log [n]  /say <text>  /mode [debate|turns]  /clear",
        "/lead  /promote <name>  /kick <name>  /grant <name>  /revoke <name>",
        "/password  /showpassword  /invite",
    }) |line| try s.note(line);
    return null;
}

/// `/who`: the players, with what each is and may do.
fn who(s: *Screen, g: *Group) Screen.Error!?[]const u8 {
    var arena: std.heap.ArenaAllocator = .init(g.gpa);
    defer arena.deinit();
    const d = g.discussionSince(arena.allocator(), std.math.maxInt(u64)) catch return "Could not list the players.";
    var buf: [160]u8 = undefined;
    try s.note(std.fmt.bufPrint(&buf, "console{s}", .{if (std.mem.eql(u8, d.leader, "console")) " (leader)" else ""}) catch "console");
    for (d.players) |p| {
        const line = std.fmt.bufPrint(&buf, "{s}: {s}, {s}{s}{s}", .{
            p.name,
            if (p.ai) "AI partner" else "person",
            if (p.local) "local" else "remote",
            if (p.leader) ", leader" else "",
            if (p.inspector) ", reads the inspector" else "",
        }) catch p.name;
        try s.note(line);
    }
    return null;
}

/// `/promote <name>`: passes the lead; `/lead` takes it back.
fn promote(g: *Group, name: []const u8) []const u8 {
    if (name.len == 0) return "Use /promote <name>.";
    g.passLeadership(.console, name) catch |err| return switch (err) {
        error.NotLeader => "Only the leader passes the lead; /lead takes it back.",
        error.UnknownPlayer => "No such player; /who lists them.",
        else => "Could not pass the lead.",
    };
    return "Leadership passed.";
}

/// `/kick <name>`.
fn kick(g: *Group, name: []const u8) []const u8 {
    if (name.len == 0) return "Use /kick <name>.";
    g.kick(.console, name) catch |err| return switch (err) {
        error.NotLeader => "Only the leader kicks; /lead takes the lead back.",
        error.UnknownPlayer => "No such player; /who lists them.",
        error.CannotKick => "The console and local players cannot be kicked.",
        else => "Could not kick that player.",
    };
    return "Removed.";
}

/// `/grant <name>` and `/revoke <name>`: an AI partner's inspector access.
fn access(g: *Group, name: []const u8, grant: bool) []const u8 {
    if (name.len == 0) return if (grant) "Use /grant <name>." else "Use /revoke <name>.";
    g.setInspectorAccess(.console, name, grant) catch |err| return switch (err) {
        error.UnknownPlayer => "No such AI partner; /who lists the players.",
        else => "Could not change inspector access.",
    };
    return if (grant) "Inspector access granted." else "Inspector access revoked.";
}

/// `/say <text>`: a message from the console.
fn say(g: *Group, text: []const u8) []const u8 {
    if (text.len == 0) return "Use /say <text>.";
    g.post(.console, .message, text, &.{}) catch return "Could not post that.";
    return "Posted.";
}

/// `/log [n]`: the last n audit log lines (default 10).
fn showLog(s: *Screen, g: *Group, args: []const u8) Screen.Error!?[]const u8 {
    const n = if (args.len == 0) 10 else std.fmt.parseInt(u64, args, 10) catch return "Use /log [n].";
    var arena: std.heap.ArenaAllocator = .init(g.gpa);
    defer arena.deinit();
    const last = g.lastEvent();
    const reply = g.events(arena.allocator(), if (last > n) last - n else 0, false) catch return "Could not read the log.";
    if (reply.events.len == 0) return "The log is empty.";
    var buf: [320]u8 = undefined;
    for (reply.events) |e| {
        const line = std.fmt.bufPrint(&buf, "#{d} {s}{s} {s}: {s}", .{ e.seq, if (e.suspicious) "! " else "", e.kind, e.client, e.detail }) catch e.detail;
        try s.note(line);
    }
    return null;
}

/// `/invite`: shows the invite link on the bottom row until a key is
/// pressed; it carries the password, so it never reaches the scrollback.
fn invite(s: *Screen, g: *Group, server: *const Server) Screen.Error!?[]const u8 {
    if (!g.listening()) return "There is no password without --listen.";
    if (!s.ansi) return "The invite link shows only on a full-screen terminal; copy one with ⚭ on the play page here.";
    var pw: [Password.max_len]u8 = undefined;
    const password_text = g.readPassword(.console, &pw, "showed an invite link with") catch return "Could not read the password.";
    var link_buf: [256]u8 = undefined;
    const link = server.consoleInviteLink(&link_buf, password_text) orelse return "Could not tell this machine's address.";
    var line_buf: [320]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, " {s}   (press a key to hide it)", .{link}) catch link;
    try s.flashBottom(line);
    return null;
}
