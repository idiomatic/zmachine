//! Z-character strings (spec §3): decoding story text into ZSCII, encoding
//! words for dictionary lookup, and translating ZSCII to and from Unicode.

const std = @import("std");

pub const Alphabets = [3][26]u8;

/// Alphabet table used by versions 2 and later unless the story provides its
/// own. Positions 0 and 1 of A2 are never printed directly: z-char 6 in A2
/// starts a 10-bit ZSCII escape and z-char 7 is a newline.
pub const default_alphabets: Alphabets = .{
    "abcdefghijklmnopqrstuvwxyz".*,
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ".*,
    " \n0123456789.,!?_#'\"/\\-:()".*,
};

/// Version 1 has a different A2 row and no newline z-char.
pub const v1_alphabets: Alphabets = .{
    default_alphabets[0],
    default_alphabets[1],
    " 0123456789.,!?_#'\"/\\<-:()".*,
};

/// Loads the alphabet table appropriate for the story.
pub fn loadAlphabets(memory: []const u8, version: u8) Alphabets {
    if (version == 1) return v1_alphabets;
    if (version >= 5) {
        const addr = readWord(memory, 0x34);
        if (addr != 0 and addr + 78 <= memory.len) {
            var result: Alphabets = undefined;
            for (0..3) |row| {
                @memcpy(&result[row], memory[addr + row * 26 ..][0..26]);
            }
            // The escape and newline positions keep their special meaning.
            result[2][0] = ' ';
            result[2][1] = '\n';
            return result;
        }
    }
    return default_alphabets;
}

fn readWord(memory: []const u8, addr: usize) u16 {
    if (addr + 1 >= memory.len) return 0;
    return std.mem.readInt(u16, memory[addr..][0..2], .big);
}

pub const Decoder = struct {
    memory: []const u8,
    version: u8,
    /// Byte address of the abbreviations table (0 if none).
    abbreviations: usize,
    alphabets: *const Alphabets,

    /// Decodes the Z-string starting at `addr`, emitting each ZSCII code via
    /// `sink.emit(code)`. Returns the byte address just past the string.
    pub fn decode(d: Decoder, addr: usize, sink: anytype) !usize {
        return d.decodeInner(addr, sink, true);
    }

    fn decodeInner(d: Decoder, start: usize, sink: anytype, comptime allow_abbrev: bool) !usize {
        var addr = start;
        // Locked alphabet (only changes in versions 1 and 2).
        var lock: u8 = 0;
        // One-character shift, if any.
        var shift: ?u8 = null;
        // Pending abbreviation bank (1-3) or 0.
        var abbrev: u8 = 0;
        // ZSCII escape state: 0 = none, 1 = want high bits, 2 = want low bits.
        var escape: u8 = 0;
        var escape_high: u16 = 0;

        while (addr + 1 < d.memory.len) {
            const word = readWord(d.memory, addr);
            addr += 2;
            const zchars = [3]u8{
                @intCast((word >> 10) & 0x1f),
                @intCast((word >> 5) & 0x1f),
                @intCast(word & 0x1f),
            };
            for (zchars) |z| {
                if (escape == 1) {
                    escape_high = z;
                    escape = 2;
                    continue;
                }
                if (escape == 2) {
                    try sink.emit((escape_high << 5) | z);
                    escape = 0;
                    continue;
                }
                if (abbrev != 0) {
                    const index = 32 * @as(usize, abbrev - 1) + z;
                    abbrev = 0;
                    if (allow_abbrev and d.abbreviations != 0) {
                        const entry = @as(usize, readWord(d.memory, d.abbreviations + index * 2)) * 2;
                        _ = try d.decodeInner(entry, sink, false);
                    }
                    continue;
                }
                switch (z) {
                    0 => try sink.emit(' '),
                    1 => {
                        if (d.version == 1) {
                            try sink.emit(13);
                        } else {
                            abbrev = 1;
                        }
                    },
                    2, 3 => {
                        if (d.version >= 3) {
                            abbrev = z;
                        } else {
                            // 2 shifts "up" one alphabet, 3 shifts "down".
                            shift = (lock + z - 1) % 3;
                        }
                    },
                    4, 5 => {
                        if (d.version >= 3) {
                            shift = z - 3;
                        } else {
                            lock = (lock + z - 3) % 3;
                        }
                    },
                    else => {
                        const alphabet = shift orelse lock;
                        shift = null;
                        if (alphabet == 2 and z == 6) {
                            escape = 1;
                        } else if (alphabet == 2 and z == 7 and d.version != 1) {
                            try sink.emit(13);
                        } else {
                            try sink.emit(d.alphabets[alphabet][z - 6]);
                        }
                    },
                }
            }
            if (word & 0x8000 != 0) break;
        }
        return addr;
    }
};

/// Encodes `text` (lower-case ZSCII) as a dictionary word: two words in
/// versions 1-3, three words afterwards. Unused trailing words are zero.
pub fn encode(alphabets: *const Alphabets, version: u8, text: []const u8) [3]u16 {
    const max_zchars: usize = if (version <= 3) 6 else 9;
    var zchars: [9]u8 = @splat(5);
    var n: usize = 0;

    const push = struct {
        fn push(buf: *[9]u8, count: *usize, limit: usize, z: u8) void {
            if (count.* < limit) {
                buf[count.*] = z;
                count.* += 1;
            }
        }
    }.push;

    for (text) |c| {
        if (n >= max_zchars) break;
        if (std.mem.indexOfScalar(u8, &alphabets[0], c)) |i| {
            push(&zchars, &n, max_zchars, @intCast(i + 6));
        } else if (std.mem.indexOfScalar(u8, &alphabets[1], c)) |i| {
            push(&zchars, &n, max_zchars, if (version >= 3) 4 else 2);
            push(&zchars, &n, max_zchars, @intCast(i + 6));
        } else if (indexInA2(alphabets, version, c)) |i| {
            push(&zchars, &n, max_zchars, if (version >= 3) 5 else 3);
            push(&zchars, &n, max_zchars, @intCast(i + 6));
        } else {
            push(&zchars, &n, max_zchars, if (version >= 3) 5 else 3);
            push(&zchars, &n, max_zchars, 6);
            push(&zchars, &n, max_zchars, c >> 5);
            push(&zchars, &n, max_zchars, c & 0x1f);
        }
    }

    var result: [3]u16 = .{ 0, 0, 0 };
    const words = max_zchars / 3;
    for (0..words) |w| {
        result[w] = (@as(u16, zchars[w * 3]) << 10) |
            (@as(u16, zchars[w * 3 + 1]) << 5) |
            zchars[w * 3 + 2];
    }
    result[words - 1] |= 0x8000;
    return result;
}

fn indexInA2(alphabets: *const Alphabets, version: u8, c: u8) ?usize {
    // Skip the escape position (and the newline position from version 2 on).
    const first: usize = if (version == 1) 1 else 2;
    for (alphabets[2][first..], first..) |a, i| {
        if (a == c) return i;
    }
    return null;
}

/// Default translation of ZSCII codes 155-223 to Unicode (spec §3.8.5.3).
pub const default_unicode_table: [69]u21 = blk: {
    const text = "äöüÄÖÜß»«ëïÿËÏáéíóúýÁÉÍÓÚÝàèìòùÀÈÌÒÙâêîôûÂÊÎÔÛåÅøØãñõÃÑÕæÆçÇþðÞÐ£œŒ¡¿";
    @setEvalBranchQuota(10000);
    var table: [69]u21 = undefined;
    var it = std.unicode.Utf8View.initComptime(text).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) table[i] = cp;
    if (i != table.len) @compileError("unicode table length mismatch");
    break :blk table;
};

/// Maps ZSCII codes 155 and up to Unicode using either the story's own
/// translation table or the default one.
pub const UnicodeMap = struct {
    table: []const u21,
    custom: [256]u21 = undefined,

    pub fn load(map: *UnicodeMap, memory: []const u8, version: u8) void {
        map.table = &default_unicode_table;
        if (version < 5) return;
        const ext = readWord(memory, 0x36);
        if (ext == 0 or readWord(memory, ext) < 3) return;
        const addr = readWord(memory, ext + 6);
        if (addr == 0 or addr >= memory.len) return;
        const count: usize = @min(memory[addr], 97);
        for (0..count) |i| map.custom[i] = readWord(memory, addr + 1 + i * 2);
        map.table = map.custom[0..count];
    }

    pub fn toUnicode(map: *const UnicodeMap, zscii: u16) ?u21 {
        return switch (zscii) {
            0 => null,
            9 => '\t',
            11 => ' ',
            13 => '\n',
            32...126 => @intCast(zscii),
            155...251 => if (zscii - 155 < map.table.len) map.table[zscii - 155] else '?',
            else => null,
        };
    }

    pub fn fromUnicode(map: *const UnicodeMap, cp: u21) ?u8 {
        if (cp >= 32 and cp <= 126) return @intCast(cp);
        for (map.table, 0..) |t, i| {
            if (t == cp) return @intCast(155 + i);
        }
        return null;
    }
};

const TestSink = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn emit(s: *TestSink, c: u16) !void {
        s.buf[s.len] = @intCast(c);
        s.len += 1;
    }
};

test "encode and decode round trip" {
    const words = encode(&default_alphabets, 3, "mailbox");
    var memory: [4]u8 = undefined;
    std.mem.writeInt(u16, memory[0..2], words[0], .big);
    std.mem.writeInt(u16, memory[2..4], words[1], .big);
    var sink: TestSink = .{};
    const d: Decoder = .{
        .memory = &memory,
        .version = 3,
        .abbreviations = 0,
        .alphabets = &default_alphabets,
    };
    _ = try d.decode(0, &sink);
    try std.testing.expectEqualStrings("mailbo", sink.buf[0..sink.len]);
}
