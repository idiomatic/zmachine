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

test "piped input stops at the end of the story" {
    const text = try run(testing.allocator, &.{0xba}, &.{"restart"});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("", text);
}
