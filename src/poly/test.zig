//! Tests of the rules of playing together, on a fake clock.

const std = @import("std");
const testing = std.testing;

const Group = @import("Group.zig");
const Password = @import("Password.zig");
const World = @import("world.zig").World;
const protocol = @import("protocol");

const Player = Group.Player;

const claude: Player = .{ .name = "Claude", .ai = true, .local = false };
const ana: Player = .{ .name = "Ana", .local = true };
const bo: Player = .{ .name = "Bo", .local = false };

/// The discussion after `since`, as `/discussion` writes it.
fn discussion(g: *Group, since: u64) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return protocol.allocWrite(testing.allocator, try g.discussionSince(arena.allocator(), since));
}

test "debate mode and discussion" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();

    try testing.expectEqual(Group.Mode.debate, g.mode);
    g.mode = .turns;
    try g.setMode(.console, .debate);
    try testing.expect(!g.maySend(claude) and g.maySend(.console));
    try testing.expectError(error.NotLeader, g.setMode(claude, .turns));
    fake.advance(1000);
    try g.post(claude, .thought, "The mailbox might hold a clue.", &.{ "open mailbox", "north" });
    try testing.expectError(error.InvalidPost, g.post(.{ .name = "Gemini", .ai = true, .local = false }, .thought, "", &.{"a\tb"}));
    try testing.expectError(error.InvalidPost, g.post(claude, .command, "north", &.{}));
    g.heard(.{ .local = false }, "open mailbox", false);

    const json = try discussion(&g, 1);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        "{\"last\":3,\"mode\":\"debate\",\"inspector_for_all\":false,\"leader\":\"console\",\"players\":[],\"posts\":[" ++
            "{\"seq\":2,\"time\":1700000001000,\"ai\":true,\"author\":\"Claude\",\"kind\":\"thought\",\"text\":\"The mailbox might hold a clue.\",\"suggestions\":[\"open mailbox\",\"north\"]}," ++
            "{\"seq\":3,\"time\":1700000001000,\"ai\":false,\"author\":\"console\",\"kind\":\"command\",\"text\":\"open mailbox\",\"suggestions\":[]}]}",
        json,
    );

    try testing.expect(Group.validName("Claude"));
    try testing.expect(Group.validName("GPT-5 (scout)"));
    try testing.expect(!Group.validName("You"));
    try testing.expect(!Group.validName("Console"));
    try testing.expect(!Group.validName(""));
    try testing.expect(!Group.validName("a\tb"));
}

test "only this machine clears the discussion" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();

    try g.post(claude, .thought, "Hello.", &.{});
    try testing.expectError(error.NotAllowed, g.clearDiscussion(claude));
    try testing.expectError(error.NotAllowed, g.clearDiscussion(bo));
    try g.clearDiscussion(.console);
    try g.post(claude, .message, "Again.", &.{});
    const json = try discussion(&g, 0);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "Hello.") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"cleared\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Again.") != null);
}

test "a restart is posted and logged under who confirmed it" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    g.heard(claude, "restart", false);
    g.heard(claude, "y", false);
    g.restarted();
    const posts = g.discussion.posts.items;
    try testing.expectEqual(Group.PostKind.restarted, posts[posts.len - 1].kind);
    try testing.expectEqualStrings("Claude", posts[posts.len - 1].author.?);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const log = try g.events(arena.allocator(), 0, true);
    try testing.expectEqualStrings("game", log.events[log.events.len - 1].kind);
    try testing.expectEqualStrings("Claude", log.events[log.events.len - 1].client);
    // From the console, the console takes it.
    g.heard(.console, "y", true);
    g.restarted();
    try testing.expect(g.discussion.posts.items[g.discussion.posts.items.len - 1].author == null);
}

test "keyboard lines are logged; web commands only posted" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    g.heard(.console, "look", true);
    g.heard(claude, "north", false);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const log = try g.events(arena.allocator(), 0, true);
    try testing.expectEqual(1, log.last);
    try testing.expectEqualStrings("keyboard", log.events[0].kind);
    try testing.expectEqualStrings("look", log.events[0].detail);
    try testing.expectEqual(2, g.lastPost());
}

test "events show a remote address only to clients on this machine" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    g.logFrom(.command, "ana via curl", Group.local_address, "look", false);
    g.logFrom(.refused, "curl", "203.0.113.9", "GET /x", true);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const local = try g.events(arena.allocator(), 0, true);
    try testing.expectEqualStrings("this machine", local.events[0].from);
    try testing.expectEqualStrings("203.0.113.9", local.events[1].from);
    const others = try g.events(arena.allocator(), 0, false);
    try testing.expectEqualStrings("this machine", others.events[0].from);
    try testing.expectEqualStrings("remote", others.events[1].from);
}

test "leadership and kicks" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();

    try g.touch(ana);
    try g.touch(claude);
    try g.touch(bo);
    try testing.expectError(error.NameTaken, g.touch(.{ .name = "ana", .local = false }));
    // The local side leads, every local client a coleader.
    try testing.expect(g.leads(ana) and g.leads(.console) and !g.leads(bo));

    try g.passLeadership(ana, "Claude");
    try testing.expect(g.leads(claude) and !g.leads(ana));
    try testing.expectError(error.NotLeader, g.passLeadership(bo, "Bo"));
    // An AI leader can kick, but not the local side.
    try testing.expectError(error.CannotKick, g.kick(claude, "Ana"));
    try g.kick(claude, "Bo");
    try testing.expect(g.players.find("Bo") == null);
    // The local side takes it back, and a kicked AI partner stays out.
    try g.passLeadership(.console, "console");
    try g.kick(ana, "Claude");
    try testing.expectError(error.Kicked, g.touch(claude));
    try testing.expect(g.leads(ana));
}

test "inspector access" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    try g.touch(ana);
    try g.touch(bo);
    try g.touch(claude);

    // AI partners need a grant; people are checked by address instead.
    try testing.expect(!g.mayInspect(claude) and g.mayInspect(ana));
    // Only a person on this machine grants it, and only to an AI partner.
    try testing.expectError(error.NotAllowed, g.setInspectorAccess(bo, "Claude", true));
    try testing.expectError(error.NotAllowed, g.setInspectorAccess(claude, "Claude", true));
    try testing.expectError(error.UnknownPlayer, g.setInspectorAccess(ana, "Bo", true));
    try g.setInspectorAccess(ana, "claude", true);
    try testing.expect(g.mayInspect(claude));
    const posts = g.discussion.posts.items;
    try testing.expectEqual(Group.PostKind.granted, posts[posts.len - 1].kind);
    try g.setInspectorAccess(.console, "Claude", false);
    try testing.expect(!g.mayInspect(claude));
    // A kick drops the grant along with the partner.
    try g.setInspectorAccess(ana, "Claude", true);
    try g.kick(ana, "Claude");
    try testing.expectEqual(0, g.players.inspector_grants.items.len);
    // --grant-inspector lets every AI partner.
    g.grantInspectorToAll();
    try testing.expect(g.mayInspect(.{ .name = "Gemini", .ai = true, .local = false }));
}

test "first remote person leads with nobody local" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    const cy: Player = .{ .name = "Cy", .local = false };
    try g.touch(bo);
    try g.touch(cy);
    try testing.expect(g.leads(bo));
    // The console can always reclaim it.
    try g.passLeadership(.console, "console");
    try testing.expect(g.leads(.console));
    try g.passLeadership(.console, "Cy");
    try testing.expect(g.leads(cy));
    // When the leader goes quiet for a minute, the earliest remaining
    // player leads.
    fake.advance(30_000);
    try g.touch(bo);
    fake.advance(30_000);
    try testing.expect(g.leads(bo));
    try testing.expect(g.players.find("Cy") == null);
}

test "people leave after a minute, AI partners after ten" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    try g.touch(ana);
    try g.touch(claude);
    fake.advance(59_999);
    _ = g.leads(.console);
    try testing.expectEqual(2, g.players.members.items.len);
    fake.advance(1);
    _ = g.leads(.console);
    try testing.expectEqual(1, g.players.members.items.len);
    fake.advance(9 * 60_000 - 1);
    _ = g.leads(.console);
    try testing.expectEqual(1, g.players.members.items.len);
    fake.advance(1);
    _ = g.leads(.console);
    try testing.expectEqual(0, g.players.members.items.len);
    const posts = g.discussion.posts.items;
    try testing.expectEqual(Group.PostKind.left, posts[posts.len - 1].kind);
}

test "password and sessions" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    g.setPassword(Password.fromText("amber-otter-glide").?);
    const key: Group.AddressKey = @splat(7);

    try testing.expectEqual(Group.Login.wrong, try g.login(key, "test", "", "amber"));
    // A second guess straight away is too soon.
    try testing.expectEqual(Group.Login.slow, try g.login(key, "test", "", "amber otter glide"));
    fake.advance(1000);
    const token = (try g.login(key, "test", "", "Amber Otter Glide")).ok;

    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), g.session(token, &buf).valid);
    try g.joinSession(token, "Bo");
    try testing.expectEqualStrings("Bo", g.session(token, &buf).valid.?);

    var pw: [Password.max_len]u8 = undefined;
    try testing.expect(g.leads(bo));
    try testing.expectEqualStrings("amber-otter-glide", try g.readPassword(bo, &pw, "copied"));
    try testing.expectError(error.NotAllowed, g.readPassword(claude, &pw, "copied"));

    // A new password ends every remote session but the leader's.
    try g.passLeadership(.console, "console");
    try g.changePassword(.console, "new words here");
    try testing.expectEqualStrings("console changed the password", g.session(token, &buf).ended);
    try testing.expect(g.access.password.?.matches("newwordshere"));
    // A generated one comes from the world's randomness, after the
    // session token's.
    try g.changePassword(.console, null);
    var again: World.Fake = .{};
    var skipped: Group.Token = undefined;
    try (World{ .fake = &again }).random(&skipped);
    try testing.expectEqualStrings((try Password.generate(.{ .fake = &again })).slice(), g.access.password.?.slice());
}

test "wrong guesses double the wait" {
    var fake: World.Fake = .{};
    var g: Group = .init(testing.allocator, testing.io, .{ .fake = &fake });
    defer g.deinit();
    g.setPassword(Password.fromText("amber-otter-glide").?);
    const key: Group.AddressKey = @splat(9);
    // Waits of one, two and four seconds after each wrong guess.
    for ([_]i64{ 1000, 2000, 4000 }) |wait| {
        try testing.expectEqual(Group.Login.wrong, try g.login(key, "test", "", "nope"));
        fake.advance(wait - 1);
        try testing.expectEqual(Group.Login.slow, try g.login(key, "test", "", "nope"));
        fake.advance(1);
    }
    // Another address isn't slowed.
    try testing.expectEqual(Group.Login.wrong, try g.login(@splat(1), "test", "", "nope"));
}
