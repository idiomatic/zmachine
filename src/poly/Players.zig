//! The players: people on the play page and AI partners, who leads them,
//! the AI partners kicked out, and who may read the inspector. Its owner
//! locks it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Players = @This();

/// In the order they joined.
members: std.ArrayList(Member) = .empty,
next_order: u64 = 1,
/// Who leads: a remote person or AI partner by name, or null for the local
/// side (the console and local play-page clients, all coleaders).
leader: ?[]u8 = null,
/// AI partners kicked out, refused from then on.
banned: std.ArrayList([]u8) = .empty,
/// Whether every AI partner may read the inspector (`--grant-inspector`),
/// and the AI partners a person on this machine let read it.
inspector_for_all: bool = false,
inspector_grants: std.ArrayList([]u8) = .empty,

/// Who sent something.
pub const Player = struct {
    /// The person's or AI partner's name, or null for the console or a
    /// local client that gives none.
    name: ?[]const u8 = null,
    ai: bool = false,
    /// On this machine. The console and local play-page clients are local;
    /// AI partners never count as local.
    local: bool = true,

    pub const console: Player = .{};
};

pub const Member = struct {
    name: []u8,
    ai: bool,
    local: bool,
    /// Join order, for choosing a new leader.
    order: u64,
    /// When the member was last heard from, in milliseconds.
    seen: i64,

    pub fn player(m: Member) Player {
        return .{ .name = m.name, .ai = m.ai, .local = m.local };
    }
};

pub fn deinit(p: *Players, gpa: Allocator) void {
    for (p.members.items) |m| gpa.free(m.name);
    p.members.deinit(gpa);
    if (p.leader) |name| gpa.free(name);
    for (p.banned.items) |name| gpa.free(name);
    p.banned.deinit(gpa);
    for (p.inspector_grants.items) |name| gpa.free(name);
    p.inspector_grants.deinit(gpa);
}

pub fn find(p: *const Players, name: []const u8) ?usize {
    for (p.members.items, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m.name, name)) return i;
    return null;
}

pub fn anyLocalPerson(p: *const Players) bool {
    for (p.members.items) |m| if (m.local and !m.ai) return true;
    return false;
}

pub fn isBanned(p: *const Players, name: []const u8) bool {
    for (p.banned.items) |b| if (std.ascii.eqlIgnoreCase(b, name)) return true;
    return false;
}

/// Whether `who` leads: the named remote person or AI partner, or anyone
/// on the local side when it leads.
pub fn leads(p: *const Players, who: Player) bool {
    if (p.leader) |name| {
        const n = who.name orelse return false;
        return !who.local and std.ascii.eqlIgnoreCase(name, n);
    }
    return who.local and !who.ai;
}

/// Whether the AI partner `name` may read the inspector.
pub fn mayInspect(p: *const Players, name: []const u8) bool {
    return p.inspector_for_all or p.granted(name);
}

pub fn granted(p: *const Players, name: []const u8) bool {
    for (p.inspector_grants.items) |g| if (std.ascii.eqlIgnoreCase(g, name)) return true;
    return false;
}

pub fn dropGrant(p: *Players, gpa: Allocator, name: []const u8) void {
    for (p.inspector_grants.items, 0..) |g, i| if (std.ascii.eqlIgnoreCase(g, name)) {
        gpa.free(p.inspector_grants.orderedRemove(i));
        return;
    };
}

pub const validName = @import("protocol").validName;
