//! Platform terminal control: window size, unbuffered key input and
//! restoring the terminal on interrupt, for POSIX terminals and the Windows
//! console.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const posix = std.posix;
const windows = std.os.windows;

const is_windows = builtin.os.tag == .windows;

pub const Error = posix.TermiosSetError;

/// Returns the terminal's columns and rows, if stdout is a terminal.
pub fn size() ?[2]u16 {
    const fd = Io.File.stdout().handle;
    if (is_windows) {
        var info: kernel32.ScreenBufferInfo = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(fd, &info) == 0) return null;
        const w = info.window;
        return .{ @intCast(w.right - w.left + 1), @intCast(w.bottom - w.top + 1) };
    }
    var ws: posix.winsize = undefined;
    // libc's ioctl is variadic; the raw Linux syscall takes the pointer as
    // an integer.
    const rc = if (builtin.link_libc)
        std.c.ioctl(fd, posix.T.IOCGWINSZ, &ws)
    else
        posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) != .SUCCESS) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ ws.col, ws.row };
}

const Mode = if (is_windows) u32 else posix.termios;

/// The input mode raw mode replaced, while it is on, so an interrupt can
/// put it back.
var raw_saved: ?Mode = null;

/// Stdin switched to unbuffered, unechoed input until `leave`. On Windows,
/// arrow keys then arrive as the same escape sequences as on a POSIX
/// terminal.
pub const RawMode = struct {
    saved: Mode,

    pub fn enter() Error!RawMode {
        const fd = Io.File.stdin().handle;
        if (is_windows) {
            var mode: u32 = 0;
            if (kernel32.GetConsoleMode(fd, &mode) == 0) return .{ .saved = 0 };
            const raw = (mode & ~(kernel32.ENABLE_LINE_INPUT | kernel32.ENABLE_ECHO_INPUT)) |
                kernel32.ENABLE_VIRTUAL_TERMINAL_INPUT;
            raw_saved = mode;
            _ = kernel32.SetConsoleMode(fd, raw);
            return .{ .saved = mode };
        }
        const saved = try posix.tcgetattr(fd);
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        raw_saved = saved;
        try posix.tcsetattr(fd, .NOW, raw);
        return .{ .saved = saved };
    }

    pub fn leave(r: RawMode) void {
        raw_saved = null;
        const fd = Io.File.stdin().handle;
        if (is_windows) {
            if (r.saved != 0) _ = kernel32.SetConsoleMode(fd, r.saved);
        } else {
            posix.tcsetattr(fd, .NOW, r.saved) catch {};
        }
    }
};

/// On Ctrl-C (and SIGTERM), writes `reset` to stdout, leaves raw mode and
/// exits with status 130, so neither escape-sequence state such as a scroll
/// region nor unechoed input outlives the process.
pub fn restoreOnInterrupt(comptime reset: []const u8) void {
    const Handler = struct {
        fn onSignal(sig: posix.SIG) callconv(.c) void {
            _ = sig;
            _ = posix.system.write(Io.File.stdout().handle, reset.ptr, reset.len);
            if (raw_saved) |mode| posix.tcsetattr(Io.File.stdin().handle, .NOW, mode) catch {};
            std.process.exit(130);
        }

        fn onCtrl(ctrl_type: u32) callconv(.winapi) c_int {
            _ = ctrl_type;
            var written: u32 = 0;
            _ = kernel32.WriteFile(Io.File.stdout().handle, reset.ptr, reset.len, &written, null);
            if (raw_saved) |mode| _ = kernel32.SetConsoleMode(Io.File.stdin().handle, mode);
            std.process.exit(130);
        }
    };
    if (is_windows) {
        _ = kernel32.SetConsoleCtrlHandler(Handler.onCtrl, 1);
        return;
    }
    const action: posix.Sigaction = .{
        .handler = .{ .handler = Handler.onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
}

const kernel32 = struct {
    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_ECHO_INPUT: u32 = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;

    const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };

    const ScreenBufferInfo = extern struct {
        size: windows.COORD,
        cursor: windows.COORD,
        attributes: u16,
        window: SmallRect,
        maximum_size: windows.COORD,
    };

    extern "kernel32" fn GetConsoleMode(console: windows.HANDLE, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(console: windows.HANDLE, mode: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleScreenBufferInfo(console: windows.HANDLE, info: *ScreenBufferInfo) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) c_int,
        add: c_int,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(
        file: windows.HANDLE,
        buffer: [*]const u8,
        len: u32,
        written: ?*u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) c_int;
};
