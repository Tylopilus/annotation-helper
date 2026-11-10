//! Background thread turning finished frames into files: UI Automation lookups,
//! clean/annotated screenshots, per-annotation crops, an always-current session.json,
//! and launching the transcription process. Jobs arrive via the thread's message queue.

const std = @import("std");
const w = @import("win32").everything;
const util = @import("util.zig");
const model = @import("model.zig");
const raster = @import("raster.zig");
const com = @import("com.zig");

const WM_JOB = w.WM_APP + 50;
pub const WM_APP_DONE = w.WM_APP + 6;

/// Result slot owned by a waiter (MCP annotate request); signalled via `event`.
pub const Reply = struct {
    event: w.HANDLE,
    ok: bool = false,
    /// gpa-owned on success (session dir) or failure (message).
    text: []u8 = &.{},
};

/// Posted to the tray window when background processing ends (gpa-owned).
pub const Done = struct { ok: bool, text: []u8 };

pub const FrameJob = struct {
    frame: model.Frame,
    /// Opaque BGRA capture of `frame.capture_rect` (gpa-owned).
    pixels: []raster.Bgra,
};

pub const EndJob = struct {
    duration_ms: u64,
    audio: ?model.AudioInfo,
    /// Extra arguments for `process` (already quoted), or null to skip processing.
    process_args: ?[]const u8,
    wait: bool,
    reply: ?*Reply = null,
    notify_hwnd: ?w.HWND = null,
};

pub const Kind = union(enum) {
    warmup: []const [2]i32,
    begin: struct { session: model.Session, dir: []const u8 },
    frame: FrameJob,
    end: EndJob,
    discard,
};

pub const Job = struct {
    /// Everything in the job lives here; freed when the session ends.
    arena: *std.heap.ArenaAllocator,
    kind: Kind,
};

pub fn newArena() !*std.heap.ArenaAllocator {
    const a = try util.gpa.create(std.heap.ArenaAllocator);
    a.* = .init(util.gpa);
    return a;
}

fn freeArena(a: *std.heap.ArenaAllocator) void {
    a.deinit();
    util.gpa.destroy(a);
}

pub const Worker = struct {
    thread: std.Thread,
    tid: u32 = 0,
    ready: w.HANDLE,

    pub fn spawn() !*Worker {
        const wk = try util.gpa.create(Worker);
        wk.* = .{ .thread = undefined, .ready = w.CreateEventW(null, w.TRUE, w.FALSE, null) orelse return error.Event };
        wk.thread = try std.Thread.spawn(util.thread_cfg, run, .{wk});
        _ = w.WaitForSingleObject(wk.ready, w.INFINITE);
        return wk;
    }

    pub fn send(wk: *Worker, job: *Job) void {
        _ = w.PostThreadMessageW(wk.tid, WM_JOB, 0, @bitCast(@intFromPtr(job)));
    }

    /// Finishes queued jobs, then exits the thread.
    pub fn shutdown(wk: *Worker) void {
        _ = w.PostThreadMessageW(wk.tid, w.WM_QUIT, 0, 0);
        wk.thread.join();
        _ = w.CloseHandle(wk.ready);
        util.gpa.destroy(wk);
    }
};

const State = struct {
    uia: ?com.Uia = null,
    wic: ?com.Wic = null,
    session: ?model.Session = null,
    dir: []const u8 = "",
    frames: std.ArrayList(model.Frame) = .empty,
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,

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
    com.initThread();
    var msg: w.MSG = undefined;
    _ = w.PeekMessageW(&msg, null, 0, 0, .{}); // create the message queue
    wk.tid = w.GetCurrentThreadId();
    _ = w.SetEvent(wk.ready);

    var st = State{};
    st.uia = com.Uia.init() catch blk: {
        util.log("  UI Automation unavailable", .{});
        break :blk null;
    };
    st.wic = com.Wic.init() catch null;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        if (msg.message != WM_JOB) continue;
        const job: *Job = @ptrFromInt(@as(usize, @bitCast(msg.lParam)));
        handle(&st, job);
    }
    st.reset();
}

fn handle(st: *State, job: *Job) void {
    const a = job.arena.allocator();
    switch (job.kind) {
        .warmup => |points| {
            if (st.uia) |u| for (points) |p| {
                _ = u.elementAt(a, p[0], p[1]);
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
            const args = if (e.process_args) |p| util.gpa.dupe(u8, p) catch null else null;
            const ctx = Finish{ .dir = dir, .args = args, .run_processor = e.process_args != null and st.session != null, .reply = e.reply, .notify = e.notify_hwnd };
            st.reset();
            freeArena(job.arena);
            // Transcription can take a while; don't hold up the next session.
            if (e.wait) ctx.go() else if (std.Thread.spawn(util.thread_cfg, Finish.go, .{ctx})) |t| t.detach() else |_| ctx.go();
        },
        .discard => {
            if (st.dir.len > 0) util.deleteFlatDir(util.gpa, st.dir);
            st.reset();
            freeArena(job.arena);
        },
    }
    util.gpa.destroy(job);
}

const Finish = struct {
    dir: []u8,
    args: ?[]u8,
    run_processor: bool,
    reply: ?*Reply,
    notify: ?w.HWND,

    fn go(f: Finish) void {
        var ok = true;
        var text: []u8 = f.dir;
        if (f.run_processor) {
            if (runProcessor(f.dir, f.args orelse "")) |err| {
                ok = false;
                text = err;
                util.gpa.free(f.dir);
            }
        }
        if (f.args) |x| util.gpa.free(x);
        if (f.reply) |r| {
            r.ok = ok;
            r.text = text;
            _ = w.SetEvent(r.event);
        } else if (f.notify) |hwnd| {
            const done = util.gpa.create(Done) catch return;
            done.* = .{ .ok = ok, .text = text };
            _ = w.PostMessageW(hwnd, WM_APP_DONE, 0, @bitCast(@intFromPtr(done)));
        } else util.gpa.free(text);
    }
};

/// Runs `<exe> process <dir> <args>` with output in process.log. Returns an error
/// message (gpa-owned) or null on success.
fn runProcessor(dir: []const u8, args: []const u8) ?[]u8 {
    var exe_buf: [1024]u16 = undefined;
    const exe = util.narrow(util.gpa, util.exePathW(&exe_buf)) catch return null;
    defer util.gpa.free(exe);
    const cmd = util.gpa.print("\"{s}\" process \"{s}\" {s}", .{ exe, dir, args }) catch return null;
    defer util.gpa.free(cmd);
    const log_path = util.join(util.gpa, &.{ dir, "process.log" }) catch return null;
    defer util.gpa.free(log_path);
    const code = util.runProcess(util.gpa, cmd, log_path) catch |e| return util.gpa.print("could not start processing: {s}", .{@errorName(e)}) catch null;
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

fn finishFrame(st: *State, a: std.mem.Allocator, job: FrameJob) !void {
    var frame = job.frame;
    const strokes = try a.dupe(model.Stroke, frame.strokes);
    frame.strokes = strokes;

    // UI Automation first: the screen may change once the user carries on.
    if (st.uia) |u| for (strokes) |*s| {
        var targets: std.ArrayList(model.Target) = .empty;
        if (s.tool == .arrow) {
            try targets.append(a, .{ .role = "from", .point = s.points[0], .element = u.elementAt(a, s.points[0][0], s.points[0][1]) });
            const last = s.points[s.points.len - 1];
            try targets.append(a, .{ .role = "to", .point = last, .element = u.elementAt(a, last[0], last[1]) });
        } else {
            const c = s.bbox.center();
            try targets.append(a, .{ .role = "center", .point = c, .element = u.elementAt(a, c[0], c[1]) });
        }
        s.targets = targets.items;
    };

    const wic = st.wic orelse return error.NoWic;
    const r = frame.capture_rect;
    const clean_path = try util.join(a, &.{ st.dir, frame.clean_image });
    try wic.savePng(clean_path, job.pixels, r.w, r.h);

    const canvas = raster.Canvas{ .px = job.pixels, .w = r.w, .h = r.h, .ox = r.x, .oy = r.y };
    for (strokes) |*s| raster.render(util.gpa, canvas, s, r, true);
    try wic.savePng(try util.join(a, &.{ st.dir, frame.image }), job.pixels, r.w, r.h);

    for (strokes) |*s| {
        if (s.bbox.intersect(r)) |b| s.image_bbox = b.offset(-r.x, -r.y);
        const cr = cropRect(raster.bounds(s), r);
        const crop = try util.gpa.alloc(raster.Bgra, @intCast(cr.w * cr.h));
        defer util.gpa.free(crop);
        var y: i32 = 0;
        while (y < cr.h) : (y += 1) {
            const src = job.pixels[@intCast((cr.y - r.y + y) * r.w + (cr.x - r.x))..][0..@intCast(cr.w)];
            @memcpy(crop[@intCast(y * cr.w)..][0..@intCast(cr.w)], src);
        }
        const name = try a.print("frame-{d:0>2}-a{d:0>2}.png", .{ frame.index, s.id });
        try wic.savePng(try util.join(a, &.{ st.dir, name }), crop, cr.w, cr.h);
        s.crop = name;
    }
    util.log("  saved screenshot {d} ({d}x{d}, {d} annotation(s))", .{ frame.index, r.w, r.h, strokes.len });
    try st.frames.append(util.gpa, frame);
}

/// Crop around an annotation with enough surrounding context; shifted inside the image.
pub fn cropRect(b: model.Rect, image: model.Rect) model.Rect {
    const pad = 60;
    const cw = @min(@max(b.w + 2 * pad, 720), image.w);
    const ch = @min(@max(b.h + 2 * pad, 450), image.h);
    const c = b.center();
    var r = model.Rect{ .x = c[0] - @divTrunc(cw, 2), .y = c[1] - @divTrunc(ch, 2), .w = cw, .h = ch };
    r.x = @max(@min(r.x, image.right() - r.w), image.x);
    r.y = @max(@min(r.y, image.bottom() - r.h), image.y);
    return r;
}
