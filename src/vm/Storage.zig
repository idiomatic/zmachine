//! Where the machine keeps saved games and the transcript.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Storage = @This();

context: *anyopaque,
vtable: *const VTable,

/// Errors are reported to the player by name, so any may be returned.
pub const VTable = struct {
    save: *const fn (context: *anyopaque, name: []const u8, data: []const u8) anyerror!void,
    restore: *const fn (context: *anyopaque, name: []const u8, gpa: Allocator) anyerror![]u8,
    transcript: *const fn (context: *anyopaque, name: []const u8) ?*Io.Writer,
};

/// Writes a saved game called `name`.
pub fn save(s: Storage, name: []const u8, data: []const u8) anyerror!void {
    return s.vtable.save(s.context, name, data);
}

/// Reads the saved game called `name`; the caller frees it.
pub fn restore(s: Storage, name: []const u8, gpa: Allocator) anyerror![]u8 {
    return s.vtable.restore(s.context, name, gpa);
}

/// Opens the transcript called `name`, or returns null if it can't. The
/// storage owns the writer; the machine flushes it.
pub fn transcript(s: Storage, name: []const u8) ?*Io.Writer {
    return s.vtable.transcript(s.context, name);
}

/// Saves and the transcript in the working directory.
pub const Cwd = struct {
    io: Io,
    gpa: Allocator,
    file: ?Io.File.Writer = null,
    buf: [4096]u8 = undefined,

    pub fn init(gpa: Allocator, io: Io) Cwd {
        return .{ .gpa = gpa, .io = io };
    }

    /// Closes the transcript.
    pub fn deinit(c: *Cwd) void {
        if (c.file) |*f| {
            f.interface.flush() catch {};
            f.file.close(c.io);
            c.file = null;
        }
    }

    pub fn storage(c: *Cwd) Storage {
        return .{ .context = c, .vtable = &.{
            .save = saveCwd,
            .restore = restoreCwd,
            .transcript = transcriptCwd,
        } };
    }

    fn saveCwd(context: *anyopaque, name: []const u8, data: []const u8) anyerror!void {
        const c: *Cwd = @ptrCast(@alignCast(context));
        try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = name, .data = data });
    }

    fn restoreCwd(context: *anyopaque, name: []const u8, gpa: Allocator) anyerror![]u8 {
        const c: *Cwd = @ptrCast(@alignCast(context));
        return Io.Dir.cwd().readFileAlloc(c.io, name, gpa, .limited(1 << 20));
    }

    fn transcriptCwd(context: *anyopaque, name: []const u8) ?*Io.Writer {
        const c: *Cwd = @ptrCast(@alignCast(context));
        if (c.file == null) {
            const file = Io.Dir.cwd().createFile(c.io, name, .{}) catch return null;
            c.file = .initStreaming(file, c.io, &c.buf);
        }
        return &c.file.?.interface;
    }
};
