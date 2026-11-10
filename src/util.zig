//! Helpers for files, directories, processes, clipboard, time and logging.
//! Windows uses Win32 directly (thread-safe, independent of std I/O churn); Linux uses
//! std.Io for files and libc (src/linux/sys.zig) for processes and time.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("win32").everything;
const lsys = @import("linux/sys.zig");

pub const is_windows = builtin.os.tag == .windows;

/// Blocking std.Io for the Linux build.
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Allocator = std.mem.Allocator;
/// libc malloc (UCRT): small, thread-safe, returns memory to the OS.
pub const gpa: Allocator = std.heap.c_allocator;

pub const L = w.L;

/// Zig's default thread stack is 16 MiB and, on Windows, *committed* up front
/// (not just reserved). 512 KiB is plenty for these threads.
pub const thread_cfg: std.Thread.SpawnConfig = .{ .stack_size = 512 * 1024 };

pub fn wide(a: Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s);
}

pub fn narrow(a: Allocator, s: []const u16) ![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(a, s);
}

/// UTF-8 → fixed UTF-16 buffer, truncated, always NUL-terminated.
pub fn wideInto(dst: []u16, s: []const u8) [:0]u16 {
    var n: usize = 0;
    var it = std.unicode.Wtf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            if (n + 3 > dst.len) break;
            const v = cp - 0x10000;
            dst[n] = @intCast(0xD800 + (v >> 10));
            dst[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        } else {
            if (n + 2 > dst.len) break;
            dst[n] = @intCast(cp);
            n += 1;
        }
    }
    dst[n] = 0;
    return dst[0..n :0];
}

// ------------------------------------------------------------------ logging

var log_handle: ?w.HANDLE = null;

pub fn initLog() void {
    if (comptime is_windows) log_handle = stdHandle(w.STD_ERROR_HANDLE);
}

/// Write to stdout (the MCP channel).
pub fn writeStdout(bytes: []const u8) !void {
    if (comptime !is_windows) return std.Io.File.stdout().writeStreamingAll(io(), bytes);
    try writeHandle(stdHandle(w.STD_OUTPUT_HANDLE) orelse return error.NoStdout, bytes);
}

/// Read what is available on stdin; 0 = end of input.
pub fn readStdin(buf: []u8) usize {
    if (comptime !is_windows) return std.Io.File.stdin().readStreaming(io(), &.{buf}) catch 0;
    const h = stdHandle(w.STD_INPUT_HANDLE) orelse return 0;
    var n: u32 = 0;
    if (w.ReadFile(h, buf.ptr, @intCast(@min(buf.len, 1 << 30)), &n, null) == 0) return 0;
    return n;
}

pub fn stdHandle(which: w.STD_HANDLE) ?w.HANDLE {
    const h = w.GetStdHandle(which);
    if (h == w.INVALID_HANDLE_VALUE or @intFromPtr(h) == 0) return null;
    return h;
}

/// Status output on stderr (stdout may be the MCP channel). Silent without a console.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (comptime !is_windows) return std.debug.print(fmt ++ "\n", args);
    const h = log_handle orelse return;
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\r\n", args) catch return;
    var written: u32 = 0;
    _ = w.WriteFile(h, s.ptr, @intCast(s.len), &written, null);
}

pub fn writeHandle(h: w.HANDLE, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        var n: u32 = 0;
        const chunk: u32 = @intCast(@min(bytes.len - off, 1 << 30));
        if (w.WriteFile(h, bytes.ptr + off, chunk, &n, null) == 0) return error.WriteFailed;
        off += n;
    }
}

// ------------------------------------------------------------------ files

pub fn exists(path: []const u8) bool {
    if (comptime !is_windows) {
        std.Io.Dir.cwd().access(io(), path, .{}) catch return false;
        return true;
    }
    var buf: [1024]u16 = undefined;
    return w.GetFileAttributesW(wideInto(&buf, path)) != w.INVALID_FILE_ATTRIBUTES;
}

pub fn isDir(path: []const u8) bool {
    if (comptime !is_windows) {
        const st = std.Io.Dir.cwd().statFile(io(), path, .{}) catch return false;
        return st.kind == .directory;
    }
    var buf: [1024]u16 = undefined;
    const attr = w.GetFileAttributesW(wideInto(&buf, path));
    return attr != w.INVALID_FILE_ATTRIBUTES and attr & @as(u32, @bitCast(w.FILE_ATTRIBUTE_DIRECTORY)) != 0;
}

pub fn readFile(a: Allocator, path: []const u8) ![]u8 {
    if (comptime !is_windows) return std.Io.Dir.cwd().readFileAlloc(io(), path, a, .unlimited);
    var buf: [1024]u16 = undefined;
    const h = w.CreateFileW(wideInto(&buf, path), w.FILE_GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.FileNotFound;
    defer _ = w.CloseHandle(h);
    var size: w.LARGE_INTEGER = undefined;
    if (w.GetFileSizeEx(h, &size) == 0) return error.ReadFailed;
    const len: usize = @intCast(size.QuadPart);
    const out = try a.alloc(u8, len);
    errdefer a.free(out);
    var off: usize = 0;
    while (off < len) {
        var n: u32 = 0;
        if (w.ReadFile(h, out.ptr + off, @intCast(@min(len - off, 1 << 30)), &n, null) == 0 or n == 0) return error.ReadFailed;
        off += n;
    }
    return out;
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (comptime !is_windows) return std.Io.Dir.cwd().writeFile(io(), .{ .sub_path = path, .data = bytes });
    var buf: [1024]u16 = undefined;
    const h = w.CreateFileW(wideInto(&buf, path), w.FILE_GENERIC_WRITE, .{}, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.CreateFailed;
    defer _ = w.CloseHandle(h);
    try writeHandle(h, bytes);
}

pub fn mkdirAll(path: []const u8) !void {
    if (comptime !is_windows) return std.Io.Dir.cwd().createDirPath(io(), path);
    if (path.len == 0 or isDir(path)) return;
    if (std.fs.path.dirnameWindows(path)) |parent| try mkdirAll(parent);
    var buf: [1024]u16 = undefined;
    if (w.CreateDirectoryW(wideInto(&buf, path), null) == 0 and !isDir(path)) return error.MkdirFailed;
}

/// Names of the entries in `dir` (no "." / ".."). Caller frees with freeNames.
pub fn listDir(a: Allocator, dir: []const u8, dirs_only: bool) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer freeNames(a, names.items);
    if (comptime !is_windows) {
        var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return names.toOwnedSlice(a);
        defer d.close(io());
        var it = d.iterate();
        while (try it.next(io())) |e| {
            if (dirs_only and e.kind != .directory) continue;
            try names.append(a, try a.dupe(u8, e.name));
        }
        return names.toOwnedSlice(a);
    }
    const pattern = try a.print("{s}\\*", .{dir});
    defer a.free(pattern);
    var buf: [1024]u16 = undefined;
    var fd: w.WIN32_FIND_DATAW = undefined;
    const h = w.FindFirstFileW(wideInto(&buf, pattern), &fd);
    if (h == -1) return names.toOwnedSlice(a);
    defer _ = w.FindClose(h);
    while (true) {
        const name16 = std.mem.sliceTo(&fd.cFileName, 0);
        const is_dir = fd.dwFileAttributes & @as(u32, @bitCast(w.FILE_ATTRIBUTE_DIRECTORY)) != 0;
        if (!(name16.len == 1 and name16[0] == '.') and !(name16.len == 2 and name16[0] == '.' and name16[1] == '.') and (is_dir or !dirs_only)) {
            try names.append(a, try narrow(a, name16));
        }
        if (w.FindNextFileW(h, &fd) == 0) break;
    }
    return names.toOwnedSlice(a);
}

pub fn freeNames(a: Allocator, names: []const []u8) void {
    for (names) |n| a.free(n);
    a.free(names);
}

/// Deletes a flat folder (files only) and the folder itself.
pub fn deleteFlatDir(a: Allocator, dir: []const u8) void {
    const names = listDir(a, dir, false) catch return;
    defer freeNames(a, names);
    if (comptime !is_windows) {
        var zb: [4096]u8 = undefined;
        for (names) |n| {
            const p = std.fmt.bufPrintSentinel(&zb, "{s}/{s}", .{ dir, n }, 0) catch continue;
            _ = lsys.unlink(p.ptr);
        }
        const d = std.fmt.bufPrintSentinel(&zb, "{s}", .{dir}, 0) catch return;
        _ = lsys.rmdir(d.ptr);
        return;
    }
    var buf: [1024]u16 = undefined;
    for (names) |n| {
        const p = std.fs.path.join(a, &.{ dir, n }) catch continue;
        defer a.free(p);
        _ = w.DeleteFileW(wideInto(&buf, p));
    }
    _ = w.RemoveDirectoryW(wideInto(&buf, dir));
}

pub fn exeDir(a: Allocator) ![]u8 {
    if (comptime !is_windows) {
        var pbuf: [4096]u8 = undefined;
        const n = try std.process.executableDirPath(io(), &pbuf);
        return a.dupe(u8, pbuf[0..n]);
    }
    var buf: [1024]u16 = undefined;
    const n = w.GetModuleFileNameW(null, @ptrCast(&buf), buf.len);
    if (n == 0) return error.NoExePath;
    const path = try narrow(a, buf[0..n]);
    defer a.free(path);
    return a.dupe(u8, std.fs.path.dirnameWindows(path) orelse ".");
}

/// Full path of the running executable (Linux).
pub fn exePath(a: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const n = lsys.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return error.NoExePath;
    return a.dupe(u8, buf[0..@intCast(n)]);
}

pub fn exePathW(buf: *[1024]u16) [:0]u16 {
    const n = w.GetModuleFileNameW(null, @ptrCast(buf), buf.len);
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn join(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

// ------------------------------------------------------------------ processes

/// Runs `exe args…` (args already quoted), output to `log_path`; waits; returns the exit code.
pub fn runProcess(a: Allocator, cmdline: []const u8, log_path: []const u8) !u32 {
    var sa = w.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = w.TRUE };
    var pbuf: [1024]u16 = undefined;
    const logh = w.CreateFileW(wideInto(&pbuf, log_path), w.FILE_GENERIC_WRITE, .{ .READ = 1 }, &sa, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (logh == w.INVALID_HANDLE_VALUE) return error.LogFile;
    defer _ = w.CloseHandle(logh);
    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    si.dwFlags = w.STARTF_USESTDHANDLES;
    si.hStdInput = null;
    si.hStdOutput = logh;
    si.hStdError = logh;
    var pi: w.PROCESS_INFORMATION = undefined;
    const cmd = try wide(a, cmdline);
    defer a.free(cmd);
    if (w.CreateProcessW(null, cmd.ptr, null, null, w.TRUE, .{ .CREATE_NO_WINDOW = 1 }, null, null, &si, &pi) == 0) return error.SpawnFailed;
    defer _ = w.CloseHandle(pi.hProcess);
    defer _ = w.CloseHandle(pi.hThread);
    _ = w.WaitForSingleObject(pi.hProcess, w.INFINITE);
    var code: u32 = 1;
    _ = w.GetExitCodeProcess(pi.hProcess, &code);
    return code;
}

/// A child process whose stdin we hold (Windows), e.g. live transcription.
pub const PipedProcess = struct {
    process: w.HANDLE,
    stdin: w.HANDLE,

    /// Closes the child's stdin and waits for it; returns its exit code.
    pub fn finish(p: PipedProcess) u32 {
        _ = w.CloseHandle(p.stdin);
        _ = w.WaitForSingleObject(p.process, w.INFINITE);
        var code: u32 = 1;
        _ = w.GetExitCodeProcess(p.process, &code);
        _ = w.CloseHandle(p.process);
        return code;
    }

    /// Tells the child to stop without output, then waits (at most 30 s).
    pub fn cancel(p: PipedProcess) void {
        var n: u32 = 0;
        _ = w.WriteFile(p.stdin, "cancel\n", 7, &n, null);
        _ = w.CloseHandle(p.stdin);
        if (w.WaitForSingleObject(p.process, 30_000) != .NO_ERROR) _ = w.TerminateProcess(p.process, 1);
        _ = w.CloseHandle(p.process);
    }
};

/// Starts `cmdline` (args already quoted) with stdin from a pipe we keep and output to `log_path`.
pub fn spawnPiped(a: Allocator, cmdline: []const u8, log_path: []const u8) !PipedProcess {
    var sa = w.SECURITY_ATTRIBUTES{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = w.TRUE };
    var rd: ?w.HANDLE = null;
    var wr: ?w.HANDLE = null;
    if (w.CreatePipe(&rd, &wr, &sa, 0) == 0) return error.PipeFailed;
    // Only the read end is inherited; our end must not leak into the child.
    _ = w.SetHandleInformation(wr, @bitCast(w.HANDLE_FLAG_INHERIT), .{});
    defer _ = w.CloseHandle(rd);
    var pbuf: [1024]u16 = undefined;
    const logh = w.CreateFileW(wideInto(&pbuf, log_path), w.FILE_GENERIC_WRITE, .{ .READ = 1 }, &sa, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (logh == w.INVALID_HANDLE_VALUE) {
        _ = w.CloseHandle(wr);
        return error.LogFile;
    }
    defer _ = w.CloseHandle(logh);
    var si = std.mem.zeroes(w.STARTUPINFOW);
    si.cb = @sizeOf(w.STARTUPINFOW);
    si.dwFlags = w.STARTF_USESTDHANDLES;
    si.hStdInput = rd;
    si.hStdOutput = logh;
    si.hStdError = logh;
    var pi: w.PROCESS_INFORMATION = undefined;
    const cmd = try wide(a, cmdline);
    defer a.free(cmd);
    if (w.CreateProcessW(null, cmd.ptr, null, null, w.TRUE, .{ .CREATE_NO_WINDOW = 1 }, null, null, &si, &pi) == 0) {
        _ = w.CloseHandle(wr);
        return error.SpawnFailed;
    }
    _ = w.CloseHandle(pi.hThread);
    return .{ .process = pi.hProcess.?, .stdin = wr.? };
}

pub fn processName(a: Allocator, pid: u32) []u8 {
    const h = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, w.FALSE, pid) orelse return a.dupe(u8, "") catch &.{};
    defer _ = w.CloseHandle(h);
    var buf: [1024]u16 = undefined;
    var len: u32 = buf.len;
    if (w.QueryFullProcessImageNameW(h, w.PROCESS_NAME_WIN32, @ptrCast(&buf), &len) == 0) return a.dupe(u8, "") catch &.{};
    const full = buf[0..len];
    const slash = std.mem.lastIndexOfScalar(u16, full, '\\');
    return narrow(a, if (slash) |i| full[i + 1 ..] else full) catch &.{};
}

pub const WindowInfo = struct { title: []u8, process: []u8 };

pub fn windowInfo(a: Allocator, hwnd: ?w.HWND) ?WindowInfo {
    const h0 = hwnd orelse return null;
    const root = w.GetAncestor(h0, w.GA_ROOT) orelse h0;
    var buf: [512]u16 = undefined;
    const n = w.GetWindowTextW(root, @ptrCast(&buf), buf.len);
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(root, &pid);
    return .{ .title = narrow(a, buf[0..@intCast(@max(n, 0))]) catch return null, .process = processName(a, pid) };
}

// ------------------------------------------------------------------ misc

pub fn setClipboard(text: []const u8) !void {
    if (comptime !is_windows) return setClipboardLinux(text);
    const w16 = try wide(gpa, text);
    defer gpa.free(w16);
    if (w.OpenClipboard(null) == 0) return error.Clipboard;
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    const bytes = (w16.len + 1) * 2;
    const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes);
    if (mem == 0) return error.OutOfMemory;
    const ptr: [*]u16 = @ptrCast(@alignCast(w.GlobalLock(mem) orelse return error.Clipboard));
    @memcpy(ptr[0 .. w16.len + 1], w16[0 .. w16.len + 1]);
    _ = w.GlobalUnlock(mem);
    if (w.SetClipboardData(@intFromEnum(w.CF_UNICODETEXT), @ptrFromInt(@as(usize, @bitCast(mem)))) == null) return error.Clipboard;
}

/// Linux: hands the text to wl-copy (Wayland), xclip or xsel (X11); the clipboard
/// needs a process that stays around, and these tools do that.
fn setClipboardLinux(text: []const u8) !void {
    const wayland = lsys.env("WAYLAND_DISPLAY") != null;
    const tools = [_]struct { wl: bool, argv: []const []const u8 }{
        .{ .wl = true, .argv = &.{"wl-copy"} },
        .{ .wl = false, .argv = &.{ "xclip", "-selection", "clipboard" } },
        .{ .wl = false, .argv = &.{ "xsel", "--clipboard", "--input" } },
    };
    for (tools) |t| {
        if (t.wl != wayland and !(t.wl == false and lsys.env("DISPLAY") != null)) continue;
        if (!lsys.inPath(t.argv[0])) continue;
        var fds: [2]c_int = undefined;
        if (lsys.pipe2(&fds, lsys.O_CLOEXEC) != 0) return error.Clipboard;
        const pid = lsys.spawn(gpa, t.argv, .{ .stdin_fd = fds[0] }) catch {
            _ = lsys.close(fds[0]);
            _ = lsys.close(fds[1]);
            continue;
        };
        _ = lsys.close(fds[0]);
        var off: usize = 0;
        while (off < text.len) {
            const n = lsys.write(fds[1], text[off..].ptr, text.len - off);
            if (n <= 0) break;
            off += @intCast(n);
        }
        _ = lsys.close(fds[1]);
        if (lsys.wait(pid) == 0) return;
    }
    return error.NoClipboardTool;
}

pub const Timestamp = struct { id: [19]u8, human: [19]u8 };

/// ("2026-10-28_14-03-12", "2026-10-28 14:03:12")
pub fn localTimestamp() Timestamp {
    if (comptime !is_windows) {
        const now = lsys.time(null);
        var tm: lsys.Tm = undefined;
        _ = lsys.localtime_r(&now, &tm);
        const y: u32 = @intCast(tm.year + 1900);
        const mo: u32 = @intCast(tm.mon + 1);
        const v = [_]u32{ @intCast(tm.mday), @intCast(tm.hour), @intCast(tm.min), @intCast(tm.sec) };
        var r: Timestamp = undefined;
        _ = std.fmt.bufPrint(&r.id, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{ y, mo, v[0], v[1], v[2], v[3] }) catch unreachable;
        _ = std.fmt.bufPrint(&r.human, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ y, mo, v[0], v[1], v[2], v[3] }) catch unreachable;
        return r;
    }
    var t: w.SYSTEMTIME = undefined;
    w.GetLocalTime(&t);
    var r: Timestamp = undefined;
    _ = std.fmt.bufPrint(&r.id, "{d:0>4}-{d:0>2}-{d:0>2}_{d:0>2}-{d:0>2}-{d:0>2}", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond }) catch unreachable;
    _ = std.fmt.bufPrint(&r.human, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond }) catch unreachable;
    return r;
}

pub fn fmtTime(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(@max(ms, 0), 1000);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @divTrunc(s, 60), @mod(s, 60) }) catch "??:??";
}

/// Milliseconds from a monotonic clock.
pub fn nowMs() u64 {
    if (comptime !is_windows) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }
    var f: i64 = 0;
    var c: i64 = 0;
    _ = w.QueryPerformanceFrequency(@ptrCast(&f));
    _ = w.QueryPerformanceCounter(@ptrCast(&c));
    return @intCast(@divTrunc(@as(i128, c) * 1000, f));
}

/// `C:\Users\x` → `/mnt/c/Users/x`, `\\wsl.localhost\Ubuntu\home\x` → `/home/x`.
pub fn wslPath(a: Allocator, p: []const u8) !?[]u8 {
    var s = p;
    if (std.mem.startsWith(u8, s, "\\\\?\\")) s = s[4..];
    for ([_][]const u8{ "\\\\wsl.localhost\\", "\\\\wsl$\\" }) |prefix| {
        if (std.mem.startsWith(u8, s, prefix)) {
            const rest = s[prefix.len..];
            const i = std.mem.indexOfScalar(u8, rest, '\\') orelse return null;
            const out = try a.print("/{s}", .{rest[i + 1 ..]});
            std.mem.replaceScalar(u8, out, '\\', '/');
            return out;
        }
    }
    if (s.len > 2 and s[1] == ':' and std.ascii.isAlphabetic(s[0])) {
        const out = try a.print("/mnt/{c}{s}", .{ std.ascii.toLower(s[0]), s[2..] });
        std.mem.replaceScalar(u8, out, '\\', '/');
        return out;
    }
    return null;
}
