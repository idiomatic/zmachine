//! Passwords for players who join from other machines (`--listen`): three
//! random words from the EFF short word list, such as `amber-otter-glide`.
//!
//! Three words from 1,296 give about 31 bits, which is enough because
//! wrong guesses are slowed down. Typing is forgiving: case, hyphens and
//! spaces don't matter.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

const World = @import("world.zig").World;

/// The EFF short word list (https://www.eff.org/dice), CC BY 3.0: one
/// `<dice>\t<word>` line per word.
const word_list = @embedFile("eff_short_wordlist_1.txt");
pub const word_count = 1296;
const words_per_password = 3;

pub const max_len = 64;

/// The password in the form people read and type.
text: [max_len]u8 = undefined,
len: usize = 0,

const Password = @This();

pub fn slice(p: *const Password) []const u8 {
    return p.text[0..p.len];
}

/// Makes a new password from the world's randomness: for real, the
/// operating system's secure random source.
pub fn generate(world: World) World.Error!Password {
    var p: Password = .{};
    var w: Io.Writer = .fixed(&p.text);
    for (0..words_per_password) |i| {
        if (i > 0) w.writeByte('-') catch unreachable;
        w.writeAll(word(try randomIndex(world))) catch unreachable;
    }
    p.len = w.buffered().len;
    return p;
}

/// A password someone chose, such as from `ZMACHINE_PASSWORD`, or null if
/// it is empty or too long.
pub fn fromText(text: []const u8) ?Password {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_len) return null;
    var p: Password = .{ .len = trimmed.len };
    @memcpy(p.text[0..trimmed.len], trimmed);
    return p;
}

/// Whether `guess` matches, ignoring case, hyphens and spaces. The
/// comparison takes the same time whatever the guess.
pub fn matches(p: *const Password, guess: []const u8) bool {
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest(p.slice()), digest(guess));
}

/// Hashes the letters that count: lowercase, without hyphens or spaces.
fn digest(text: []const u8) [Sha256.digest_length]u8 {
    var h: Sha256 = .init(.{});
    for (text) |c| {
        if (c == '-' or c == ' ' or c == '\t') continue;
        h.update(&.{std.ascii.toLower(c)});
    }
    return h.finalResult();
}

/// A uniformly random word index, without modulo bias.
fn randomIndex(world: World) World.Error!usize {
    const limit = std.math.maxInt(u16) / word_count * word_count;
    while (true) {
        var bytes: [2]u8 = undefined;
        try world.random(&bytes);
        const n = std.mem.readInt(u16, &bytes, .little);
        if (n < limit) return n % word_count;
    }
}

/// The word at `index` in the list.
fn word(index: usize) []const u8 {
    var lines = std.mem.tokenizeScalar(u8, word_list, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        if (i == index) {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return line;
            return std.mem.trimEnd(u8, line[tab + 1 ..], "\r");
        }
    }
    unreachable;
}

test "word list" {
    var lines = std.mem.tokenizeScalar(u8, word_list, '\n');
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    try std.testing.expectEqual(word_count, n);
    try std.testing.expectEqualStrings("acid", word(0));
    try std.testing.expectEqualStrings("zoom", word(word_count - 1));
}

test "generate and match" {
    var fake: World.Fake = .{};
    const p = try generate(.{ .fake = &fake });
    var parts = std.mem.splitScalar(u8, p.slice(), '-');
    var count: usize = 0;
    while (parts.next()) |_| count += 1;
    // "yo-yo" is the one word with a hyphen of its own.
    try std.testing.expect(count >= 3 and count <= 6);
    try std.testing.expect(p.matches(p.slice()));

    const chosen = fromText("Amber-Otter-Glide").?;
    try std.testing.expect(chosen.matches("amber otter glide"));
    try std.testing.expect(chosen.matches("AMBEROTTERGLIDE"));
    try std.testing.expect(!chosen.matches("amber otter"));
    try std.testing.expectEqual(@as(?Password, null), fromText("   "));
}
