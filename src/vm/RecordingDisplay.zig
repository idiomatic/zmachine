//! A display for tests: records the lower window's text and answers input
//! from a script.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Display = @import("Display.zig");

const RecordingDisplay = @This();

gpa: Allocator,
/// What the game printed in the lower window.
text: std.ArrayList(u8) = .empty,
/// Lines of input, read in turn; then input ends.
input: []const []const u8,
next_input: usize = 0,
window: u8 = 0,
status: [2][]const u8 = .{ "", "" },
width: u16 = 80,
height: u16 = 24,

pub fn init(gpa: Allocator, input: []const []const u8) RecordingDisplay {
    return .{ .gpa = gpa, .input = input };
}

pub fn deinit(r: *RecordingDisplay) void {
    r.text.deinit(r.gpa);
}

pub fn display(r: *RecordingDisplay) Display {
    return .from(r);
}

pub fn print(r: *RecordingDisplay, cp: u21) !void {
    if (r.window != 0) return;
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &utf8) catch return;
    try r.text.appendSlice(r.gpa, utf8[0..n]);
}

pub fn setWindow(r: *RecordingDisplay, window: u8) !void {
    r.window = window;
}

pub fn splitWindow(_: *RecordingDisplay, _: u16) !void {}

pub fn eraseWindow(_: *RecordingDisplay, _: i16) !void {}

pub fn eraseLine(_: *RecordingDisplay) !void {}

pub fn setCursor(_: *RecordingDisplay, _: u16, _: u16) !void {}

pub fn getCursor(_: *RecordingDisplay) [2]u16 {
    return .{ 1, 1 };
}

pub fn setStyle(_: *RecordingDisplay, _: u8) !void {}

pub fn setColor(_: *RecordingDisplay, _: u16, _: u16) !void {}

pub fn setBuffered(_: *RecordingDisplay, _: bool) !void {}

/// Keeps only the latest status line; the strings are valid until the
/// next call.
pub fn drawStatus(r: *RecordingDisplay, left: []const u8, right: []const u8) !void {
    r.status = .{ left, right };
}

/// Echoes the line, as piped input is.
pub fn readLine(r: *RecordingDisplay, buf: []u8) !?[]u8 {
    if (r.next_input == r.input.len) return null;
    const line = r.input[r.next_input];
    r.next_input += 1;
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    try r.text.appendSlice(r.gpa, buf[0..n]);
    try r.text.append(r.gpa, '\n');
    return buf[0..n];
}

/// The first character of the next line, or Return for an empty one.
pub fn readKey(r: *RecordingDisplay) !?u8 {
    if (r.next_input == r.input.len) return null;
    const line = r.input[r.next_input];
    r.next_input += 1;
    return if (line.len == 0) 13 else line[0];
}

pub fn capabilities(r: *RecordingDisplay) Display.Capabilities {
    return .{ .styles = false, .width = r.width, .height = r.height };
}
