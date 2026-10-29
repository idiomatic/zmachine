//! Quetzal save files (IFF "IFZS" forms), the standard portable format for
//! saved Z-machine games.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Frame = struct {
    return_pc: u32,
    /// Variable to receive the return value, or null to discard it.
    store: ?u8,
    locals: [15]u16,
    local_count: u8,
    arg_count: u8,
    /// Index into the evaluation stack where this frame's values begin.
    stack_base: u32,
};

pub const State = struct {
    /// Dynamic memory.
    memory: []u8,
    /// Original story file, used to compress memory.
    story: []const u8,
    frames: []Frame,
    stack: []u16,
    pc: u32,
};

pub const Error = error{ InvalidSaveFile, WrongStory, StackOverflow } || Allocator.Error;

fn putWord(list: *std.ArrayList(u8), gpa: Allocator, value: u16) Allocator.Error!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .big);
    try list.appendSlice(gpa, &bytes);
}

fn putLong(list: *std.ArrayList(u8), gpa: Allocator, value: u32) Allocator.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try list.appendSlice(gpa, &bytes);
}

fn putPc(list: *std.ArrayList(u8), gpa: Allocator, pc: u32) Allocator.Error!void {
    try list.appendSlice(gpa, &.{ @truncate(pc >> 16), @truncate(pc >> 8), @truncate(pc) });
}

fn beginChunk(list: *std.ArrayList(u8), gpa: Allocator, id: *const [4]u8) Allocator.Error!usize {
    try list.appendSlice(gpa, id);
    try putLong(list, gpa, 0);
    return list.items.len;
}

fn endChunk(list: *std.ArrayList(u8), gpa: Allocator, start: usize) Allocator.Error!void {
    const len: u32 = @intCast(list.items.len - start);
    std.mem.writeInt(u32, list.items[start - 4 ..][0..4], len, .big);
    if (len % 2 == 1) try list.append(gpa, 0);
}

/// Serializes the machine state. Caller owns the returned bytes.
pub fn write(gpa: Allocator, state: State) Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    try list.appendSlice(gpa, "FORM");
    try putLong(&list, gpa, 0);
    try list.appendSlice(gpa, "IFZS");

    const header = state.story;
    var start = try beginChunk(&list, gpa, "IFhd");
    try list.appendSlice(gpa, header[0x02..0x04]);
    try list.appendSlice(gpa, header[0x12..0x18]);
    try list.appendSlice(gpa, header[0x1c..0x1e]);
    try putPc(&list, gpa, state.pc);
    try endChunk(&list, gpa, start);

    // CMem: XOR against the original, with runs of zeros compressed.
    start = try beginChunk(&list, gpa, "CMem");
    var i: usize = 0;
    while (i < state.memory.len) {
        const b = state.memory[i] ^ state.story[i];
        if (b != 0) {
            try list.append(gpa, b);
            i += 1;
            continue;
        }
        var run: usize = 0;
        while (i < state.memory.len and state.memory[i] == state.story[i] and run < 256) {
            run += 1;
            i += 1;
        }
        // Trailing zeros may be omitted.
        if (i == state.memory.len) break;
        try list.appendSlice(gpa, &.{ 0, @intCast(run - 1) });
    }
    try endChunk(&list, gpa, start);

    start = try beginChunk(&list, gpa, "Stks");
    for (state.frames, 0..) |frame, index| {
        const stack_end = if (index + 1 < state.frames.len) state.frames[index + 1].stack_base else state.stack.len;
        const values = state.stack[frame.stack_base..stack_end];
        try putPc(&list, gpa, frame.return_pc);
        try list.append(gpa, frame.local_count | @as(u8, if (frame.store == null) 0x10 else 0));
        try list.append(gpa, frame.store orelse 0);
        const args: u8 = @intCast((@as(u16, 1) << @intCast(frame.arg_count)) - 1);
        try list.append(gpa, args);
        try putWord(&list, gpa, @intCast(values.len));
        for (frame.locals[0..frame.local_count]) |local| try putWord(&list, gpa, local);
        for (values) |value| try putWord(&list, gpa, value);
    }
    try endChunk(&list, gpa, start);

    std.mem.writeInt(u32, list.items[4..8], @intCast(list.items.len - 8), .big);
    return list.toOwnedSlice(gpa);
}

pub const Restored = struct {
    pc: u32,
    frame_count: usize,
    stack_len: usize,
};

/// Restores `data` into the buffers of `state`, whose `frames` and `stack`
/// slices give the available capacity.
pub fn read(data: []const u8, state: State) Error!Restored {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "FORM") or !std.mem.eql(u8, data[8..12], "IFZS")) {
        return error.InvalidSaveFile;
    }
    const form_len = std.mem.readInt(u32, data[4..8], .big);
    const end = @min(data.len, @as(usize, form_len) + 8);

    var pc: ?u32 = null;
    var have_memory = false;
    var frame_count: usize = 0;
    var stack_len: usize = 0;

    var pos: usize = 12;
    while (pos + 8 <= end) {
        const id = data[pos..][0..4];
        const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
        const body_start = pos + 8;
        if (body_start + len > end) return error.InvalidSaveFile;
        const body = data[body_start..][0..len];
        pos = body_start + len + (len % 2);

        if (std.mem.eql(u8, id, "IFhd")) {
            if (body.len < 13) return error.InvalidSaveFile;
            const header = state.story;
            if (!std.mem.eql(u8, body[0..2], header[0x02..0x04]) or
                !std.mem.eql(u8, body[2..8], header[0x12..0x18]) or
                !std.mem.eql(u8, body[8..10], header[0x1c..0x1e]))
            {
                return error.WrongStory;
            }
            pc = (@as(u32, body[10]) << 16) | (@as(u32, body[11]) << 8) | body[12];
        } else if (std.mem.eql(u8, id, "CMem")) {
            @memcpy(state.memory, state.story[0..state.memory.len]);
            var i: usize = 0;
            var out: usize = 0;
            while (i < body.len) : (i += 1) {
                if (body[i] == 0) {
                    if (i + 1 >= body.len) return error.InvalidSaveFile;
                    i += 1;
                    out += @as(usize, body[i]) + 1;
                } else {
                    if (out >= state.memory.len) return error.InvalidSaveFile;
                    state.memory[out] ^= body[i];
                    out += 1;
                }
            }
            if (out > state.memory.len) return error.InvalidSaveFile;
            have_memory = true;
        } else if (std.mem.eql(u8, id, "UMem")) {
            if (body.len != state.memory.len) return error.InvalidSaveFile;
            @memcpy(state.memory, body);
            have_memory = true;
        } else if (std.mem.eql(u8, id, "Stks")) {
            var i: usize = 0;
            while (i < body.len) {
                if (i + 8 > body.len) return error.InvalidSaveFile;
                if (frame_count >= state.frames.len) return error.StackOverflow;
                const flags = body[i + 3];
                const local_count = flags & 0x0f;
                var frame: Frame = .{
                    .return_pc = (@as(u32, body[i]) << 16) | (@as(u32, body[i + 1]) << 8) | body[i + 2],
                    .store = if (flags & 0x10 != 0) null else body[i + 4],
                    .locals = @splat(0),
                    .local_count = local_count,
                    .arg_count = @intCast(@popCount(body[i + 5])),
                    .stack_base = @intCast(stack_len),
                };
                const value_count = std.mem.readInt(u16, body[i + 6 ..][0..2], .big);
                i += 8;
                if (i + (@as(usize, local_count) + value_count) * 2 > body.len) return error.InvalidSaveFile;
                for (0..local_count) |l| {
                    frame.locals[l] = std.mem.readInt(u16, body[i..][0..2], .big);
                    i += 2;
                }
                if (stack_len + value_count > state.stack.len) return error.StackOverflow;
                for (0..value_count) |_| {
                    state.stack[stack_len] = std.mem.readInt(u16, body[i..][0..2], .big);
                    stack_len += 1;
                    i += 2;
                }
                state.frames[frame_count] = frame;
                frame_count += 1;
            }
        }
    }

    if (pc == null or !have_memory or frame_count == 0) return error.InvalidSaveFile;
    return .{ .pc = pc.?, .frame_count = frame_count, .stack_len = stack_len };
}
