//! Remote access, with `--listen`: the password remote players give, their
//! sessions, sessions ended by a kick (so their pages can say so), and the
//! limits on password guesses. Its owner locks it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Password = @import("Password.zig");
const World = @import("world.zig").World;

const Access = @This();

password: ?Password = null,
sessions: std.ArrayList(Session) = .empty,
kicked: std.ArrayList(Kicked) = .empty,
/// Wrong passwords by address, and the latest attempts overall.
failures: std.ArrayList(Failure) = .empty,
attempts: [max_attempts_per_second]i64 = @splat(0),
next_attempt: usize = 0,

const max_kicked = 64;
/// Password guesses: at most this many a second from everyone, and a
/// delay that doubles with each wrong guess from one address.
const max_attempts_per_second = 10;
const max_delay_ms = 60_000;

/// A session cookie's value.
pub const Token = [16]u8;

/// An address, for limiting password guesses.
pub const AddressKey = [16]u8;

pub const Session = struct {
    token: Token,
    /// The name chosen with `POST /join`.
    name: ?[]u8 = null,
};

const Kicked = struct {
    token: Token,
    /// Why the session ended, such as "Ana removed you from the game".
    why: []u8,
};

const Failure = struct {
    key: AddressKey,
    count: u32,
    /// No more guesses from this address until then, in milliseconds.
    until: i64,
};

pub fn deinit(a: *Access, gpa: Allocator) void {
    for (a.sessions.items) |s| if (s.name) |name| gpa.free(name);
    a.sessions.deinit(gpa);
    for (a.kicked.items) |k| gpa.free(k.why);
    a.kicked.deinit(gpa);
    a.failures.deinit(gpa);
}

pub const Login = union(enum) {
    ok: Token,
    wrong,
    /// Too many guesses; try again later.
    slow,
};

/// Checks a password guess from the address `key` at `time`, starting a
/// session if it is right.
pub fn login(a: *Access, gpa: Allocator, world: World, key: AddressKey, guess: []const u8) !Login {
    const password = a.password orelse return .wrong;
    const t = world.now();
    const oldest = a.attempts[a.next_attempt];
    if (t - oldest < 1000) return .slow;
    const failure = for (a.failures.items) |*f| {
        if (std.mem.eql(u8, &f.key, &key)) break f;
    } else null;
    if (failure) |f| if (t < f.until) return .slow;
    a.attempts[a.next_attempt] = t;
    a.next_attempt = (a.next_attempt + 1) % a.attempts.len;

    if (!password.matches(guess)) {
        if (failure) |f| {
            f.count += 1;
            f.until = t + @min(@as(i64, 1000) << @intCast(@min(f.count - 1, 16)), max_delay_ms);
        } else {
            try a.failures.append(gpa, .{ .key = key, .count = 1, .until = t + 1000 });
        }
        return .wrong;
    }
    if (failure) |f| f.until = 0;
    var token: Token = undefined;
    try world.random(&token);
    try a.sessions.append(gpa, .{ .token = token });
    return .{ .ok = token };
}

pub fn find(a: *Access, token: Token) ?*Session {
    for (a.sessions.items) |*s| if (std.crypto.timing_safe.eql(Token, s.token, token)) return s;
    return null;
}

pub const SessionState = union(enum) {
    none,
    /// Ended, by a kick or a new password; why is copied into the caller's
    /// buffer.
    ended: []const u8,
    /// A session, with the name it joined under, if any.
    valid: ?[]const u8,
};

/// Looks up a session cookie, copying any name into `buf`.
pub fn session(a: *Access, token: Token, buf: []u8) SessionState {
    if (a.find(token)) |s| {
        const name = s.name orelse return .{ .valid = null };
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return .{ .valid = buf[0..n] };
    }
    for (a.kicked.items) |k| {
        if (!std.crypto.timing_safe.eql(Token, k.token, token)) continue;
        const n = @min(k.why.len, buf.len);
        @memcpy(buf[0..n], k.why[0..n]);
        return .{ .ended = buf[0..n] };
    }
    return .none;
}

/// Whether a session has joined under `name`.
pub fn nameTaken(a: *const Access, name: []const u8) bool {
    for (a.sessions.items) |s| if (s.name) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// Ends session `i`, remembering why, and returns the name it had (the
/// caller frees it).
pub fn end(a: *Access, gpa: Allocator, i: usize, why: []const u8) ?[]u8 {
    const s = a.sessions.swapRemove(i);
    if (a.kicked.items.len >= max_kicked) gpa.free(a.kicked.orderedRemove(0).why);
    if (gpa.dupe(u8, why)) |why_copy| {
        a.kicked.append(gpa, .{ .token = s.token, .why = why_copy }) catch gpa.free(why_copy);
    } else |_| {}
    return s.name;
}
