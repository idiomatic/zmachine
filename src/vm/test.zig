//! Tests that run tiny stories, assembled here, against a recording display.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Machine = @import("Machine.zig");
const RecordingDisplay = @import("RecordingDisplay.zig");
const Storage = @import("Storage.zig");

/// A version 5 story: 512 bytes, dynamic memory below 0x100, `code` at
/// 0x100, and a text buffer for `aread` at 0x80.
fn story(code: []const u8) [0x200]u8 {
    var s: [0x200]u8 = @splat(0);
    s[0x00] = 5;
    std.mem.writeInt(u16, s[0x04..0x06], 0x100, .big); // high memory
    std.mem.writeInt(u16, s[0x06..0x08], 0x100, .big); // initial PC
    std.mem.writeInt(u16, s[0x0c..0x0e], 0x40, .big); // globals
    std.mem.writeInt(u16, s[0x0e..0x10], 0x100, .big); // static memory
    std.mem.writeInt(u16, s[0x1a..0x1c], 0x200 / 4, .big); // length
    s[0x80] = 20; // text buffer: room for 20 characters
    @memcpy(s[0x100..][0..code.len], code);
    return s;
}

/// Runs `code` with `input`, returning what it printed.
fn run(gpa: Allocator, code: []const u8, input: []const []const u8) ![]u8 {
    const s = story(code);
    var display: RecordingDisplay = .init(gpa, input);
    defer display.deinit();
    var cwd: Storage.Cwd = .init(gpa, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(gpa, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    try m.run();
    return display.text.toOwnedSlice(gpa);
}

test "print, new_line and quit" {
    const text = try run(testing.allocator, &.{
        0xb2, 0xb5, 0xc5, // print "hi"
        0xbb, // new_line
        0xba, // quit
    }, &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hi\n", text);
}

test "je with fewer than two operands never branches" {
    const text = try run(testing.allocator, &.{
        0xc1, 0xff, 0xc5, // je ?(skip the next print)
        0xb2, 0xb5, 0xc5, // print "hi"
        0xc1, 0x7f, 0x05, 0xc5, // je 5 ?(skip the next print)
        0xb2, 0xb5, 0xc5, // print "hi"
        0xba, // quit
    }, &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hihi", text);
}

test "restore_undo keeps the transcript bit" {
    const s = story(&.{
        0xbe, 0x09, 0xff, 0x10, // save_undo -> g0
        0x41, 0x10, 0x02, 0xcc, // je g0 2 ?(after the quit below)
        0xe2, 0x57, 0x11, 0x00, 0x01, // storeb 0x11 0 1: transcript on
        0xbe, 0x0a, 0xff, 0x11, // restore_undo -> g1
        0xba, // quit
        0xba, // quit (after the undo)
    });
    var display: RecordingDisplay = .init(testing.allocator, &.{});
    defer display.deinit();
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    try m.run();
    try testing.expectEqual(1, m.memory[0x11] & 0x01);
}

test "erase_window -1 selects the lower window" {
    const s = story(&.{
        0xeb, 0x7f, 0x01, // set_window 1
        0xed, 0x3f, 0xff, 0xff, // erase_window -1
        0xba, // quit
    });
    var display: RecordingDisplay = .init(testing.allocator, &.{});
    defer display.deinit();
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    try m.run();
    try testing.expectEqual(0, m.window);
}

test "unknown and picture EXT opcodes don't halt" {
    const text = try run(testing.allocator, &.{
        0xbe, 0x1d, 0xff, // EXT:29, ignored
        0xbe, 0x80, 0xff, // EXT:128, ignored
        0xbe, 0x06, 0x5f, 0x01, 0x00, 0xc5, // picture_data 1 0 ?(skip the print): no pictures
        0xb2, 0xb5, 0xc5, // print "hi"
        0xbe, 0x05, 0x7f, 0x01, // draw_picture 1: nothing
        0xba, // quit
    }, &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hi", text);
}

test "check_unicode and print_unicode" {
    const text = try run(testing.allocator, &.{
        0xbe, 0x0c, 0x3f, 0x00, 0xe9, 0x00, // check_unicode U+00E9 -> sp: in the table
        0xe6, 0xbf, 0x00, // print_num sp
        0xbe, 0x0c, 0x3f, 0x26, 0x03, 0x00, // check_unicode U+2603 -> sp: printable only
        0xe6, 0xbf, 0x00, // print_num sp
        0xbe, 0x0c, 0x3f, 0x00, 0x07, 0x00, // check_unicode U+0007 -> sp: neither
        0xe6, 0xbf, 0x00, // print_num sp
        0xbe, 0x0b, 0x3f, 0x00, 0x07, // print_unicode U+0007: shown as ?
        0xba, // quit
    }, &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("310?", text);
}

test "aread stores lowercased input" {
    const text = try run(testing.allocator, &.{
        0xe4, 0x5f, 0x80, 0x00, 0x00, // aread 0x80 0 -> sp
        0x10, 0x80, 0x02, 0x00, // loadb 0x80 2 -> sp
        0xe5, 0xbf, 0x00, // print_char sp
        0xba, // quit
    }, &.{"Go"});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Go\ng", text);
}

test "the story ends when input does" {
    const text = try run(testing.allocator, &.{
        0xe4, 0x5f, 0x80, 0x00, 0x00, // aread 0x80 0 -> sp
        0xb2, 0xb5, 0xc5, // print "hi", never reached
        0xba, // quit
    }, &.{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
}

test "the header advertises the display" {
    const s = story(&.{0xba});
    var display: RecordingDisplay = .init(testing.allocator, &.{});
    defer display.deinit();
    display.width = 60;
    display.height = 30;
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    // No styles or colors without escape sequences.
    try testing.expectEqual(0, m.memory[0x01] & 0x0d);
    try testing.expectEqual(30, m.memory[0x20]);
    try testing.expectEqual(60, m.memory[0x21]);
}

test "runUntilInput stops before input, and at a step limit" {
    const s = story(&.{
        0xb2, 0xb5, 0xc5, // print "hi"
        0xbb, // new_line
        0xe4, 0x5f, 0x80, 0x00, 0x00, // aread 0x80 0 -> sp
        0x10, 0x80, 0x02, 0x00, // loadb 0x80 2 -> sp
        0xe5, 0xbf, 0x00, // print_char sp
        0x8c, 0xff, 0xff, // jump to itself
    });
    var display: RecordingDisplay = .init(testing.allocator, &.{"Go"});
    defer display.deinit();
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();

    try testing.expectEqual(Machine.Stop.limit, try m.runUntilInput(1));
    try testing.expectEqualStrings("hi", display.text.items);
    // Stopped before the read, which hasn't taken the line yet.
    try testing.expectEqual(Machine.Stop.input, try m.runUntilInput(100));
    try testing.expectEqual(0, display.next_input);
    try testing.expectEqual(0x104, m.pc);
    // Carrying on reads it first, then runs into the loop.
    try testing.expectEqual(Machine.Stop.limit, try m.runUntilInput(100));
    try testing.expectEqualStrings("hi\nGo\ng", display.text.items);
    try testing.expectEqual(0x110, m.pc);
}

test "runUntilInput runs to the end" {
    const s = story(&.{0xba}); // quit
    var display: RecordingDisplay = .init(testing.allocator, &.{});
    defer display.deinit();
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    try testing.expectEqual(Machine.Stop.ended, try m.runUntilInput(100));
    try testing.expectEqual(Machine.Stop.ended, try m.runUntilInput(100));
}

test "run ends at input end after quit, and at a typed quit" {
    const s = story(&.{0xba}); // quit
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    for ([_][]const []const u8{ &.{}, &.{ "nonsense", "QUIT" } }) |input| {
        var display: RecordingDisplay = .init(testing.allocator, input);
        defer display.deinit();
        display.interactive = true;
        const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
        defer m.deinit();
        try m.run();
        try testing.expect(m.finished);
        try testing.expectEqual(input.len, display.next_input);
    }
}

fn countRestart(context: *anyopaque) void {
    const n: *usize = @ptrCast(@alignCast(context));
    n.* += 1;
}

test "restart after the end runs the story again" {
    const s = story(&.{
        0xb2, 0xb5, 0xc5, // print "hi"
        0xba, // quit
    });
    var display: RecordingDisplay = .init(testing.allocator, &.{ "RESTART", "quit" });
    defer display.deinit();
    display.interactive = true;
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    var restarts: usize = 0;
    m.on_restart = .{ .context = &restarts, .call = countRestart };
    try m.run();
    const prompt = "\n[The game has ended. Type RESTART, RESTORE, or QUIT.]\n";
    try testing.expectEqual(1, restarts);
    try testing.expectEqualStrings("hi" ++ prompt ++ "RESTART\nhi" ++ prompt ++ "quit\n", display.text.items);
}

test "restart starts the generator again from the seed, in random mode" {
    const s = story(&.{
        0xe7, 0x7f, 0x64, 0x00, // random 100 -> sp
        0xe6, 0xbf, 0x00, // print_num sp
        0xe7, 0x3f, 0xff, 0xfb, 0x10, // random -5 -> g0 (predictable)
        0xba, // quit
    });
    var display: RecordingDisplay = .init(testing.allocator, &.{ "restart", "quit" });
    defer display.deinit();
    display.interactive = true;
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    m.seedRandom(1);
    try m.run();
    const prompt = "\n[The game has ended. Type RESTART, RESTORE, or QUIT.]\n";
    try testing.expectEqualStrings("47" ++ prompt ++ "restart\n47" ++ prompt ++ "quit\n", display.text.items);
}

test "SEED at the end sets the seed and asks again" {
    const s = story(&.{0xba});
    var display: RecordingDisplay = .init(testing.allocator, &.{ "seed 42", "SEED x", "SEED random", "quit" });
    defer display.deinit();
    display.interactive = true;
    var cwd: Storage.Cwd = .init(testing.allocator, testing.io);
    defer cwd.deinit();
    const m = try Machine.init(testing.allocator, testing.io, &s, display.display(), cwd.storage(), "test.qzl");
    defer m.deinit();
    try m.run();
    try testing.expect(m.seed_random);
    try testing.expect(m.user_seed == null);
    try testing.expect(std.mem.indexOf(u8, display.text.items, "[Seed set to 42.]") != null);
    try testing.expect(std.mem.indexOf(u8, display.text.items, "[SEED takes a number.]") != null);
    try testing.expect(std.mem.indexOf(u8, display.text.items, "[Seed is random.]") != null);
}

test "piped input stops at the end of the story" {
    const text = try run(testing.allocator, &.{0xba}, &.{"restart"});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
}
