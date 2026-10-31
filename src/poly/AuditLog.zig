//! The audit log: who sent commands, joined, led, kicked, changed the
//! password or looked at the inspector, and refused requests. The latest
//! thousand events are kept. Its owner locks it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const AuditLog = @This();

events: std.ArrayList(Event) = .empty,
next_seq: u64 = 1,

const max_events = 1000;

pub const Kind = enum {
    /// A command sent with `POST /command`.
    command,
    /// A line typed at the keyboard.
    keyboard,
    /// The object inspector page was opened.
    inspector,
    /// An inspector snapshot (object tree, attributes, globals) was read.
    snapshot,
    /// A request was refused.
    refused,
    /// A player joined or left.
    join,
    /// A remote player gave the password, rightly or wrongly.
    login,
    /// The leadership moved.
    leader,
    /// A player was kicked.
    kick,
    /// The password was changed, read or shown.
    password,
    /// An AI partner was let read the inspector, or stopped.
    access,
    /// The game restarted.
    game,
};

pub const Event = struct {
    seq: u64,
    time: i64,
    kind: Kind,
    suspicious: bool,
    client: []u8,
    /// The address it came from: "this machine", or a remote address.
    from: []u8,
    detail: []u8,
};

pub fn deinit(l: *AuditLog, gpa: Allocator) void {
    for (l.events.items) |e| freeEvent(gpa, e);
    l.events.deinit(gpa);
}

fn freeEvent(gpa: Allocator, e: Event) void {
    gpa.free(e.client);
    gpa.free(e.from);
    gpa.free(e.detail);
}

/// Records an event at `time`; one that can't be stored is dropped.
pub fn add(l: *AuditLog, gpa: Allocator, time: i64, kind: Kind, client: []const u8, from: []const u8, detail: []const u8, suspicious: bool) void {
    const client_copy = gpa.dupe(u8, client) catch return;
    const from_copy = gpa.dupe(u8, from) catch {
        gpa.free(client_copy);
        return;
    };
    const detail_copy = gpa.dupe(u8, detail) catch {
        gpa.free(client_copy);
        gpa.free(from_copy);
        return;
    };
    if (l.events.items.len >= max_events) freeEvent(gpa, l.events.orderedRemove(0));
    l.events.append(gpa, .{
        .seq = l.next_seq,
        .time = time,
        .kind = kind,
        .suspicious = suspicious,
        .client = client_copy,
        .from = from_copy,
        .detail = detail_copy,
    }) catch {
        freeEvent(gpa, .{ .seq = 0, .time = 0, .kind = kind, .suspicious = false, .client = client_copy, .from = from_copy, .detail = detail_copy });
        return;
    };
    l.next_seq += 1;
}

/// The sequence number of the latest event, or 0.
pub fn last(l: *const AuditLog) u64 {
    return l.next_seq - 1;
}
