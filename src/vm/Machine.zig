//! The Z-machine processor: memory, the call stack and the instruction set
//! (spec §§4-15). Supports story files of versions 1 through 5, 7 and 8.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Display = @import("Display.zig");
const ObjectTable = @import("ObjectTable.zig");
const Storage = @import("Storage.zig");
const quetzal = @import("quetzal.zig");
const zstring = @import("zstring.zig");

const Machine = @This();

pub const Frame = quetzal.Frame;

const stack_capacity = 0x8000;
const frame_capacity = 1024;

gpa: Allocator,
io: Io,
memory: []u8,
/// Pristine copy of the story file for restart, verify and saving.
story: []const u8,
version: u8,
pc: u32 = 0,
/// Address of the instruction currently executing, for diagnostics.
instruction_pc: u32 = 0,
stack: []u16,
sp: u32 = 0,
frames: []Frame,
frame_count: u32 = 0,
objects: ObjectTable,
alphabets: zstring.Alphabets,
unicode: zstring.UnicodeMap = undefined,
globals: usize,
abbreviations: usize,
dictionary: usize,
static_base: usize,
display: Display,
storage: Storage,
/// The window `set_window` selected.
window: u8 = 0,
/// Linear congruential generator state; the same generator as Frotz, so a
/// run with `--seed` can be compared line for line with `dfrotz -s`.
rng_state: u64,
/// The seed from the command line, reused when the story asks for a
/// fresh random seed.
user_seed: ?u64 = null,
/// When nonzero, `random` counts 1, 2, ... up to this value (spec §2.4).
predictable_range: u16 = 0,
predictable_next: u16 = 0,
screen_stream: bool = true,
memory_streams: [16]MemoryStream = undefined,
memory_stream_depth: usize = 0,
transcript: ?*Io.Writer = null,
/// File that output stream 2 (the transcript) writes to.
transcript_name: []const u8 = "transcript.txt",
undo: ?Snapshot = null,
observer: ?Observer = null,
/// Default file name for saved games.
save_name: []const u8,
finished: bool = false,

const MemoryStream = struct {
    table: u16,
    count: u16,
};

const Snapshot = struct {
    memory: []u8,
    stack: []u16,
    frames: []Frame,
    pc: u32,
};

/// Hooks for tools that watch the game, such as the web inspector. Called on
/// the interpreter thread while the machine is in a consistent state.
pub const Observer = struct {
    context: *anyopaque,
    beforeInput: *const fn (context: *anyopaque, m: *Machine) void,
    afterInput: *const fn (context: *anyopaque, m: *Machine, line: []const u8) void,
};

pub const Error = error{
    UnsupportedVersion,
    InvalidStory,
    InvalidOpcode,
    InvalidVariable,
    StackOverflow,
    StackUnderflow,
    MemoryOutOfBounds,
    DivisionByZero,
    ReturnFromMain,
};

pub fn init(gpa: Allocator, io: Io, story: []const u8, display: Display, storage: Storage, save_name: []const u8) !*Machine {
    if (story.len < 64) return error.InvalidStory;
    const version = story[0];
    switch (version) {
        1...5, 7, 8 => {},
        else => return error.UnsupportedVersion,
    }

    const m = try gpa.create(Machine);
    errdefer gpa.destroy(m);
    // Room for the largest packed address the header can describe.
    const memory = try gpa.alloc(u8, @max(story.len, 64));
    errdefer gpa.free(memory);
    @memcpy(memory[0..story.len], story);
    const stack = try gpa.alloc(u16, stack_capacity);
    errdefer gpa.free(stack);
    const frames = try gpa.alloc(Frame, frame_capacity);
    errdefer gpa.free(frames);

    var seed: [8]u8 = undefined;
    io.random(&seed);

    m.* = .{
        .gpa = gpa,
        .io = io,
        .memory = memory,
        .story = story,
        .version = version,
        .stack = stack,
        .frames = frames,
        .objects = .init(memory, version),
        .alphabets = zstring.loadAlphabets(memory, version),
        .globals = readHeader(memory, 0x0c),
        .abbreviations = readHeader(memory, 0x18),
        .dictionary = readHeader(memory, 0x08),
        .static_base = readHeader(memory, 0x0e),
        .display = display,
        .storage = storage,
        .rng_state = std.mem.readInt(u64, &seed, .little),
        .save_name = save_name,
    };
    if (m.static_base > story.len or m.static_base < 64) return error.InvalidStory;
    m.unicode.load(memory, version);
    m.reset();
    return m;
}

pub fn deinit(m: *Machine) void {
    if (m.transcript) |t| t.flush() catch {};
    m.freeUndo();
    m.gpa.free(m.frames);
    m.gpa.free(m.stack);
    m.gpa.free(m.memory);
    m.gpa.destroy(m);
}

fn readHeader(memory: []const u8, addr: usize) u16 {
    return std.mem.readInt(u16, memory[addr..][0..2], .big);
}

/// Puts the machine in its initial state, as at power-on or `restart`.
fn reset(m: *Machine) void {
    m.sp = 0;
    m.frames[0] = .{
        .return_pc = 0,
        .store = null,
        .locals = @splat(0),
        .local_count = 0,
        .arg_count = 0,
        .stack_base = 0,
    };
    m.frame_count = 1;
    m.pc = readHeader(m.memory, 0x06);
    m.memory_stream_depth = 0;
    m.screen_stream = true;
    m.setupHeader();
}

/// Fills in the header fields the interpreter is responsible for.
fn setupHeader(m: *Machine) void {
    const mem = m.memory;
    const caps = m.display.capabilities();
    if (m.version <= 3) {
        // Status line available, screen splitting available, fixed pitch.
        mem[0x01] = (mem[0x01] & ~@as(u8, 0x10 | 0x40)) | 0x20;
    } else {
        // Fixed-space style; colors (v5+), bold and italic only when drawing
        // with escape sequences, so plain output gets each story's fallback
        // (such as capitals for emphasis); no timed input.
        const styles: u8 = if (caps.styles) 0x0c | @as(u8, if (m.version >= 5) 0x01 else 0) else 0;
        mem[0x01] = (mem[0x01] & ~@as(u8, 0x80 | 0x0d)) | 0x10 | styles;
        mem[0x1e] = 6;
        mem[0x1f] = 'Z';
        mem[0x20] = @intCast(@min(caps.height, 255));
        mem[0x21] = @intCast(@min(caps.width, 255));
    }
    if (m.version >= 5) {
        std.mem.writeInt(u16, mem[0x22..0x24], caps.width, .big);
        std.mem.writeInt(u16, mem[0x24..0x26], caps.height, .big);
        mem[0x26] = 1;
        mem[0x27] = 1;
        mem[0x2c] = 2;
        mem[0x2d] = 9;
        // No pictures, mouse, sound or menus.
        mem[0x11] &= ~@as(u8, 0x08 | 0x20 | 0x80);
        mem[0x10] &= ~@as(u8, 0x01);
    }
    mem[0x32] = 1;
    mem[0x33] = 1;
}

pub fn run(m: *Machine) !void {
    while (!m.finished) try m.step();
    try m.flushTranscript();
}

// Memory access

pub fn readByte(m: *const Machine, addr: usize) Error!u8 {
    if (addr >= m.memory.len) return error.MemoryOutOfBounds;
    return m.memory[addr];
}

pub fn readWord(m: *const Machine, addr: usize) Error!u16 {
    if (addr + 1 >= m.memory.len) return error.MemoryOutOfBounds;
    return std.mem.readInt(u16, m.memory[addr..][0..2], .big);
}

fn writeByte(m: *Machine, addr: usize, value: u8) Error!void {
    if (addr >= m.static_base) return error.MemoryOutOfBounds;
    m.memory[addr] = value;
}

fn writeWord(m: *Machine, addr: usize, value: u16) Error!void {
    if (addr + 1 >= m.static_base) return error.MemoryOutOfBounds;
    std.mem.writeInt(u16, m.memory[addr..][0..2], value, .big);
}

fn fetchByte(m: *Machine) Error!u8 {
    const b = try m.readByte(m.pc);
    m.pc += 1;
    return b;
}

fn fetchWord(m: *Machine) Error!u16 {
    const w = try m.readWord(m.pc);
    m.pc += 2;
    return w;
}

fn unpackRoutine(m: *const Machine, packed_addr: u16) usize {
    const p: usize = packed_addr;
    return switch (m.version) {
        1, 2, 3 => p * 2,
        4, 5 => p * 4,
        6, 7 => p * 4 + @as(usize, readHeader(m.memory, 0x28)) * 8,
        else => p * 8,
    };
}

fn unpackString(m: *const Machine, packed_addr: u16) usize {
    const p: usize = packed_addr;
    return switch (m.version) {
        1, 2, 3 => p * 2,
        4, 5 => p * 4,
        6, 7 => p * 4 + @as(usize, readHeader(m.memory, 0x2a)) * 8,
        else => p * 8,
    };
}

// Variables and the stack

fn push(m: *Machine, value: u16) Error!void {
    if (m.sp >= m.stack.len) return error.StackOverflow;
    m.stack[m.sp] = value;
    m.sp += 1;
}

fn pop(m: *Machine) Error!u16 {
    if (m.sp <= m.currentFrame().stack_base) {
        // Some early stories (e.g. Zork I release 2) pull from an empty
        // stack right after popping; original interpreters then read the
        // stale slot, which is what the story expects.
        return m.stack[m.sp];
    }
    m.sp -= 1;
    return m.stack[m.sp];
}

fn peek(m: *Machine) Error!*u16 {
    if (m.sp <= m.currentFrame().stack_base) return error.StackUnderflow;
    return &m.stack[m.sp - 1];
}

pub fn currentFrame(m: *Machine) *Frame {
    return &m.frames[m.frame_count - 1];
}

pub fn readGlobal(m: *const Machine, index: u8) Error!u16 {
    return m.readWord(m.globals + @as(usize, index) * 2);
}

fn readVar(m: *Machine, v: u8) Error!u16 {
    if (v == 0) return m.pop();
    if (v < 16) {
        const frame = m.currentFrame();
        if (v > frame.local_count) return error.InvalidVariable;
        return frame.locals[v - 1];
    }
    return m.readGlobal(v - 16);
}

fn writeVar(m: *Machine, v: u8, value: u16) Error!void {
    if (v == 0) return m.push(value);
    if (v < 16) {
        const frame = m.currentFrame();
        if (v > frame.local_count) return error.InvalidVariable;
        frame.locals[v - 1] = value;
        return;
    }
    return m.writeWord(m.globals + @as(usize, v - 16) * 2, value);
}

/// Reads a variable named by an operand: the stack is read in place.
fn readVarIndirect(m: *Machine, v: u8) Error!u16 {
    if (v == 0) return (try m.peek()).*;
    return m.readVar(v);
}

/// Writes a variable named by an operand: the stack top is replaced.
fn writeVarIndirect(m: *Machine, v: u8, value: u16) Error!void {
    if (v == 0) {
        (try m.peek()).* = value;
        return;
    }
    return m.writeVar(v, value);
}

// Instruction decoding

fn fetchOperand(m: *Machine, kind: u2) Error!u16 {
    return switch (kind) {
        0 => m.fetchWord(),
        1 => @as(u16, try m.fetchByte()),
        2 => m.readVar(try m.fetchByte()),
        3 => unreachable,
    };
}

fn fetchVarOperands(m: *Machine, operands: *[8]u16, type_bytes: usize) Error!usize {
    var types: [2]u8 = .{ 0xff, 0xff };
    for (0..type_bytes) |i| types[i] = try m.fetchByte();
    var count: usize = 0;
    outer: for (types[0..type_bytes]) |t| {
        var shift: u3 = 6;
        while (true) : (shift -= 2) {
            const kind: u2 = @intCast((t >> shift) & 3);
            if (kind == 3) break :outer;
            operands[count] = try m.fetchOperand(kind);
            count += 1;
            if (shift == 0) break;
        }
    }
    return count;
}

fn store(m: *Machine, value: u16) Error!void {
    try m.writeVar(try m.fetchByte(), value);
}

fn branch(m: *Machine, condition: bool) !void {
    const b = try m.fetchByte();
    var offset: i16 = undefined;
    if (b & 0x40 != 0) {
        offset = b & 0x3f;
    } else {
        const raw: u16 = (@as(u16, b & 0x3f) << 8) | try m.fetchByte();
        // Sign-extend the 14-bit value.
        offset = @as(i16, @bitCast(raw << 2)) >> 2;
    }
    if (condition != (b & 0x80 != 0)) return;
    switch (offset) {
        0 => try m.ret(0),
        1 => try m.ret(1),
        else => m.jump(offset),
    }
}

fn jump(m: *Machine, offset: i16) void {
    const target = @as(i64, m.pc) + offset - 2;
    m.pc = @intCast(target);
}

fn call(m: *Machine, routine: u16, args: []const u16, store_var: ?u8) !void {
    if (routine == 0) {
        if (store_var) |v| try m.writeVar(v, 0);
        return;
    }
    if (m.frame_count >= m.frames.len) return error.StackOverflow;
    var addr = m.unpackRoutine(routine);
    const local_count = try m.readByte(addr);
    if (local_count > 15) return error.InvalidStory;
    addr += 1;

    var frame: Frame = .{
        .return_pc = m.pc,
        .store = store_var,
        .locals = @splat(0),
        .local_count = local_count,
        .arg_count = @intCast(@min(args.len, 7)),
        .stack_base = m.sp,
    };
    for (0..local_count) |i| {
        if (m.version <= 4) {
            frame.locals[i] = try m.readWord(addr);
            addr += 2;
        }
        if (i < args.len) frame.locals[i] = args[i];
    }
    m.frames[m.frame_count] = frame;
    m.frame_count += 1;
    m.pc = @intCast(addr);
}

fn ret(m: *Machine, value: u16) !void {
    if (m.frame_count <= 1) return error.ReturnFromMain;
    const frame = m.frames[m.frame_count - 1];
    m.frame_count -= 1;
    m.sp = frame.stack_base;
    m.pc = frame.return_pc;
    if (frame.store) |v| try m.writeVar(v, value);
}

// Execution

fn step(m: *Machine) !void {
    m.instruction_pc = m.pc;
    const opcode = try m.fetchByte();
    var operands: [8]u16 = undefined;

    if (opcode == 0xbe and m.version >= 5) {
        const ext = try m.fetchByte();
        const count = try m.fetchVarOperands(&operands, 1);
        return m.execExt(ext, operands[0..count]);
    }
    switch (opcode >> 6) {
        0b11 => {
            const double = opcode == 0xec or opcode == 0xfa;
            const count = try m.fetchVarOperands(&operands, if (double) 2 else 1);
            if (opcode & 0x20 != 0) return m.execVar(opcode & 0x1f, operands[0..count]);
            return m.exec2op(opcode & 0x1f, operands[0..count]);
        },
        0b10 => {
            const kind: u2 = @intCast((opcode >> 4) & 3);
            if (kind == 3) return m.exec0op(opcode & 0x0f);
            return m.exec1op(opcode & 0x0f, try m.fetchOperand(kind));
        },
        else => {
            operands[0] = try m.fetchOperand(if (opcode & 0x40 != 0) 2 else 1);
            operands[1] = try m.fetchOperand(if (opcode & 0x20 != 0) 2 else 1);
            return m.exec2op(opcode & 0x1f, operands[0..2]);
        },
    }
}

fn signed(x: u16) i16 {
    return @bitCast(x);
}

fn unsigned(x: i16) u16 {
    return @bitCast(x);
}

fn invalid(m: *Machine) Error {
    std.log.err("invalid opcode at 0x{x:0>5}", .{m.instruction_pc});
    return error.InvalidOpcode;
}

fn exec2op(m: *Machine, op: u8, ops: []const u16) !void {
    if (ops.len < 2 and op != 1) return m.invalid();
    const a = ops[0];
    const b = if (ops.len > 1) ops[1] else 0;
    switch (op) {
        1 => { // je
            var equal = false;
            for (ops[1..]) |other| equal = equal or a == other;
            try m.branch(equal);
        },
        2 => try m.branch(signed(a) < signed(b)), // jl
        3 => try m.branch(signed(a) > signed(b)), // jg
        4 => { // dec_chk
            const v: u8 = @truncate(a);
            const value = signed(try m.readVarIndirect(v)) -% 1;
            try m.writeVarIndirect(v, unsigned(value));
            try m.branch(value < signed(b));
        },
        5 => { // inc_chk
            const v: u8 = @truncate(a);
            const value = signed(try m.readVarIndirect(v)) +% 1;
            try m.writeVarIndirect(v, unsigned(value));
            try m.branch(value > signed(b));
        },
        6 => try m.branch(try m.objects.parent(a) == b), // jin
        7 => try m.branch(a & b == b), // test
        8 => try m.store(a | b), // or
        9 => try m.store(a & b), // and
        10 => try m.branch(try m.objects.attribute(a, b)), // test_attr
        11 => try m.objects.setAttribute(a, b, true), // set_attr
        12 => try m.objects.setAttribute(a, b, false), // clear_attr
        13 => try m.writeVarIndirect(@truncate(a), b), // store
        14 => try m.objects.insert(a, b), // insert_obj
        15 => try m.store(try m.readWord(a +% b *% 2)), // loadw
        16 => try m.store(try m.readByte(a +% b)), // loadb
        17 => try m.store(try m.objects.getProperty(a, b)), // get_prop
        18 => try m.store(try m.objects.propertyAddress(a, b)), // get_prop_addr
        19 => try m.store(try m.objects.nextProperty(a, b)), // get_next_prop
        20 => try m.store(unsigned(signed(a) +% signed(b))), // add
        21 => try m.store(unsigned(signed(a) -% signed(b))), // sub
        22 => try m.store(unsigned(signed(a) *% signed(b))), // mul
        23 => { // div
            if (b == 0) return error.DivisionByZero;
            try m.store(unsigned(@truncate(@divTrunc(@as(i32, signed(a)), signed(b)))));
        },
        24 => { // mod
            if (b == 0) return error.DivisionByZero;
            try m.store(unsigned(@truncate(@rem(@as(i32, signed(a)), signed(b)))));
        },
        25 => try m.call(a, ops[1..], try m.fetchByte()), // call_2s
        26 => try m.call(a, ops[1..], null), // call_2n
        27 => try m.display.setColor(a, b), // set_colour
        28 => { // throw
            if (b == 0 or b > m.frame_count) return error.StackUnderflow;
            m.frame_count = b;
            try m.ret(a);
        },
        else => return m.invalid(),
    }
}

fn exec1op(m: *Machine, op: u8, a: u16) !void {
    switch (op) {
        0 => try m.branch(a == 0), // jz
        1 => { // get_sibling
            const s = try m.objects.sibling(a);
            try m.store(s);
            try m.branch(s != 0);
        },
        2 => { // get_child
            const c = try m.objects.child(a);
            try m.store(c);
            try m.branch(c != 0);
        },
        3 => try m.store(try m.objects.parent(a)), // get_parent
        4 => try m.store(try m.objects.propertyLength(a)), // get_prop_len
        5 => { // inc
            const v: u8 = @truncate(a);
            try m.writeVarIndirect(v, (try m.readVarIndirect(v)) +% 1);
        },
        6 => { // dec
            const v: u8 = @truncate(a);
            try m.writeVarIndirect(v, (try m.readVarIndirect(v)) -% 1);
        },
        7 => _ = try m.printString(a), // print_addr
        8 => try m.call(a, &.{}, try m.fetchByte()), // call_1s
        9 => try m.objects.remove(a), // remove_obj
        10 => try m.printObject(a), // print_obj
        11 => try m.ret(a), // ret
        12 => m.jump(signed(a)), // jump
        13 => _ = try m.printString(m.unpackString(a)), // print_paddr
        14 => try m.store(try m.readVarIndirect(@truncate(a))), // load
        15 => {
            if (m.version <= 4) {
                try m.store(~a); // not
            } else {
                try m.call(a, &.{}, null); // call_1n
            }
        },
        else => unreachable,
    }
}

fn exec0op(m: *Machine, op: u8) !void {
    switch (op) {
        0 => try m.ret(1), // rtrue
        1 => try m.ret(0), // rfalse
        2 => m.pc = @intCast(try m.printString(m.pc)), // print
        3 => { // print_ret
            m.pc = @intCast(try m.printString(m.pc));
            try m.printZscii(13);
            try m.ret(1);
        },
        4 => {}, // nop
        5 => { // save
            if (m.version >= 5) return m.invalid();
            const ok = try m.saveGame();
            if (m.version <= 3) try m.branch(ok) else try m.store(@intFromBool(ok));
        },
        6 => { // restore
            if (m.version >= 5) return m.invalid();
            if (!try m.restoreGame()) {
                if (m.version <= 3) try m.branch(false) else try m.store(0);
            }
        },
        7 => try m.restart(), // restart
        8 => try m.ret(try m.pop()), // ret_popped
        9 => {
            if (m.version <= 4) {
                _ = try m.pop(); // pop
            } else {
                try m.store(@intCast(m.frame_count)); // catch
            }
        },
        10 => m.finished = true, // quit
        11 => try m.printZscii(13), // new_line
        12 => if (m.version <= 3) try m.showStatus(), // show_status
        13 => try m.branch(m.verify()), // verify
        15 => try m.branch(true), // piracy
        else => return m.invalid(),
    }
}

fn execVar(m: *Machine, op: u8, ops: []const u16) !void {
    const arg = struct {
        fn get(o: []const u16, i: usize) u16 {
            return if (i < o.len) o[i] else 0;
        }
    }.get;
    switch (op) {
        0 => { // call_vs
            if (ops.len == 0) return m.invalid();
            try m.call(ops[0], ops[1..], try m.fetchByte());
        },
        1 => try m.writeWord(arg(ops, 0) +% arg(ops, 1) *% 2, arg(ops, 2)), // storew
        2 => try m.writeByte(arg(ops, 0) +% arg(ops, 1), @truncate(arg(ops, 2))), // storeb
        3 => try m.objects.putProperty(arg(ops, 0), arg(ops, 1), arg(ops, 2)), // put_prop
        4 => try m.read(ops), // sread / aread
        5 => try m.printZscii(arg(ops, 0)), // print_char
        6 => try m.printNumber(signed(arg(ops, 0))), // print_num
        7 => try m.store(m.random(signed(arg(ops, 0)))), // random
        8 => try m.push(arg(ops, 0)), // push
        9 => { // pull
            const value = try m.pop();
            try m.writeVarIndirect(@truncate(arg(ops, 0)), value);
        },
        10 => try m.display.splitWindow(arg(ops, 0)), // split_window
        11 => { // set_window
            m.window = @truncate(arg(ops, 0));
            try m.display.setWindow(m.window);
        },
        12 => { // call_vs2
            if (ops.len == 0) return m.invalid();
            try m.call(ops[0], ops[1..], try m.fetchByte());
        },
        13 => try m.display.eraseWindow(signed(arg(ops, 0))), // erase_window
        14 => if (arg(ops, 0) == 1) try m.display.eraseLine(), // erase_line
        15 => try m.display.setCursor(arg(ops, 0), arg(ops, 1)), // set_cursor
        16 => { // get_cursor
            const pos = m.display.getCursor();
            try m.writeWord(arg(ops, 0), pos[0]);
            try m.writeWord(arg(ops, 0) + 2, pos[1]);
        },
        17 => try m.display.setStyle(@truncate(arg(ops, 0))), // set_text_style
        18 => try m.display.setBuffered(arg(ops, 0) != 0), // buffer_mode
        19 => try m.outputStream(signed(arg(ops, 0)), arg(ops, 1)), // output_stream
        20 => {}, // input_stream
        21 => {}, // sound_effect
        22 => { // read_char
            const key = (try m.display.readKey()) orelse {
                m.finished = true;
                return;
            };
            try m.store(key);
        },
        23 => { // scan_table
            const form = if (ops.len > 3) ops[3] else 0x82;
            const found = try m.scanTable(arg(ops, 0), arg(ops, 1), arg(ops, 2), form);
            try m.store(found);
            try m.branch(found != 0);
        },
        24 => try m.store(~arg(ops, 0)), // not
        25, 26 => { // call_vn, call_vn2
            if (ops.len == 0) return m.invalid();
            try m.call(ops[0], ops[1..], null);
        },
        27 => { // tokenise
            const dict = if (arg(ops, 2) != 0) arg(ops, 2) else m.dictionary;
            try m.tokenize(arg(ops, 0), arg(ops, 1), dict, arg(ops, 3) != 0);
        },
        28 => { // encode_text
            const text = arg(ops, 0) + arg(ops, 2);
            const len = arg(ops, 1);
            if (text + len > m.memory.len) return error.MemoryOutOfBounds;
            const words = zstring.encode(&m.alphabets, m.version, m.memory[text..][0..len]);
            for (words, 0..) |w, i| try m.writeWord(arg(ops, 3) + i * 2, w);
        },
        29 => try m.copyTable(arg(ops, 0), arg(ops, 1), signed(arg(ops, 2))), // copy_table
        30 => try m.printTable(arg(ops, 0), arg(ops, 1), if (ops.len > 2) ops[2] else 1, arg(ops, 3)), // print_table
        31 => try m.branch(arg(ops, 0) <= m.currentFrame().arg_count), // check_arg_count
        else => return m.invalid(),
    }
}

fn execExt(m: *Machine, op: u8, ops: []const u16) !void {
    const a = if (ops.len > 0) ops[0] else 0;
    const b = if (ops.len > 1) ops[1] else 0;
    switch (op) {
        0 => { // save
            if (ops.len > 0) return m.store(0);
            try m.store(@intFromBool(try m.saveGame()));
        },
        1 => { // restore
            if (ops.len > 0) return m.store(0);
            if (!try m.restoreGame()) try m.store(0);
        },
        2 => { // log_shift
            const places = signed(b);
            const result = if (places >= 0)
                std.math.shl(u16, a, @as(u16, @intCast(places)))
            else
                std.math.shr(u16, a, @as(u16, @intCast(-places)));
            try m.store(result);
        },
        3 => { // art_shift
            const places = signed(b);
            const result = if (places >= 0)
                std.math.shl(i16, signed(a), @as(u16, @intCast(places)))
            else
                signed(a) >> @intCast(@min(-places, 15));
            try m.store(unsigned(result));
        },
        4 => try m.store(if (a == 0 or a == 1 or a == 4) 1 else 0), // set_font
        9 => try m.saveUndo(), // save_undo
        10 => try m.restoreUndo(), // restore_undo
        11 => try m.printUnicode(a), // print_unicode
        12 => try m.store(if (m.unicode.fromUnicode(a) != null or a >= 0xa0) 3 else 0), // check_unicode
        13 => {}, // set_true_colour
        else => return m.invalid(),
    }
}

// Output

const PrintSink = struct {
    m: *Machine,

    pub fn emit(s: PrintSink, c: u16) !void {
        try s.m.printZscii(c);
    }
};

/// Collects decoded text as UTF-8 into a fixed buffer.
pub const TextBuffer = struct {
    unicode: *const zstring.UnicodeMap,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn emit(b: *TextBuffer, c: u16) !void {
        const cp = b.unicode.toUnicode(c) orelse return;
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        if (b.len + n > b.buf.len) return;
        @memcpy(b.buf[b.len..][0..n], utf8[0..n]);
        b.len += n;
    }

    pub fn slice(b: *const TextBuffer) []const u8 {
        return b.buf[0..b.len];
    }
};

pub fn decoder(m: *const Machine) zstring.Decoder {
    return .{
        .memory = m.memory,
        .version = m.version,
        .abbreviations = m.abbreviations,
        .alphabets = &m.alphabets,
    };
}

/// Decodes an object's short name into `out`.
pub fn objectName(m: *const Machine, obj: u16, out: *TextBuffer) void {
    out.* = .{ .unicode = &m.unicode };
    const name = m.objects.name(obj) catch return;
    if (name.words == 0) return;
    _ = m.decoder().decode(name.addr, out) catch {};
}

fn printString(m: *Machine, addr: usize) !usize {
    return m.decoder().decode(addr, PrintSink{ .m = m });
}

fn printObject(m: *Machine, obj: u16) !void {
    const name = try m.objects.name(obj);
    if (name.words == 0) return;
    _ = try m.printString(name.addr);
}

fn printNumber(m: *Machine, n: i16) !void {
    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    for (text) |c| try m.printZscii(c);
}

pub fn printAscii(m: *Machine, text: []const u8) !void {
    for (text) |c| try m.printZscii(if (c == '\n') 13 else c);
}

fn printUnicode(m: *Machine, cp: u16) !void {
    if (m.unicode.fromUnicode(cp)) |z| return m.printZscii(z);
    if (m.memory_stream_depth > 0) return m.printZscii('?');
    if (m.screen_stream) try m.display.print(std.math.cast(u21, cp) orelse '?');
}

pub fn printZscii(m: *Machine, zscii: u16) !void {
    const c = if (zscii == 10) 13 else zscii;
    if (m.memory_stream_depth > 0) {
        const stream = &m.memory_streams[m.memory_stream_depth - 1];
        try m.writeByte(@as(usize, stream.table) + 2 + stream.count, @truncate(c));
        stream.count +%= 1;
        return;
    }
    const cp = m.unicode.toUnicode(c) orelse return;
    if (m.screen_stream) try m.display.print(cp);
    if (m.memory[0x11] & 0x01 != 0 and m.window == 0) try m.transcribe(cp);
}

fn transcribe(m: *Machine, cp: u21) !void {
    if (m.transcript == null) m.transcript = m.storage.transcript(m.transcript_name) orelse return;
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &utf8) catch return;
    m.transcript.?.writeAll(utf8[0..n]) catch {};
}

fn flushTranscript(m: *Machine) !void {
    if (m.transcript) |t| t.flush() catch {};
}

fn outputStream(m: *Machine, n: i16, table: u16) !void {
    switch (n) {
        1 => m.screen_stream = true,
        -1 => m.screen_stream = false,
        2 => m.memory[0x11] |= 0x01,
        -2 => m.memory[0x11] &= ~@as(u8, 0x01),
        3 => {
            if (m.memory_stream_depth >= m.memory_streams.len) return error.StackOverflow;
            m.memory_streams[m.memory_stream_depth] = .{ .table = table, .count = 0 };
            m.memory_stream_depth += 1;
        },
        -3 => {
            if (m.memory_stream_depth == 0) return;
            m.memory_stream_depth -= 1;
            const stream = m.memory_streams[m.memory_stream_depth];
            try m.writeWord(stream.table, stream.count);
        },
        else => {},
    }
}

fn printTable(m: *Machine, text: u16, width: u16, height: u16, skip: u16) !void {
    const start = m.display.getCursor();
    var addr: usize = text;
    for (0..height) |row| {
        if (row > 0) {
            if (m.window == 1) {
                try m.display.setCursor(start[0] + @as(u16, @intCast(row)), start[1]);
            } else {
                try m.printZscii(13);
            }
        }
        for (0..width) |_| {
            try m.printZscii(try m.readByte(addr));
            addr += 1;
        }
        addr += skip;
    }
}

pub fn showStatus(m: *Machine) !void {
    var name: TextBuffer = undefined;
    m.objectName(try m.readGlobal(0), &name);
    var right_buf: [48]u8 = undefined;
    const a = signed(try m.readGlobal(1));
    const b = try m.readGlobal(2);
    const right = if (m.version == 3 and m.memory[0x01] & 0x02 != 0) blk: {
        const hours: u16 = @intCast(@mod(a, 24));
        const h12 = if (hours % 12 == 0) 12 else hours % 12;
        break :blk std.fmt.bufPrint(&right_buf, "Time: {d}:{d:0>2} {s}", .{
            h12, b % 60, if (hours < 12) "am" else "pm",
        }) catch unreachable;
    } else std.fmt.bufPrint(&right_buf, "Score: {d}   Moves: {d}", .{ a, b }) catch unreachable;
    try m.display.drawStatus(name.slice(), right);
}

// Input

fn read(m: *Machine, ops: []const u16) !void {
    if (ops.len < 1) return m.invalid();
    const text: usize = ops[0];
    const parse: usize = if (ops.len > 1) ops[1] else 0;

    if (m.version <= 3) try m.showStatus();
    try m.flushTranscript();
    if (m.observer) |o| o.beforeInput(o.context, m);

    var max: usize = try m.readByte(text);
    if (m.version <= 4) max -|= 1;
    const start = if (m.version >= 5) text + 2 else text + 1;
    var n: usize = 0;
    if (m.version >= 5) {
        n = try m.readByte(text + 1);
        if (n > max) n = 0;
    }

    var buf: [512]u8 = undefined;
    const line = (try m.display.readLine(&buf)) orelse {
        m.finished = true;
        return;
    };
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (it.nextCodepoint()) |cp| {
        const lower = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
        const z = m.unicode.fromUnicode(lower) orelse continue;
        if (n >= max) break;
        try m.writeByte(start + n, z);
        n += 1;
    }
    if (m.version >= 5) {
        try m.writeByte(text + 1, @intCast(n));
    } else {
        try m.writeByte(start + n, 0);
    }
    if (m.memory[0x11] & 0x01 != 0) {
        if (m.transcript) |t| {
            t.writeAll(line) catch {};
            t.writeAll("\n") catch {};
        }
    }
    if (m.observer) |o| o.afterInput(o.context, m, line);

    if (parse != 0) try m.tokenize(text, parse, m.dictionary, false);
    if (m.version >= 5) try m.store(13);
}

fn tokenize(m: *Machine, text: usize, parse: usize, dict: usize, skip_unknown: bool) !void {
    var start: usize = undefined;
    var len: usize = undefined;
    if (m.version >= 5) {
        start = text + 2;
        len = try m.readByte(text + 1);
    } else {
        start = text + 1;
        len = 0;
        while (start + len < m.memory.len and m.memory[start + len] != 0) len += 1;
    }
    if (start + len > m.memory.len) return error.MemoryOutOfBounds;
    const chars = m.memory[start..][0..len];

    const sep_count = try m.readByte(dict);
    if (dict + 1 + sep_count > m.memory.len) return error.MemoryOutOfBounds;
    const separators = m.memory[dict + 1 ..][0..sep_count];

    const max_words = try m.readByte(parse);
    var count: u8 = 0;
    var i: usize = 0;
    while (i < chars.len and count < max_words) {
        if (chars[i] == ' ') {
            i += 1;
            continue;
        }
        var j = i + 1;
        if (std.mem.indexOfScalar(u8, separators, chars[i]) == null) {
            while (j < chars.len and chars[j] != ' ' and
                std.mem.indexOfScalar(u8, separators, chars[j]) == null) j += 1;
        }
        const entry_addr = try m.lookup(dict, chars[i..j]);
        const slot = parse + 2 + @as(usize, count) * 4;
        if (!(skip_unknown and entry_addr == 0)) {
            try m.writeWord(slot, entry_addr);
            try m.writeByte(slot + 2, @intCast(j - i));
            try m.writeByte(slot + 3, @intCast(start - text + i));
        }
        count += 1;
        i = j;
    }
    try m.writeByte(parse + 1, count);
}

/// Finds `word` in the dictionary at `dict`, returning its address or 0.
pub fn lookup(m: *const Machine, dict: usize, word: []const u8) !u16 {
    const sep_count = try m.readByte(dict);
    const entry_len = try m.readByte(dict + 1 + sep_count);
    const raw_count = signed(try m.readWord(dict + 2 + sep_count));
    const entries = dict + 4 + sep_count;

    const encoded = zstring.encode(&m.alphabets, m.version, word);
    var key: [6]u8 = undefined;
    for (encoded, 0..) |w, i| std.mem.writeInt(u16, key[i * 2 ..][0..2], w, .big);
    const key_len: usize = if (m.version <= 3) 4 else 6;

    const count: usize = @abs(raw_count);
    if (entries + count * entry_len > m.memory.len) return error.MemoryOutOfBounds;

    if (raw_count > 0) {
        var lo: usize = 0;
        var hi: usize = count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const addr = entries + mid * entry_len;
            switch (std.mem.order(u8, m.memory[addr..][0..key_len], key[0..key_len])) {
                .eq => return @intCast(addr),
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
    } else {
        for (0..count) |i| {
            const addr = entries + i * entry_len;
            if (std.mem.eql(u8, m.memory[addr..][0..key_len], key[0..key_len])) return @intCast(addr);
        }
    }
    return 0;
}

// Tables

fn scanTable(m: *Machine, x: u16, table: u16, len: u16, form: u16) !u16 {
    const field: usize = form & 0x7f;
    const words = form & 0x80 != 0;
    var addr: usize = table;
    for (0..len) |_| {
        const value = if (words) try m.readWord(addr) else try m.readByte(addr);
        if (value == x) return @intCast(addr);
        addr += field;
    }
    return 0;
}

fn copyTable(m: *Machine, first: u16, second: u16, size: i16) !void {
    const n: usize = @abs(size);
    if (second == 0) {
        for (0..n) |i| try m.writeByte(@as(usize, first) + i, 0);
        return;
    }
    if (@as(usize, first) + n > m.memory.len or @as(usize, second) + n > m.static_base) {
        return error.MemoryOutOfBounds;
    }
    const src = m.memory[first..][0..n];
    const dst = m.memory[second..][0..n];
    if (size < 0 or second <= first) {
        std.mem.copyForwards(u8, dst, src);
    } else {
        std.mem.copyBackwards(u8, dst, src);
    }
}

// Randomness

fn random(m: *Machine, range: i16) u16 {
    if (range > 0) {
        const r: u16 = @intCast(range);
        if (m.predictable_range != 0) {
            m.predictable_next = m.predictable_next % m.predictable_range + 1;
            return (m.predictable_next - 1) % r + 1;
        }
        m.rng_state = m.rng_state *% 0x015a4e35 +% 1;
        const value: u16 = @intCast((m.rng_state >> 16) & 0x7fff);
        return value % r + 1;
    }
    if (range == 0) {
        m.rng_state = m.user_seed orelse seed: {
            var seed: [8]u8 = undefined;
            m.io.random(&seed);
            break :seed std.mem.readInt(u64, &seed, .little);
        };
        m.predictable_range = 0;
    } else {
        const seed: u16 = @intCast(-@as(i32, range));
        if (seed < 1000) {
            m.predictable_range = seed;
            m.predictable_next = 0;
        } else {
            m.rng_state = seed;
            m.predictable_range = 0;
        }
    }
    return 0;
}

/// Starts the transcript before the story runs, writing to `name`.
pub fn startTranscript(m: *Machine, name: []const u8) void {
    m.transcript_name = name;
    m.memory[0x11] |= 0x01;
}

/// Seeds the generator for reproducible runs.
pub fn seedRandom(m: *Machine, seed: u64) void {
    m.rng_state = seed;
    m.user_seed = seed;
}

// Game state

fn verify(m: *const Machine) bool {
    const scale: usize = switch (m.version) {
        1, 2, 3 => 2,
        4, 5 => 4,
        else => 8,
    };
    const len = @min(@as(usize, readHeader(m.story, 0x1a)) * scale, m.story.len);
    var sum: u16 = 0;
    if (len > 0x40) {
        for (m.story[0x40..len]) |b| sum +%= b;
    }
    return sum == readHeader(m.story, 0x1c);
}

fn restart(m: *Machine) !void {
    const flags2 = m.memory[0x11] & 0x03;
    @memcpy(m.memory[0..m.static_base], m.story[0..m.static_base]);
    m.memory[0x11] = (m.memory[0x11] & ~@as(u8, 0x03)) | flags2;
    try m.display.eraseWindow(-1);
    m.reset();
}

fn promptFileName(m: *Machine, prompt: []const u8, buf: []u8) !?[]const u8 {
    try m.printAscii(prompt);
    try m.printAscii(" [");
    try m.printAscii(m.save_name);
    try m.printAscii("]: ");
    const line = (try m.display.readLine(buf)) orelse return null;
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return m.save_name;
    return trimmed;
}

/// Writes a Quetzal file. The saved PC addresses the instruction's branch
/// or store byte, which restoring completes with a "restored" result.
fn saveGame(m: *Machine) !bool {
    var buf: [256]u8 = undefined;
    const name = (try m.promptFileName("Save to file", &buf)) orelse return false;
    const data = quetzal.write(m.gpa, .{
        .memory = m.memory[0..m.static_base],
        .story = m.story,
        .frames = m.frames[0..m.frame_count],
        .stack = m.stack[0..m.sp],
        .pc = m.pc,
    }) catch return false;
    defer m.gpa.free(data);
    m.storage.save(name, data) catch |err| {
        try m.printAscii("Could not write save file: ");
        try m.printAscii(@errorName(err));
        try m.printZscii(13);
        return false;
    };
    return true;
}

/// Loads a Quetzal file. On success the machine continues after the
/// original save instruction; on failure the caller reports it.
fn restoreGame(m: *Machine) !bool {
    var buf: [256]u8 = undefined;
    const name = (try m.promptFileName("Restore from file", &buf)) orelse return false;
    const data = m.storage.restore(name, m.gpa) catch |err| {
        try m.printAscii("Could not read save file: ");
        try m.printAscii(@errorName(err));
        try m.printZscii(13);
        return false;
    };
    defer m.gpa.free(data);

    // Restore into scratch buffers so a bad file leaves the game intact.
    const memory = try m.gpa.alloc(u8, m.static_base);
    defer m.gpa.free(memory);
    const stack = try m.gpa.alloc(u16, m.stack.len);
    defer m.gpa.free(stack);
    const frames = try m.gpa.alloc(Frame, m.frames.len);
    defer m.gpa.free(frames);

    const restored = quetzal.read(data, .{
        .memory = memory,
        .story = m.story,
        .frames = frames,
        .stack = stack,
        .pc = 0,
    }) catch |err| {
        try m.printAscii("Could not restore: ");
        try m.printAscii(@errorName(err));
        try m.printZscii(13);
        return false;
    };

    const flags2 = m.memory[0x11] & 0x03;
    @memcpy(m.memory[0..m.static_base], memory);
    m.memory[0x11] = (m.memory[0x11] & ~@as(u8, 0x03)) | flags2;
    @memcpy(m.stack[0..restored.stack_len], stack[0..restored.stack_len]);
    @memcpy(m.frames[0..restored.frame_count], frames[0..restored.frame_count]);
    m.sp = @intCast(restored.stack_len);
    m.frame_count = @intCast(restored.frame_count);
    m.pc = restored.pc;
    m.setupHeader();

    if (m.version <= 3) try m.branch(true) else try m.store(2);
    return true;
}

fn freeUndo(m: *Machine) void {
    if (m.undo) |u| {
        m.gpa.free(u.memory);
        m.gpa.free(u.stack);
        m.gpa.free(u.frames);
        m.undo = null;
    }
}

fn saveUndo(m: *Machine) !void {
    m.freeUndo();
    const memory = try m.gpa.dupe(u8, m.memory[0..m.static_base]);
    errdefer m.gpa.free(memory);
    const stack = try m.gpa.dupe(u16, m.stack[0..m.sp]);
    errdefer m.gpa.free(stack);
    const frames = try m.gpa.dupe(Frame, m.frames[0..m.frame_count]);
    m.undo = .{ .memory = memory, .stack = stack, .frames = frames, .pc = m.pc };
    try m.store(1);
}

fn restoreUndo(m: *Machine) !void {
    const u = m.undo orelse return m.store(0);
    @memcpy(m.memory[0..m.static_base], u.memory);
    @memcpy(m.stack[0..u.stack.len], u.stack);
    @memcpy(m.frames[0..u.frames.len], u.frames);
    m.sp = @intCast(u.stack.len);
    m.frame_count = @intCast(u.frames.len);
    m.pc = u.pc;
    m.setupHeader();
    try m.store(2);
}
