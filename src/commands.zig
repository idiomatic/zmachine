//! Console commands, typed at the keyboard with `--web` in place of a line
//! of input: `/lead`, `/password` and `/showpassword`. The game never sees
//! them.

const std = @import("std");

const Group = @import("poly").Group;
const Hub = @import("hub").Hub;
const Password = @import("poly").Password;
const Screen = @import("console").Screen;

/// The commands, for `Screen.commands`, carried out on `group`.
pub fn commands(group: *Group) Screen.Commands {
    return .{ .context = group, .run = run };
}

fn run(context: *anyopaque, s: *Screen, name: []const u8) Screen.Error!void {
    const g: *Group = @ptrCast(@alignCast(context));
    const command = std.meta.stringToEnum(Hub.ConsoleCommand, name) orelse return;
    const note: ?[]const u8 = switch (command) {
        .lead => if (g.leads(.console))
            "The console already leads."
        else if (g.passLeadership(.console, "console")) |_|
            "The console leads again."
        else |_|
            "Could not take back the leadership.",
        .password => try password(s, g),
        .showpassword => try showPassword(s, g),
    };
    if (note) |text| try s.note(text);
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
