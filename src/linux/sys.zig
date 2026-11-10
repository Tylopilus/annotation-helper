//! Thin libc layer for the Linux build (x86_64 glibc only, like the rest of the build):
//! sockets with fd passing, poll, eventfd, shared memory, process spawning, pthread
//! locks and events. Declared here so the code doesn't depend on std's changing APIs.

const std = @import("std");

pub const fd_t = c_int;

// ------------------------------------------------------------------ externs

pub extern "c" fn socket(domain: c_int, kind: c_int, proto: c_int) c_int;
pub extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
pub extern "c" fn sendmsg(fd: c_int, msg: *const MsgHdr, flags: c_int) isize;
pub extern "c" fn recvmsg(fd: c_int, msg: *MsgHdr, flags: c_int) isize;
pub extern "c" fn send(fd: c_int, buf: [*]const u8, len: usize, flags: c_int) isize;
pub extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
pub extern "c" fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;
pub extern "c" fn eventfd(initval: c_uint, flags: c_int) c_int;
pub extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
pub extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
pub extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) ?*anyopaque;
pub extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
pub extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
pub extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern "c" fn unlink(path: [*:0]const u8) c_int;
pub extern "c" fn rmdir(path: [*:0]const u8) c_int;
pub extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
pub extern "c" fn getuid() c_uint;
pub extern "c" fn getpid() c_int;
pub extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
pub extern "c" fn signal(sig: c_int, handler: usize) usize;
pub extern "c" fn time(t: ?*i64) i64;
pub extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
pub extern "c" fn usleep(us: c_uint) c_int;
pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
pub extern "c" fn __errno_location() *c_int;
pub extern "c" fn dlopen(name: [*:0]const u8, flags: c_int) ?*anyopaque;
pub extern "c" fn dlsym(h: *anyopaque, name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn posix_spawn_file_actions_init(a: *anyopaque) c_int;
pub extern "c" fn posix_spawn_file_actions_destroy(a: *anyopaque) c_int;
pub extern "c" fn posix_spawn_file_actions_adddup2(a: *anyopaque, fd: c_int, newfd: c_int) c_int;
pub extern "c" fn posix_spawn_file_actions_addopen(a: *anyopaque, fd: c_int, path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
pub extern "c" fn posix_spawnattr_init(a: *anyopaque) c_int;
pub extern "c" fn posix_spawnattr_destroy(a: *anyopaque) c_int;
pub extern "c" fn posix_spawnattr_setflags(a: *anyopaque, flags: c_short) c_int;
pub extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
pub extern "c" fn pthread_mutex_init(m: *anyopaque, attr: ?*const anyopaque) c_int;
pub extern "c" fn pthread_mutex_lock(m: *anyopaque) c_int;
pub extern "c" fn pthread_mutex_unlock(m: *anyopaque) c_int;
pub extern "c" fn pthread_cond_init(c: *anyopaque, attr: ?*const anyopaque) c_int;
pub extern "c" fn pthread_cond_wait(c: *anyopaque, m: *anyopaque) c_int;
pub extern "c" fn pthread_cond_timedwait(c: *anyopaque, m: *anyopaque, ts: *const Timespec) c_int;
pub extern "c" fn pthread_cond_broadcast(c: *anyopaque) c_int;
pub extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
pub extern var environ: [*:null]?[*:0]u8;

pub const AF_UNIX = 1;
pub const SOCK_STREAM = 1;
pub const SOCK_CLOEXEC = 0o2000000;
pub const SOL_SOCKET = 1;
pub const SCM_RIGHTS = 1;
pub const MSG_NOSIGNAL = 0x4000;
pub const MSG_CMSG_CLOEXEC = 0x40000000;
pub const POLLIN: i16 = 1;
pub const POLLOUT: i16 = 4;
pub const POLLERR: i16 = 8;
pub const POLLHUP: i16 = 16;
pub const EFD_CLOEXEC = 0o2000000;
pub const EFD_NONBLOCK = 0o4000;
pub const MFD_CLOEXEC = 1;
pub const PROT_READ = 1;
pub const PROT_WRITE = 2;
pub const MAP_SHARED = 1;
pub const MAP_PRIVATE = 2;
pub const O_RDONLY = 0;
pub const O_WRONLY = 1;
pub const O_RDWR = 2;
pub const O_CREAT = 0o100;
pub const O_TRUNC = 0o1000;
pub const O_APPEND = 0o2000;
pub const O_CLOEXEC = 0o2000000;
pub const EINTR = 4;
pub const EAGAIN = 11;
pub const RTLD_NOW = 2;
pub const SIGINT = 2;
pub const SIGPIPE = 13;
pub const SIGTERM = 15;
pub const SIGHUP = 1;
pub const SIG_IGN: usize = 1;
pub const CLOCK_MONOTONIC = 1;
pub const CLOCK_REALTIME = 0;
pub const POSIX_SPAWN_SETSID: c_short = 0x80;
pub const ETIMEDOUT = 110;

pub const Timespec = extern struct { sec: i64, nsec: i64 };
pub const PollFd = extern struct { fd: c_int, events: i16, revents: i16 = 0 };
pub const IoVec = extern struct { base: [*]u8, len: usize };
pub const MsgHdr = extern struct {
    name: ?*anyopaque = null,
    namelen: u32 = 0,
    iov: [*]IoVec,
    iovlen: usize,
    control: ?*anyopaque = null,
    controllen: usize = 0,
    flags: c_int = 0,
};
pub const CmsgHdr = extern struct { len: usize, level: c_int, type: c_int };
pub const SockaddrUn = extern struct { family: u16 = AF_UNIX, path: [108]u8 = @splat(0) };
pub const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

pub fn errno() c_int {
    return __errno_location().*;
}

pub fn env(name: [:0]const u8) ?[]const u8 {
    const v = getenv(name.ptr) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

// ------------------------------------------------------------------ sockets

/// Connects a stream socket to a unix path; `abstract` uses the Linux abstract namespace.
pub fn connectUnix(path: []const u8, abstract: bool) !fd_t {
    var addr = SockaddrUn{};
    const off: usize = if (abstract) 1 else 0;
    if (path.len + off >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[off..][0..path.len], path);
    const fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return error.Socket;
    const len: u32 = @intCast(@sizeOf(u16) + off + path.len + @as(usize, if (abstract) 0 else 1));
    if (connect(fd, &addr, len) != 0) {
        _ = close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

pub fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = send(fd, bytes.ptr + off, bytes.len - off, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno() == EINTR) continue;
            if (errno() == EAGAIN) {
                var p = [1]PollFd{.{ .fd = fd, .events = POLLOUT }};
                _ = poll(&p, 1, 1000);
                continue;
            }
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

/// Sends bytes plus file descriptors (SCM_RIGHTS).
pub fn sendWithFds(fd: fd_t, bytes: []const u8, fds: []const fd_t) !void {
    if (fds.len == 0) return writeAll(fd, bytes);
    var ctrl: [64]u8 align(8) = @splat(0);
    const data_len = fds.len * @sizeOf(c_int);
    const cmsg_len = @sizeOf(CmsgHdr) + data_len;
    const h: *CmsgHdr = @ptrCast(&ctrl);
    h.* = .{ .len = cmsg_len, .level = SOL_SOCKET, .type = SCM_RIGHTS };
    @memcpy(ctrl[@sizeOf(CmsgHdr)..][0..data_len], std.mem.sliceAsBytes(fds));
    var iov = [1]IoVec{.{ .base = @constCast(bytes.ptr), .len = bytes.len }};
    const msg = MsgHdr{ .iov = &iov, .iovlen = 1, .control = &ctrl, .controllen = std.mem.alignForward(usize, cmsg_len, 8) };
    while (true) {
        const n = sendmsg(fd, &msg, MSG_NOSIGNAL);
        if (n < 0 and errno() == EINTR) continue;
        if (n < 0) return error.WriteFailed;
        if (@as(usize, @intCast(n)) < bytes.len) try writeAll(fd, bytes[@intCast(n)..]);
        return;
    }
}

/// Receives available bytes; file descriptors that arrive are appended to `fds_out`.
pub fn recvWithFds(fd: fd_t, buf: []u8, fds_out: *std.ArrayList(fd_t), a: std.mem.Allocator) !usize {
    var ctrl: [256]u8 align(8) = undefined;
    var iov = [1]IoVec{.{ .base = buf.ptr, .len = buf.len }};
    var msg = MsgHdr{ .iov = &iov, .iovlen = 1, .control = &ctrl, .controllen = ctrl.len };
    const n = while (true) {
        const r = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC);
        if (r < 0 and errno() == EINTR) continue;
        break r;
    };
    if (n < 0) return if (errno() == EAGAIN) error.WouldBlock else error.ReadFailed;
    var off: usize = 0;
    while (off + @sizeOf(CmsgHdr) <= msg.controllen) {
        const h: *align(1) const CmsgHdr = @ptrCast(&ctrl[off]);
        if (h.len < @sizeOf(CmsgHdr)) break;
        if (h.level == SOL_SOCKET and h.type == SCM_RIGHTS) {
            const count = (h.len - @sizeOf(CmsgHdr)) / @sizeOf(c_int);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const v = std.mem.readInt(c_int, ctrl[off + @sizeOf(CmsgHdr) + i * 4 ..][0..4], .little);
                try fds_out.append(a, v);
            }
        }
        off += std.mem.alignForward(usize, h.len, 8);
    }
    return @intCast(n);
}

/// Blocking read of exactly `buf.len` bytes (fails at EOF).
pub fn readExact(fd: fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = recv(fd, buf.ptr + off, buf.len - off, 0);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.EndOfStream;
        off += @intCast(n);
    }
}

/// Waits until `fd` is readable or `timeout_ms` passes (true = readable).
pub fn waitReadable(fd: fd_t, timeout_ms: i32) bool {
    var p = [1]PollFd{.{ .fd = fd, .events = POLLIN }};
    while (true) {
        const r = poll(&p, 1, timeout_ms);
        if (r < 0 and errno() == EINTR) continue;
        return r > 0;
    }
}

// ------------------------------------------------------------------ shared memory

pub const Shm = struct {
    fd: fd_t,
    mem: []align(4096) u8,

    pub fn create(size: usize) !Shm {
        const fd = memfd_create("annotation-helper", MFD_CLOEXEC);
        if (fd < 0) return error.MemfdFailed;
        errdefer _ = close(fd);
        if (ftruncate(fd, @intCast(size)) != 0) return error.TruncateFailed;
        const p = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.MmapFailed;
        const ptr: [*]align(4096) u8 = @ptrCast(@alignCast(p.?));
        return .{ .fd = fd, .mem = ptr[0..size] };
    }

    pub fn deinit(s: *Shm) void {
        _ = munmap(s.mem.ptr, s.mem.len);
        _ = close(s.fd);
    }
};

// ------------------------------------------------------------------ wake-up fd

/// eventfd used to wake the main loop from other threads.
pub const Wake = struct {
    fd: fd_t,

    pub fn init() !Wake {
        const fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        if (fd < 0) return error.EventFd;
        return .{ .fd = fd };
    }

    pub fn signal(wk: Wake) void {
        const one: u64 = 1;
        _ = write(wk.fd, std.mem.asBytes(&one), 8);
    }

    pub fn drain(wk: Wake) void {
        var v: u64 = 0;
        _ = read(wk.fd, std.mem.asBytes(&v), 8);
    }
};

// ------------------------------------------------------------------ locks & events

pub const Mutex = struct {
    m: [40]u8 align(8) = @splat(0), // PTHREAD_MUTEX_INITIALIZER is all zeroes on glibc

    pub fn lock(s: *Mutex) void {
        _ = pthread_mutex_lock(&s.m);
    }
    pub fn unlock(s: *Mutex) void {
        _ = pthread_mutex_unlock(&s.m);
    }
};

/// Manual-reset event (like a Win32 event).
pub const Event = struct {
    m: Mutex = .{},
    c: [48]u8 align(8) = @splat(0), // PTHREAD_COND_INITIALIZER
    set_: bool = false,

    pub fn set(e: *Event) void {
        e.m.lock();
        e.set_ = true;
        _ = pthread_cond_broadcast(&e.c);
        e.m.unlock();
    }

    /// Returns false on timeout.
    pub fn wait(e: *Event, timeout_ms: ?u64) bool {
        e.m.lock();
        defer e.m.unlock();
        if (timeout_ms) |ms| {
            var ts: Timespec = undefined;
            _ = clock_gettime(CLOCK_REALTIME, &ts);
            const total_ns = @as(u64, @intCast(ts.nsec)) + (ms % 1000) * 1_000_000;
            ts.sec += @intCast(ms / 1000 + total_ns / 1_000_000_000);
            ts.nsec = @intCast(total_ns % 1_000_000_000);
            while (!e.set_) if (pthread_cond_timedwait(&e.c, &e.m.m, &ts) == ETIMEDOUT) return e.set_;
        } else while (!e.set_) {
            _ = pthread_cond_wait(&e.c, &e.m.m);
        }
        return true;
    }
};

// ------------------------------------------------------------------ processes

/// Spawns `argv` (searched in PATH when `argv[0]` has no slash). Stdout/stderr go to
/// `log_path` (or stay inherited), stdin from /dev/null or the given fd. Returns the pid.
pub fn spawn(a: std.mem.Allocator, argv: []const []const u8, opts: struct { log_path: ?[]const u8 = null, stdin_fd: ?fd_t = null, stdout_fd: ?fd_t = null, new_session: bool = false }) !c_int {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const cargv = try ar.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |s, i| cargv[i] = (try ar.dupeSentinel(u8, s, 0)).ptr;

    var actions: [128]u8 align(16) = undefined;
    _ = posix_spawn_file_actions_init(&actions);
    defer _ = posix_spawn_file_actions_destroy(&actions);
    if (opts.stdin_fd) |f| {
        _ = posix_spawn_file_actions_adddup2(&actions, f, 0);
    } else _ = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    if (opts.stdout_fd) |f| _ = posix_spawn_file_actions_adddup2(&actions, f, 1);
    if (opts.log_path) |lp| {
        const z = try ar.dupeSentinel(u8, lp, 0);
        _ = posix_spawn_file_actions_addopen(&actions, 1, z.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
        _ = posix_spawn_file_actions_adddup2(&actions, 1, 2);
    }
    var attr: [512]u8 align(16) = undefined;
    _ = posix_spawnattr_init(&attr);
    defer _ = posix_spawnattr_destroy(&attr);
    if (opts.new_session) _ = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    var pid: c_int = 0;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(environ);
    const rc = if (std.mem.indexOfScalar(u8, argv[0], '/') != null)
        posix_spawn(&pid, cargv[0].?, &actions, &attr, cargv.ptr, envp)
    else
        posix_spawnp(&pid, cargv[0].?, &actions, &attr, cargv.ptr, envp);
    if (rc != 0) return error.SpawnFailed;
    return pid;
}

/// Waits for `pid`; returns its exit code (128+signal when killed).
pub fn wait(pid: c_int) u32 {
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno() != EINTR) return 1;
    }
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return (s >> 8) & 0xff;
    return 128 + (s & 0x7f);
}

/// Starts a program without waiting for it (a helper thread reaps it).
pub fn spawnDetached(a: std.mem.Allocator, argv: []const []const u8) bool {
    const pid = spawn(a, argv, .{ .new_session = true }) catch return false;
    if (std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
        fn reap(p: c_int) void {
            _ = wait(p);
        }
    }.reap, .{pid})) |t| t.detach() else |_| {}
    return true;
}

/// Whether `name` is an executable in PATH.
pub fn inPath(name: []const u8) bool {
    const path = env("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path, ':');
    var buf: [1024]u8 = undefined;
    while (it.next()) |dir| {
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
        if (access(p.ptr, 1) == 0) return true;
    }
    return false;
}

/// Name of the process `pid` (from /proc/PID/comm), allocated in `a`.
pub fn processName(a: std.mem.Allocator, pid: u32) []const u8 {
    var pbuf: [64]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pbuf, "/proc/{d}/exe", .{pid}, 0) catch return "";
    var buf: [1024]u8 = undefined;
    const n = readlink(p.ptr, &buf, buf.len);
    if (n > 0) {
        const full = buf[0..@intCast(n)];
        const base = full[(std.mem.lastIndexOfScalar(u8, full, '/') orelse return a.dupe(u8, full) catch "") + 1 ..];
        return a.dupe(u8, base) catch "";
    }
    const c = std.fmt.bufPrintSentinel(&pbuf, "/proc/{d}/comm", .{pid}, 0) catch return "";
    const fd = open(c.ptr, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "";
    defer _ = close(fd);
    const r = read(fd, &buf, buf.len);
    if (r <= 0) return "";
    return a.dupe(u8, std.mem.trimEnd(u8, buf[0..@intCast(r)], "\n")) catch "";
}

pub fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}
