//! The time and randomness the rules see: the real ones, or a test's,
//! which only change when the test says.

const std = @import("std");
const Io = std.Io;

pub const World = union(enum) {
    real: Io,
    fake: *Fake,

    pub const Error = error{EntropyUnavailable};

    /// A clock that moves only when told, and repeatable randomness.
    pub const Fake = struct {
        ms: i64 = 1_700_000_000_000,
        prng: std.Random.DefaultPrng = .init(1),

        pub fn advance(f: *Fake, ms: i64) void {
            f.ms += ms;
        }
    };

    /// The time, in milliseconds since the epoch.
    pub fn now(w: World) i64 {
        return switch (w) {
            .real => |io| Io.Timestamp.now(io, .real).toMilliseconds(),
            .fake => |f| f.ms,
        };
    }

    /// Fills `buf` with random bytes, from the operating system's secure
    /// source for real.
    pub fn random(w: World, buf: []u8) Error!void {
        switch (w) {
            .real => |io| io.randomSecure(buf) catch return error.EntropyUnavailable,
            .fake => |f| f.prng.random().bytes(buf),
        }
    }
};
