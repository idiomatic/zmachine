//! Input read straight from standard input (or any reader), without the
//! web: it blocks until input arrives.

const std = @import("std");
const Io = std.Io;

const InputSource = @import("InputSource.zig");
const terminal = @import("terminal.zig");

const TerminalInput = @This();

in: *Io.Reader,

pub fn input(t: *TerminalInput) InputSource {
    return .{ .context = t, .vtable = &.{
        .waiting = waiting,
        .takeLine = takeLine,
        .takeKey = takeKey,
        .keyboardPending = keyboardPending,
        .takeKeyboardByte = takeKeyboardByte,
        .webPending = webPending,
    } };
}

fn cast(context: *anyopaque) *TerminalInput {
    return @ptrCast(@alignCast(context));
}

fn waiting(_: *anyopaque) void {}

/// The next line, without its line ending, or null at the end.
fn readLine(t: *TerminalInput, buf: []u8) InputSource.Error!?[]u8 {
    const raw = t.in.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => t.in.buffered(),
        else => return error.ReadFailed,
    };
    const line = std.mem.trimEnd(u8, raw orelse return null, "\r");
    const n = @min(line.len, buf.len);
    @memcpy(buf[0..n], line[0..n]);
    return buf[0..n];
}

fn takeLine(context: *anyopaque, buf: []u8) InputSource.Error!InputSource.Line {
    const line = try readLine(cast(context), buf) orelse return .closed;
    return .{ .keyboard = line };
}

fn takeKey(context: *anyopaque, buf: []u8, by_line: bool, _: bool) InputSource.Error!InputSource.Key {
    const t = cast(context);
    if (by_line) return .{ .line = try readLine(t, buf) orelse return .closed };
    const c = t.in.takeByte() catch |err| return switch (err) {
        error.EndOfStream => .closed,
        else => error.ReadFailed,
    };
    return .{ .key = c };
}

fn keyboardPending(context: *anyopaque) bool {
    return cast(context).in.bufferedLen() > 0 or terminal.inputPending();
}

fn takeKeyboardByte(context: *anyopaque) ?u8 {
    return cast(context).in.takeByte() catch null;
}

fn webPending(_: *anyopaque) bool {
    return false;
}
