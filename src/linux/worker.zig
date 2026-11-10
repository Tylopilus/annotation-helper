//! Background thread turning finished frames into files (Linux counterpart of
//! src/worker.zig): AT-SPI lookups, clean/annotated screenshots, per-annotation crops,
//! an always-current session.json, and launching the transcription process.

const std = @import("std");
const util = @import("../util.zig");
const model = @import("../model.zig");
const raster = @import("../raster.zig");
const sys = @import("sys.zig");
const atspi = @import("atspi.zig");
const shared = @import("../worker.zig");

/// Result slot owned by a waiter (MCP annotate request).
pub const Reply = struct {
    event: sys.Event = .{},
    ok: bool = false,
    /// gpa-owned on success (session dir) or failure (message).
    text: []u8 = &.{},
};

/// Handed to `EndJob.notify` when background processing ends (gpa-owned).
pub const Done = shared.Done;

pub const FrameJob = shared.FrameJob;

pub const EndJob = struct {
    duration_ms: u64,
    audio: ?model.AudioInfo,
    process_args: ?[]const []const u8,
    wait: bool,
    reply: ?*Reply = null,
    notify: ?*const fn (*Done) void = null,
};

pub const Kind = union(enum) {
    warmup: []const [2]i32,
    /// `live_args`: start live transcription with these `process` arguments.
    begin: struct { session: model.Session, dir: []const u8, live_args: ?[]const []const u8 = null },
    frame: FrameJob,
    end: EndJob,
    discard,
};

pub const Job = struct {
    arena: *std.heap.ArenaAllocator,
    kind: Kind,
};

pub const newArena = shared.newArena;

fn freeArena(a: *std.heap.ArenaAllocator) void {
    a.deinit();
    util.gpa.destroy(a);
}

pub const Worker = struct {
    thread: std.Thread,
    lock: sys.Mutex = .{},
    cond: [48]u8 align(8) = @splat(0),
    jobs: std.ArrayList(?*Job) = .empty,
    wayland: bool,

    pub fn spawn(wayland: bool) !*Worker {
        const wk = try util.gpa.create(Worker);
        wk.* = .{ .thread = undefined, .wayland = wayland };
        wk.thread = try std.Thread.spawn(util.thread_cfg, run, .{wk});
        return wk;
    }

    pub fn send(wk: *Worker, job: ?*Job) void {
        wk.lock.lock();
        wk.jobs.append(util.gpa, job) catch {};
        _ = sys.pthread_cond_broadcast(&wk.cond);
        wk.lock.unlock();
    }

    /// Finishes queued jobs, then exits the thread.
    pub fn shutdown(wk: *Worker) void {
        wk.send(null);
        wk.thread.join();
        wk.jobs.deinit(util.gpa);
        util.gpa.destroy(wk);
    }

    fn take(wk: *Worker) ?*Job {
        wk.lock.lock();
        defer wk.lock.unlock();
        while (wk.jobs.items.len == 0) _ = sys.pthread_cond_wait(&wk.cond, &wk.lock.m);
        return wk.jobs.orderedRemove(0);
    }
};

/// The `process --live` helper of the current session.
const LiveProc = struct {
    pid: c_int,
    stdin: c_int,

    /// Session over: the helper transcribes the rest and writes the brief. Returns its exit code.
    fn finish(l: LiveProc) u32 {
        _ = sys.close(l.stdin);
        return sys.wait(l.pid);
    }

    fn cancel(l: LiveProc) void {
        _ = sys.write(l.stdin, "cancel\n", 7);
        _ = sys.close(l.stdin);
        _ = sys.wait(l.pid);
    }
};

const State = struct {
    live: ?LiveProc = null,
    ax: ?atspi.Atspi = null,
    ax_tried: bool = false,
    wayland: bool,
    session: ?model.Session = null,
    dir: []const u8 = "",
    frames: std.ArrayList(model.Frame) = .empty,
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,

    fn accessibility(s: *State) ?*atspi.Atspi {
        if (!s.ax_tried) {
            s.ax_tried = true;
            s.ax = atspi.Atspi.init(util.gpa, s.wayland) catch blk: {
                util.log("  accessibility bus (AT-SPI) unavailable: UI elements won't be named", .{});
                break :blk null;
            };
        }
        return if (s.ax) |*x| x else null;
    }

    fn reset(s: *State) void {
        for (s.arenas.items) |a| freeArena(a);
        s.arenas.clearRetainingCapacity();
        s.frames.clearAndFree(util.gpa);
        s.session = null;
        s.dir = "";
    }

    fn save(s: *State) void {
        var sess = s.session orelse return;
        sess.frames = s.frames.items;
        const json = model.toJson(util.gpa, sess) catch return;
        defer util.gpa.free(json);
        const p = util.join(util.gpa, &.{ s.dir, "session.json" }) catch return;
        defer util.gpa.free(p);
        util.writeFile(p, json) catch |e| util.log("  error writing session.json: {s}", .{@errorName(e)});
    }
};

fn run(wk: *Worker) void {
    var st = State{ .wayland = wk.wayland };
    while (wk.take()) |job| handle(&st, job);
    st.reset();
    if (st.ax) |*x| x.deinit();
}

fn handle(st: *State, job: *Job) void {
    const a = job.arena.allocator();
    switch (job.kind) {
        .warmup => |points| {
            if (st.accessibility()) |ax| for (points) |p| {
                _ = ax.elementAt(a, p[0], p[1]);
            };
            freeArena(job.arena);
        },
        .begin => |b| {
            st.reset();
            st.arenas.append(util.gpa, job.arena) catch {};
            st.session = b.session;
            st.dir = b.dir;
            util.mkdirAll(b.dir) catch {};
            st.save();
            if (b.live_args) |args| st.live = startLive(b.dir, args);
        },
        .frame => |f| {
            st.arenas.append(util.gpa, job.arena) catch {};
            finishFrame(st, a, f) catch |e| util.log("  error: frame failed ({s})", .{@errorName(e)});
            util.gpa.free(f.pixels);
            st.save();
        },
        .end => |e| {
            if (st.session) |*s| {
                s.duration_ms = e.duration_ms;
                s.audio = e.audio;
            }
            st.save();
            const dir = util.gpa.dupe(u8, st.dir) catch return;
            var args: ?[][]u8 = null;
            if (e.process_args) |pa| {
                const copy = util.gpa.alloc([]u8, pa.len) catch return;
                for (pa, copy) |src, *dst| dst.* = util.gpa.dupe(u8, src) catch &.{};
                args = copy;
            }
            const ctx = Finish{ .dir = dir, .args = args, .run_processor = e.process_args != null and st.session != null, .reply = e.reply, .notify = e.notify, .live = st.live };
            st.live = null;
            st.reset();
            freeArena(job.arena);
            if (e.wait) ctx.go() else if (std.Thread.spawn(util.thread_cfg, Finish.go, .{ctx})) |t| t.detach() else |_| ctx.go();
        },
        .discard => {
            if (st.live) |l| l.cancel();
            st.live = null;
            if (st.dir.len > 0) util.deleteFlatDir(util.gpa, st.dir);
            st.reset();
            freeArena(job.arena);
        },
    }
    util.gpa.destroy(job);
}

const Finish = struct {
    dir: []u8,
    args: ?[][]u8,
    run_processor: bool,
    reply: ?*Reply,
    notify: ?*const fn (*Done) void,
    live: ?LiveProc = null,

    fn go(f: Finish) void {
        var ok = true;
        var text: []u8 = f.dir;
        var done_live = false;
        if (f.live) |l| {
            const code = l.finish();
            done_live = code == 0;
            if (!done_live) util.log("  live transcription failed (exit code {d}); transcribing again", .{code});
        }
        if (f.run_processor and !done_live) {
            if (runProcessor(f.dir, f.args orelse &.{})) |err| {
                ok = false;
                text = err;
                util.gpa.free(f.dir);
            }
        }
        if (f.args) |x| {
            for (x) |s| util.gpa.free(s);
            util.gpa.free(x);
        }
        if (f.reply) |r| {
            r.ok = ok;
            r.text = text;
            r.event.set();
        } else if (f.notify) |cb| {
            const done = util.gpa.create(Done) catch return;
            done.* = .{ .ok = ok, .text = text };
            cb(done);
        } else util.gpa.free(text);
    }
};

/// Starts `<exe> process <dir> --live <args>` with output in process.log; null on failure
/// (the session is then transcribed when it ends).
fn startLive(dir: []const u8, args: []const []const u8) ?LiveProc {
    const exe = util.exePath(util.gpa) catch return null;
    defer util.gpa.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(util.gpa);
    argv.appendSlice(util.gpa, &.{ exe, "process", dir, "--live" }) catch return null;
    argv.appendSlice(util.gpa, args) catch return null;
    const log_path = util.join(util.gpa, &.{ dir, "process.log" }) catch return null;
    defer util.gpa.free(log_path);
    var fds: [2]c_int = undefined;
    if (sys.pipe2(&fds, sys.O_CLOEXEC) != 0) return null;
    const pid = sys.spawn(util.gpa, argv.items, .{ .log_path = log_path, .stdin_fd = fds[0] }) catch {
        _ = sys.close(fds[0]);
        _ = sys.close(fds[1]);
        return null;
    };
    _ = sys.close(fds[0]);
    return .{ .pid = pid, .stdin = fds[1] };
}

/// Runs `<exe> process <dir> <args>` with output in process.log. Returns an error
/// message (gpa-owned) or null on success.
fn runProcessor(dir: []const u8, args: []const []const u8) ?[]u8 {
    const exe = util.exePath(util.gpa) catch return null;
    defer util.gpa.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(util.gpa);
    argv.appendSlice(util.gpa, &.{ exe, "process", dir }) catch return null;
    argv.appendSlice(util.gpa, args) catch return null;
    const log_path = util.join(util.gpa, &.{ dir, "process.log" }) catch return null;
    defer util.gpa.free(log_path);
    const pid = sys.spawn(util.gpa, argv.items, .{ .log_path = log_path }) catch |e| return util.gpa.print("could not start processing: {s}", .{@errorName(e)}) catch null;
    const code = sys.wait(pid);
    if (code == 0) return null;
    const log = util.readFile(util.gpa, log_path) catch return util.gpa.print("processing failed (exit code {d})", .{code}) catch null;
    defer util.gpa.free(log);
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len > 0) last = t;
    }
    return util.gpa.print("processing failed (exit code {d}): {s}", .{ code, last }) catch null;
}

extern fn ah_png_write_bgra(path: [*:0]const u8, bgra: [*]const raster.Bgra, w: c_int, h: c_int) c_int;

fn savePng(path: []const u8, px: []const raster.Bgra, w: i32, h: i32) !void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.NameTooLong;
    if (ah_png_write_bgra(z.ptr, px.ptr, w, h) != 0) return error.PngWriteFailed;
}

fn finishFrame(st: *State, a: std.mem.Allocator, job: FrameJob) !void {
    var frame = job.frame;
    const strokes = try a.dupe(model.Stroke, frame.strokes);
    frame.strokes = strokes;

    if (st.accessibility()) |ax| {
        if (frame.foreground == null and st.wayland) frame.foreground = ax.activeWindow(a);
        for (strokes) |*s| {
            var targets: std.ArrayList(model.Target) = .empty;
            if (s.tool == .arrow) {
                try targets.append(a, .{ .role = "from", .point = s.points[0], .element = ax.elementAt(a, s.points[0][0], s.points[0][1]) });
                const last = s.points[s.points.len - 1];
                try targets.append(a, .{ .role = "to", .point = last, .element = ax.elementAt(a, last[0], last[1]) });
            } else {
                const c = s.bbox.center();
                try targets.append(a, .{ .role = "center", .point = c, .element = ax.elementAt(a, c[0], c[1]) });
            }
            s.targets = targets.items;
        }
    }

    const r = frame.capture_rect;
    try savePng(try util.join(a, &.{ st.dir, frame.clean_image }), job.pixels, r.w, r.h);
    const canvas = raster.Canvas{ .px = job.pixels, .w = r.w, .h = r.h, .ox = r.x, .oy = r.y };
    for (strokes) |*s| raster.render(util.gpa, canvas, s, r, true);
    try savePng(try util.join(a, &.{ st.dir, frame.image }), job.pixels, r.w, r.h);

    for (strokes) |*s| {
        if (s.bbox.intersect(r)) |b| s.image_bbox = b.offset(-r.x, -r.y);
        const cr = shared.cropRect(raster.bounds(s), r);
        const crop = try util.gpa.alloc(raster.Bgra, @intCast(cr.w * cr.h));
        defer util.gpa.free(crop);
        var y: i32 = 0;
        while (y < cr.h) : (y += 1) {
            const src = job.pixels[@intCast((cr.y - r.y + y) * r.w + (cr.x - r.x))..][0..@intCast(cr.w)];
            @memcpy(crop[@intCast(y * cr.w)..][0..@intCast(cr.w)], src);
        }
        const name = try a.print("frame-{d:0>2}-a{d:0>2}.png", .{ frame.index, s.id });
        try savePng(try util.join(a, &.{ st.dir, name }), crop, cr.w, cr.h);
        s.crop = name;
    }
    util.log("  saved screenshot {d} ({d}x{d}, {d} annotation(s))", .{ frame.index, r.w, r.h, strokes.len });
    try st.frames.append(util.gpa, frame);
}
