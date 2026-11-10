//! Crash reports for the tray app. A GUI-subsystem process has no stderr, so Zig's
//! panic and segfault reports (message + stack trace) would vanish. Before they are
//! written, stderr is pointed at `crash.log` next to the exe; with a console or a pipe
//! (CLI, MCP) the report goes there as usual.
//!
//! The exe ships without its .pdb, so frames show as raw addresses; the image base in
//! the header turns them into offsets that `annotation-helper.pdb` can resolve.

const std = @import("std");
const w = @import("win32").everything;
const util = @import("util.zig");

pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    toCrashLog();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
    @branchHint(.cold);
    toCrashLog();
    std.debug.defaultHandleSegfault(addr, name, ctx);
}

var redirected = std.atomic.Value(bool).init(false);

fn toCrashLog() void {
    if (comptime !util.is_windows) return;
    if (util.stdHandle(w.STD_ERROR_HANDLE) != null) return;
    if (redirected.swap(true, .acq_rel)) return; // another thread is already reporting

    var buf: [1024]u16 = undefined;
    const exe = util.exePathW(&buf);
    const dir_len = std.mem.lastIndexOfScalar(u16, exe, '\\') orelse return;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\crash.log");
    if (dir_len + name.len + 1 > buf.len) return;
    @memcpy(buf[dir_len..][0..name.len], name);
    buf[dir_len + name.len] = 0;
    const path: [*:0]const u16 = @ptrCast(&buf);

    // Append, so an earlier report survives a second crash.
    const h = w.CreateFileW(path, .{ .FILE_APPEND_DATA = 1, .SYNCHRONIZE = 1 }, .{ .READ = 1 }, null, w.OPEN_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return;
    var t: w.SYSTEMTIME = undefined;
    w.GetLocalTime(&t);
    var hdr: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&hdr, "\r\n=== annotation-helper crashed {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} (image base 0x{x}) ===\r\n", .{
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, @intFromPtr(w.GetModuleHandleW(null)),
    }) catch return;
    util.writeHandle(h, line) catch {};
    _ = w.SetStdHandle(w.STD_ERROR_HANDLE, h);
}
