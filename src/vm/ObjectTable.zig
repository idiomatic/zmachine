//! Access to the object tree and property tables (spec §12).

const std = @import("std");

const ObjectTable = @This();

memory: []u8,
version: u8,
/// Byte address of the object table (the property defaults come first).
base: usize,

pub const Error = error{ InvalidObject, InvalidProperty, MemoryOutOfBounds };

pub const Property = struct {
    number: u8,
    /// Address of the first data byte.
    data: usize,
    size: usize,
    /// Address of the next property's size byte.
    next: usize,
};

pub fn init(memory: []u8, version: u8) ObjectTable {
    return .{
        .memory = memory,
        .version = version,
        .base = std.mem.readInt(u16, memory[0x0a..][0..2], .big),
    };
}

fn wide(t: ObjectTable) bool {
    return t.version >= 4;
}

pub fn attributeCount(t: ObjectTable) u8 {
    return if (t.wide()) 48 else 32;
}

fn entrySize(t: ObjectTable) usize {
    return if (t.wide()) 14 else 9;
}

fn defaultsSize(t: ObjectTable) usize {
    return if (t.wide()) 63 * 2 else 31 * 2;
}

fn maxObject(t: ObjectTable) u16 {
    return if (t.wide()) 0xffff else 255;
}

fn readWord(t: ObjectTable, addr: usize) Error!u16 {
    if (addr + 1 >= t.memory.len) return error.MemoryOutOfBounds;
    return std.mem.readInt(u16, t.memory[addr..][0..2], .big);
}

fn writeWord(t: ObjectTable, addr: usize, value: u16) Error!void {
    if (addr + 1 >= t.memory.len) return error.MemoryOutOfBounds;
    std.mem.writeInt(u16, t.memory[addr..][0..2], value, .big);
}

fn readByte(t: ObjectTable, addr: usize) Error!u8 {
    if (addr >= t.memory.len) return error.MemoryOutOfBounds;
    return t.memory[addr];
}

pub fn entry(t: ObjectTable, obj: u16) Error!usize {
    if (obj == 0) return error.InvalidObject;
    const addr = t.base + t.defaultsSize() + (@as(usize, obj) - 1) * t.entrySize();
    if (addr + t.entrySize() > t.memory.len) return error.InvalidObject;
    return addr;
}

/// Estimates the number of objects: the object entries end where the first
/// property table begins.
pub fn count(t: ObjectTable) u16 {
    const first = t.base + t.defaultsSize();
    var lowest_props: usize = t.memory.len;
    var n: u16 = 0;
    while (n < t.maxObject()) {
        const addr = first + @as(usize, n) * t.entrySize();
        if (addr + t.entrySize() > lowest_props) break;
        const props = t.propTableAt(addr) catch break;
        if (props < first or props >= t.memory.len) break;
        lowest_props = @min(lowest_props, props);
        n += 1;
    }
    return n;
}

fn propTableAt(t: ObjectTable, entry_addr: usize) Error!usize {
    return @as(usize, try t.readWord(entry_addr + (if (t.wide()) @as(usize, 12) else 7)));
}

const Link = enum { parent, sibling, child };

fn link(t: ObjectTable, obj: u16, which: Link) Error!u16 {
    if (obj == 0) return 0;
    const addr = try t.entry(obj);
    const index: usize = @backingInt(which);
    if (t.wide()) return t.readWord(addr + 6 + index * 2);
    return @as(u16, try t.readByte(addr + 4 + index));
}

fn setLink(t: ObjectTable, obj: u16, which: Link, value: u16) Error!void {
    const addr = try t.entry(obj);
    const index: usize = @backingInt(which);
    if (t.wide()) {
        try t.writeWord(addr + 6 + index * 2, value);
    } else {
        t.memory[addr + 4 + index] = @truncate(value);
    }
}

pub fn parent(t: ObjectTable, obj: u16) Error!u16 {
    return t.link(obj, .parent);
}

pub fn sibling(t: ObjectTable, obj: u16) Error!u16 {
    return t.link(obj, .sibling);
}

pub fn child(t: ObjectTable, obj: u16) Error!u16 {
    return t.link(obj, .child);
}

pub fn attribute(t: ObjectTable, obj: u16, attr: u16) Error!bool {
    if (obj == 0 or attr >= t.attributeCount()) return false;
    const addr = try t.entry(obj);
    const byte = t.memory[addr + attr / 8];
    return byte & (@as(u8, 0x80) >> @intCast(attr % 8)) != 0;
}

pub fn setAttribute(t: ObjectTable, obj: u16, attr: u16, on: bool) Error!void {
    if (obj == 0 or attr >= t.attributeCount()) return;
    const addr = try t.entry(obj);
    const mask = @as(u8, 0x80) >> @intCast(attr % 8);
    if (on) {
        t.memory[addr + attr / 8] |= mask;
    } else {
        t.memory[addr + attr / 8] &= ~mask;
    }
}

/// Detaches `obj` from its parent, leaving its own children intact.
pub fn remove(t: ObjectTable, obj: u16) Error!void {
    if (obj == 0) return;
    const p = try t.parent(obj);
    if (p == 0) return;
    const next = try t.sibling(obj);
    const first = try t.child(p);
    if (first == obj) {
        try t.setLink(p, .child, next);
    } else {
        var cur = first;
        var guard: usize = 0;
        while (cur != 0) : (guard += 1) {
            if (guard > 0xffff) return error.InvalidObject;
            const sib = try t.sibling(cur);
            if (sib == obj) {
                try t.setLink(cur, .sibling, next);
                break;
            }
            cur = sib;
        }
    }
    try t.setLink(obj, .parent, 0);
    try t.setLink(obj, .sibling, 0);
}

/// Makes `obj` the first child of `dest`.
pub fn insert(t: ObjectTable, obj: u16, dest: u16) Error!void {
    if (obj == 0 or dest == 0) return;
    try t.remove(obj);
    try t.setLink(obj, .sibling, try t.child(dest));
    try t.setLink(dest, .child, obj);
    try t.setLink(obj, .parent, dest);
}

pub fn propTable(t: ObjectTable, obj: u16) Error!usize {
    return t.propTableAt(try t.entry(obj));
}

/// Address of the encoded short name and its length in words.
pub fn name(t: ObjectTable, obj: u16) Error!struct { addr: usize, words: u8 } {
    const table = try t.propTable(obj);
    return .{ .addr = table + 1, .words = try t.readByte(table) };
}

pub fn firstProperty(t: ObjectTable, obj: u16) Error!usize {
    const table = try t.propTable(obj);
    return table + 1 + @as(usize, try t.readByte(table)) * 2;
}

/// Decodes the property whose size byte is at `addr`, or returns null at
/// the end of the list.
pub fn propertyAt(t: ObjectTable, addr: usize) Error!?Property {
    const b = try t.readByte(addr);
    if (b == 0) return null;
    if (!t.wide()) {
        const size = @as(usize, b >> 5) + 1;
        return .{ .number = b & 0x1f, .data = addr + 1, .size = size, .next = addr + 1 + size };
    }
    if (b & 0x80 != 0) {
        var size: usize = (try t.readByte(addr + 1)) & 0x3f;
        if (size == 0) size = 64;
        return .{ .number = b & 0x3f, .data = addr + 2, .size = size, .next = addr + 2 + size };
    }
    const size: usize = if (b & 0x40 != 0) 2 else 1;
    return .{ .number = b & 0x3f, .data = addr + 1, .size = size, .next = addr + 1 + size };
}

pub fn findProperty(t: ObjectTable, obj: u16, number: u16) Error!?Property {
    var addr = try t.firstProperty(obj);
    while (try t.propertyAt(addr)) |prop| : (addr = prop.next) {
        if (prop.number == number) return prop;
        // Properties are stored in descending order.
        if (prop.number < number) break;
    }
    return null;
}

pub fn getProperty(t: ObjectTable, obj: u16, number: u16) Error!u16 {
    if (try t.findProperty(obj, number)) |prop| {
        return switch (prop.size) {
            1 => @as(u16, try t.readByte(prop.data)),
            else => t.readWord(prop.data),
        };
    }
    if (number == 0 or number > (if (t.wide()) @as(u16, 63) else 31)) return error.InvalidProperty;
    return t.readWord(t.base + (@as(usize, number) - 1) * 2);
}

pub fn putProperty(t: ObjectTable, obj: u16, number: u16, value: u16) Error!void {
    const prop = (try t.findProperty(obj, number)) orelse return error.InvalidProperty;
    if (prop.size == 1) {
        t.memory[prop.data] = @truncate(value);
    } else {
        try t.writeWord(prop.data, value);
    }
}

pub fn propertyAddress(t: ObjectTable, obj: u16, number: u16) Error!u16 {
    if (obj == 0) return 0;
    const prop = (try t.findProperty(obj, number)) orelse return 0;
    return @intCast(prop.data);
}

/// Number of the property after `number`, or the first if `number` is 0.
pub fn nextProperty(t: ObjectTable, obj: u16, number: u16) Error!u16 {
    if (obj == 0) return 0;
    var addr = try t.firstProperty(obj);
    if (number != 0) {
        const prop = (try t.findProperty(obj, number)) orelse return error.InvalidProperty;
        addr = prop.next;
    }
    const next = (try t.propertyAt(addr)) orelse return 0;
    return next.number;
}

/// Length of the property whose data starts at `data_addr`.
pub fn propertyLength(t: ObjectTable, data_addr: u16) Error!u16 {
    if (data_addr == 0) return 0;
    const b = try t.readByte(data_addr - 1);
    if (!t.wide()) return (b >> 5) + 1;
    if (b & 0x80 != 0) {
        const size = b & 0x3f;
        return if (size == 0) 64 else size;
    }
    return if (b & 0x40 != 0) 2 else 1;
}
