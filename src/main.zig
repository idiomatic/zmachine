//! zmachine: a Z-machine interpreter for the terminal.

const std = @import("std");
const Io = std.Io;

const Inspector = @import("inspector").Inspector;
const inspector_routes = @import("inspector").routes;
const Machine = @import("vm").Machine;
const Storage = @import("vm").Storage;
const Password = @import("poly").Password;
const Group = @import("poly").Group;
const Hub = @import("hub").Hub;
const Screen = @import("console").Screen;
const commands = @import("commands.zig");
const TerminalInput = @import("console").TerminalInput;
const mcp = @import("mcp");
const terminal = @import("console").terminal;
const web = @import("web");
const build_options = @import("build_options");

const usage =
    \\Usage: zmachine [options] <story-file>
    \\
    \\Options:
    \\  -w, --web [port]   Serve the play page on http://127.0.0.1:<port>/
    \\                     (default 9675, ZORK on a phone keypad), so people
    \\                     and AI partners can play along, and the live
    \\                     object inspector and map on /inspector
    \\  --listen <address> Also let players on other machines join the game,
    \\                     with a password, on <address> (such as 0.0.0.0);
    \\                     implies --web. ZMACHINE_PASSWORD sets the
    \\                     password; otherwise three random words are used
    \\  --grant-inspector  Let every AI partner read the inspector (which
    \\                     shows hidden game state); implies --web. People
    \\                     on this machine can instead let one partner
    \\                     at a time, from its menu on the play page
    \\  --seed <n>         Seed the random number generator (the same
    \\                     generator as Frotz, so `dfrotz -s <n>` matches)
    \\  -t, --transcript <file>
    \\                     Write a transcript from the start of the story
    \\  --plain            Plain text output, without escape sequences
    \\  --style <list>     Choose how the display looks (see Styles); may be
    \\                     repeated, and ZMACHINE_STYLE is applied first
    \\  --mcp [port]       Run as an MCP server over stdio, so an AI partner
    \\                     can play the game served with `--web [port]`
    \\  -h, --help         Show this help
    \\  --version          Show the version
    \\
    \\Styles:
    \\  A comma-separated list of presets and <part>=<look> settings, applied
    \\  in order, such as `mono,prompt=bold+cyan`.
    \\  Presets: default, dark, light, mono (no colors), plain
    \\  Parts:   input, prompt, header (or status), more ([MORE]), and
    \\           currentinput and priorinput, laid over input for the
    \\           line being typed and for earlier lines
    \\  Looks:   attributes and a color joined by +, such as bold+white/blue
    \\           attributes: bold, dim, italic, underline, reverse, plain
    \\           color: fg, fg/bg or /bg, each a theme color (black, red,
    \\           green, yellow, blue, magenta, cyan, white, or bright-<name>),
    \\           a 256-color number, #rrggbb or default
    \\  Default: input=30,currentinput=bold,prompt=plain,
    \\           header=bold+231/24,more=reverse
    \\
;

/// The port `--web` and `--mcp` use when none is given: ZORK on a phone
/// keypad.
const default_port: u16 = 9675;

const Options = struct {
    story_path: []const u8,
    web_port: ?u16 = null,
    listen: ?[]const u8 = null,
    grant_inspector: bool = false,
    seed: ?u64 = null,
    transcript: ?[]const u8 = null,
    plain: bool = false,
    looks: Screen.Looks = .{},
    mcp_port: ?u16 = null,
};

const Command = union(enum) {
    run: Options,
    mcp: u16,
    usage,
    version,
};

/// Parses the command line. `style` is the value of `ZMACHINE_STYLE`, which
/// `--style` options add to.
fn parseArgs(args: []const []const u8, style: ?[]const u8) !Command {
    var story_path: ?[]const u8 = null;
    var options: Options = .{ .story_path = "" };
    if (style) |list| options.looks.apply(list) catch return error.InvalidZmachineStyle;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .usage;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--web")) {
            options.web_port = optionalPort(args, &i);
        } else if (std.mem.eql(u8, arg, "--listen")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            _ = std.Io.net.IpAddress.parse(args[i], 0) catch return error.InvalidListenAddress;
            options.listen = args[i];
        } else if (std.mem.eql(u8, arg, "--grant-inspector")) {
            options.grant_inspector = true;
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--transcript")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.transcript = args[i];
        } else if (std.mem.eql(u8, arg, "--mcp")) {
            options.mcp_port = optionalPort(args, &i);
        } else if (std.mem.eql(u8, arg, "--plain")) {
            options.plain = true;
        } else if (std.mem.eql(u8, arg, "--style")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            try options.looks.apply(args[i]);
        } else if (story_path == null and !std.mem.startsWith(u8, arg, "-")) {
            story_path = arg;
        } else {
            return error.InvalidArgument;
        }
    }
    if (options.mcp_port) |port| return .{ .mcp = port };
    if ((options.listen != null or options.grant_inspector) and options.web_port == null) options.web_port = default_port;
    options.story_path = story_path orelse return .usage;
    return .{ .run = options };
}

/// Takes the argument after `args[i.*]` as a port if it is a number, and
/// otherwise returns `default_port`.
fn optionalPort(args: []const []const u8, i: *usize) u16 {
    if (i.* + 1 < args.len) {
        if (std.fmt.parseInt(u16, args[i.* + 1], 10)) |port| {
            i.* += 1;
            return port;
        } else |_| {}
    }
    return default_port;
}

/// Default save file name: the story's base name with a .qzl extension.
fn saveName(arena: std.mem.Allocator, story_path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(story_path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    return std.fmt.allocPrint(arena, "{s}.qzl", .{stem});
}

/// The inspector's routes, for the web server.
fn inspectorRoutes(inspector: *Inspector) web.Routes {
    return .{
        .context = inspector,
        .paths = &inspector_routes.paths,
        .ai_path = inspector_routes.ai_path,
        .handle = handleInspector,
    };
}

fn handleInspector(context: *anyopaque, arena: std.mem.Allocator, method: []const u8, path: []const u8, query: []const u8) anyerror!?web.Answer {
    const reply = try inspector_routes.handle(@ptrCast(@alignCast(context)), arena, method, path, query) orelse return null;
    return .{
        .status = reply.status,
        .content_type = reply.content_type,
        .body = reply.body,
        .log = if (reply.log) |l| .{
            .kind = switch (l.kind) {
                .inspector => .inspector,
                .snapshot => .snapshot,
            },
            .detail = l.detail,
            .suspicious = l.suspicious,
        } else null,
    };
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const command = parseArgs(args, init.environ_map.get("ZMACHINE_STYLE")) catch |err| {
        try stderr.print("zmachine: {s}\n\n{s}", .{ @errorName(err), usage });
        try stderr.flush();
        return 2;
    };
    const options = switch (command) {
        .run => |options| options,
        .usage => {
            try stderr.writeAll(usage);
            try stderr.flush();
            return 2;
        },
        .version => {
            try Io.File.stdout().writeStreamingAll(io, "zmachine " ++ build_options.version ++ "\n");
            return 0;
        },
        .mcp => |port| {
            try mcp.run(gpa, io, port);
            return 0;
        },
    };

    const story = Io.Dir.cwd().readFileAlloc(io, options.story_path, gpa, .limited(1 << 20)) catch |err| {
        try stderr.print("zmachine: cannot read {s}: {s}\n", .{ options.story_path, @errorName(err) });
        try stderr.flush();
        return 1;
    };
    defer gpa.free(story);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buf);

    const tty_out = try Io.File.stdout().isTty(io);
    const tty_in = try Io.File.stdin().isTty(io);
    var hub: Hub = .init(gpa, io);
    defer hub.deinit();
    var group: Group = .init(gpa, io, .{ .real = io });
    defer group.deinit();
    var keyboard: TerminalInput = .{ .in = &stdin_reader.interface };
    var screen: Screen = .init(
        io,
        &stdout_writer.interface,
        if (options.web_port != null) hub.input() else keyboard.input(),
        story[0],
        tty_out and !options.plain,
        tty_in,
    );
    screen.looks = options.looks;

    var storage: Storage.Cwd = .init(gpa, io);
    defer storage.deinit();
    // With --web, the players there see what the game prints.
    const display = if (options.web_port != null) hub.display(screen.display()) else screen.display();
    const machine = Machine.init(gpa, io, story, display, storage.storage(), try saveName(arena, options.story_path)) catch |err| {
        try stderr.print("zmachine: cannot load {s}: {s}\n", .{ options.story_path, @errorName(err) });
        try stderr.flush();
        return 1;
    };
    defer machine.deinit();
    if (options.seed) |seed| machine.seedRandom(seed);
    if (options.transcript) |name| machine.startTranscript(name);

    var inspector: Inspector = .init(gpa, io);
    defer inspector.deinit();
    if (options.web_port) |port| {
        const server = try arena.create(web.Server);
        server.* = web.Server.listen(gpa, io, inspectorRoutes(&inspector), &hub, &group, port, options.listen) catch |err| {
            try stderr.print("zmachine: cannot listen on port {d}: {s}\n", .{ port, @errorName(err) });
            try stderr.flush();
            return 1;
        };
        const thread = try std.Thread.spawn(.{}, web.Server.serve, .{server});
        thread.detach();
        machine.observer = inspector.observer();
        try hub.startKeyboard();
        screen.commands = commands.commands(&group);
        try stderr.print("Play at http://127.0.0.1:{d}/ (the inspector is at /inspector)\n", .{port});
        if (options.grant_inspector) {
            group.grantInspectorToAll();
            try stderr.writeAll("AI partners may read the inspector (--grant-inspector).\n");
        }
        if (options.listen) |address| {
            // The password stays off the terminal; copy an invite link on
            // the play page on this machine, or type /showpassword.
            const env = init.environ_map.get("ZMACHINE_PASSWORD");
            const password = if (env) |text| Password.fromText(text) orelse {
                try stderr.writeAll("zmachine: ZMACHINE_PASSWORD is empty or longer than 64 characters\n");
                try stderr.flush();
                return 1;
            } else try Password.generate(group.world);
            group.setPassword(password);
            // An address such as 0.0.0.0 stands for all of this machine's.
            const any = std.mem.eql(u8, address, "0.0.0.0") or std.mem.eql(u8, address, "::");
            try stderr.print(
                "Players on other machines can join at http://{s}:{d}/ with the password {s}.\n" ++
                    "Copy an invite link with \u{26AD} on the play page on this machine, or type /showpassword.\n",
                .{
                    if (any) "<this machine's address>" else address,                      port,
                    if (env != null) "from ZMACHINE_PASSWORD" else "chosen for this game",
                },
            );
        }
        try stderr.flush();
    }

    if (screen.ansi) {
        // Windows consoles need escape-sequence processing switched on.
        Io.File.stdout().enableAnsiEscapeCodes(io) catch {};
        // Reset styles and the scroll region if interrupted.
        // Resetting the scroll region homes the cursor, so move it to the
        // bottom row (terminals clamp 999) as a normal exit does.
        terminal.restoreOnInterrupt("\x1b[0m\x1b[r\x1b[999;1H\r\n");
    }
    const result = if (screen.start()) machine.run() else |err| err;
    screen.finish() catch {};
    const status: u8 = if (result) 0 else |err| status: {
        // The reader went away (for example, a closed pipe).
        if (err == error.WriteFailed) break :status 0;
        try stderr.print("zmachine: {s} at pc 0x{x:0>5}\n", .{ @errorName(err), machine.instruction_pc });
        try stderr.flush();
        break :status 1;
    };
    if (options.web_port != null) {
        // The server and keyboard threads may still be using the inspector
        // and the remote state, so exit without freeing them. Closing the
        // machine flushes the transcript.
        machine.deinit();
        std.process.exit(status);
    }
    return status;
}

test "ports default to 9675" {
    const run = (try parseArgs(&.{ "zmachine", "--web", "zork1.z3" }, null)).run;
    try std.testing.expectEqual(9675, run.web_port.?);
    try std.testing.expectEqualStrings("zork1.z3", run.story_path);
    const given = (try parseArgs(&.{ "zmachine", "-w", "8080", "zork1.z3" }, null)).run;
    try std.testing.expectEqual(8080, given.web_port.?);
    try std.testing.expectEqual(9675, (try parseArgs(&.{ "zmachine", "--mcp" }, null)).mcp);
    try std.testing.expectEqual(1980, (try parseArgs(&.{ "zmachine", "--mcp", "1980" }, null)).mcp);
}
