//! Linux recorder on the main thread: tray icon + menu (StatusNotifierItem), global
//! hotkeys (X11 key grabs, or the GlobalShortcuts portal on Wayland), freeze-frame
//! drawing (the screen is captured first, then shown full-screen to draw on), request
//! banners, hotkey capture, agent requests and the session state machine.

const std = @import("std");
const util = @import("../util.zig");
const model = @import("../model.zig");
const raster = @import("../raster.zig");
const config = @import("../config.zig");
const audio = @import("../audio.zig");
const sys = @import("sys.zig");
const dbus = @import("dbus.zig");
const x11 = @import("x11.zig");
const wayland = @import("wayland.zig");
const keys = @import("keys.zig");
const tray_mod = @import("tray.zig");
const desktop = @import("desktop.zig");
const worker = @import("worker.zig");

const Hotkey = config.Hotkey;
const Rect = model.Rect;
const Bgra = raster.Bgra;

const ID_SESSION = 10;
const ID_DRAW = 11;
const ID_OPEN_SESSIONS = 12;
const ID_SHOW_LAST = 13;
const ID_HOTKEYS = 19;
const ID_HK_SESSION = 20;
const ID_HK_DRAW = 21;
const ID_HK_RESET = 22;
const ID_CONFIG = 23;
const ID_HK_CONFIGURE = 24;
const ID_QUIT = 99;

const TIMER_REQUEST = 0;
const TIMER_AUTODRAW = 1;
const TIMER_CAPTURE = 2;

const HOTKEY_NAMES = [2][]const u8{ "Start/stop recording", "Draw on screen" };
const SHORTCUT_IDS = [2][]const u8{ "record", "draw" };

pub const Options = struct {
    out_dir: []const u8,
    no_audio: bool = false,
    /// Use this WAV instead of the microphone (selftest).
    audio_file: ?[]const u8 = null,
    /// Extra arguments for `process`, or null to skip processing.
    process_args: ?[]const []const u8 = &.{},
    /// Interactive tray app with hotkeys (null for selftest / MCP mode).
    config: ?config.Config = null,
};

// ------------------------------------------------------------------ display

const Disp = union(enum) {
    x: *x11.X11,
    wl: *wayland.Wl,

    fn fd(d: Disp) sys.fd_t {
        return switch (d) {
            .x => |x| x.fd,
            .wl => |w| w.fd,
        };
    }

    fn monitors(d: Disp) MonitorList {
        var out = MonitorList{};
        switch (d) {
            .x => |x| {
                const m = x.monitors();
                @memcpy(out.items[0..m.n], m.items[0..m.n]);
                out.n = m.n;
            },
            .wl => |w| {
                const m = w.monitors();
                @memcpy(out.items[0..m.n], m.items[0..m.n]);
                out.n = m.n;
            },
        }
        return out;
    }
};

const MonitorList = struct {
    items: [16]model.Monitor = undefined,
    n: usize = 0,

    fn slice(m: *const MonitorList) []const model.Monitor {
        return m.items[0..m.n];
    }
    fn primary(m: *const MonitorList) Rect {
        for (m.slice()) |x| if (x.primary) return x.rect;
        return if (m.n > 0) m.items[0].rect else .{ .w = 1920, .h = 1080 };
    }
    fn at(m: *const MonitorList, p: ?[2]i32) Rect {
        if (p) |q| for (m.slice()) |x| if (x.rect.contains(q[0], q[1])) return x.rect;
        return m.primary();
    }
};

// ------------------------------------------------------------------ state

const Active = struct {
    t0: u64,
    dir: []u8,
    next_id: u32 = 1,
    frames: u32 = 0,
    recorder: ?*audio.Recorder = null,
};

const Current = struct {
    tool: model.Tool,
    color: model.ColorName,
    t_start: u64,
    points: std.ArrayList([2]i32) = .empty,

    fn stroke(c: *const Current, id: u32) model.Stroke {
        return .{ .id = id, .tool = c.tool, .color = c.color, .t_start_ms = c.t_start, .t_end_ms = c.t_start, .points = c.points.items, .bbox = Rect.bounding(c.points.items) };
    }
};

const Overlay = struct { px: []Bgra, rect: Rect };

const Drawing = struct {
    virt: Rect,
    /// Frozen screenshot (clean) and what is shown (tinted + strokes + pill + banner).
    base: []Bgra,
    px: []Bgra,
    mons: MonitorList,
    strokes: std.ArrayList(model.Stroke) = .empty,
    current: ?Current = null,
    t_start: u64,
    fg: ?model.WindowInfo = null,
    fg_arena: std.heap.ArenaAllocator,
    dirty: ?Rect = null,
    banner: ?Overlay = null,
    pill: Rect = .{},
    cursor: ?[2]i32 = null,
};

pub const Request = struct {
    prompt: []const u8,
    asker: []const u8,
    voice: bool,
    timeout_ms: u32,
    reply: *worker.Reply,
};

const Msg = union(enum) { annotate, cancel, done: *worker.Done, quit, control: Control };
const Control = enum { draw, toggle };

var msg_lock: sys.Mutex = .{};
var msgs: std.ArrayList(Msg) = .empty;
var req_queue: std.ArrayList(*Request) = .empty;
var wake: sys.Wake = undefined;
var signalled = std.atomic.Value(bool).init(false);

const App = struct {
    opts: Options,
    disp: ?Disp = null,
    bus: ?*dbus.Conn = null,
    wk: *worker.Worker,
    session: ?Active = null,
    draw: ?Drawing = null,
    tool: model.Tool = .pen,
    color: model.ColorName = .red,
    prev_color: model.ColorName = .red,
    request: ?*Request = null,
    tray: ?*tray_mod.Tray = null,
    hotkeys: [2]?Hotkey = .{ null, null },
    grabbed: [2]?Hotkey = .{ null, null },
    shortcuts: ?desktop.Shortcuts = null,
    shortcut_labels: [2][64]u8 = undefined,
    shortcut_label_len: [2]usize = .{ 0, 0 },
    capturing: ?usize = null,
    last_dir: ?[]u8 = null,
    timers: [3]u64 = .{ 0, 0, 0 },
    quitting: bool = false,
    interactive: bool = false,
    last_note: u32 = 0,
    fonts: [2]c_int = .{ -1, -1 },
};

var app: App = undefined;
var app_ready = false;

fn elapsed() u64 {
    return if (app.session) |s| util.nowMs() - s.t0 else 0;
}

fn post(m: Msg) void {
    msg_lock.lock();
    msgs.append(util.gpa, m) catch {};
    msg_lock.unlock();
    wake.signal();
}

fn sendJob(kind: worker.Kind) void {
    const arena = worker.newArena() catch return;
    sendJobWith(arena, kind);
}

fn sendJobWith(arena: *std.heap.ArenaAllocator, kind: worker.Kind) void {
    const job = util.gpa.create(worker.Job) catch return;
    job.* = .{ .arena = arena, .kind = kind };
    app.wk.send(job);
}

fn setTimer(id: usize, ms: u64) void {
    app.timers[id] = util.nowMs() + ms;
}
fn killTimer(id: usize) void {
    app.timers[id] = 0;
}

fn cursorPos() ?[2]i32 {
    const d = app.disp orelse return null;
    return switch (d) {
        .x => |x| x.cursorPos(),
        .wl => null,
    };
}

fn monitors() MonitorList {
    if (app.disp) |d| return d.monitors();
    var m = MonitorList{};
    m.items[0] = .{ .rect = .{ .w = 1920, .h = 1080 }, .primary = true };
    m.n = 1;
    return m;
}

fn isWayland() bool {
    return if (app.disp) |d| d == .wl else false;
}

// ------------------------------------------------------------------ session

fn startSession(with_audio: bool) !void {
    if (app.session != null) return;
    const ts = util.localTimestamp();
    const dir = try util.join(util.gpa, &.{ app.opts.out_dir, &ts.id });
    try util.mkdirAll(dir);
    util.log("● Session started → {s}", .{dir});
    var active = Active{ .t0 = util.nowMs(), .dir = dir };
    if (with_audio and !app.opts.no_audio and app.opts.audio_file == null) {
        const wav = try util.join(util.gpa, &.{ dir, "audio.wav" });
        defer util.gpa.free(wav);
        active.recorder = audio.Recorder.start(wav) catch null;
    }
    const arena = try worker.newArena();
    const a = arena.allocator();
    const mons = monitors();
    sendJobWith(arena, .{ .begin = .{
        .session = .{ .id = try a.dupe(u8, &ts.id), .started_local = try a.dupe(u8, &ts.human), .monitors = try a.dupe(model.Monitor, mons.slice()) },
        .dir = try a.dupe(u8, dir),
    } });
    app.session = active;
    updateTray();
}

fn stopSession(wait: bool, reply: ?*worker.Reply) void {
    if (app.draw != null) finishDraw();
    const s = app.session orelse return;
    app.session = null;
    defer util.gpa.free(s.dir);
    const duration = util.nowMs() - s.t0;
    var audio_info: ?model.AudioInfo = null;
    if (s.recorder) |rec| {
        const rate = rec.sample_rate;
        const offset = rec.stop(s.t0);
        audio_info = .{ .file = "audio.wav", .sample_rate = rate, .offset_ms = offset };
    } else if (app.opts.audio_file) |src| {
        if (util.join(util.gpa, &.{ s.dir, "audio.wav" })) |d| {
            defer util.gpa.free(d);
            if (util.readFile(util.gpa, src)) |bytes| {
                defer util.gpa.free(bytes);
                util.writeFile(d, bytes) catch {};
                if (bytes.len > 28) audio_info = .{ .file = "audio.wav", .sample_rate = std.mem.readInt(u32, bytes[24..28], .little), .offset_ms = 0 };
            } else |_| {}
        } else |_| {}
    }
    var tbuf: [16]u8 = undefined;
    util.log("■ Session stopped ({s}, {d} screenshot(s))", .{ util.fmtTime(&tbuf, @intCast(duration)), s.frames });
    const arena = worker.newArena() catch return;
    var args: ?[]const []const u8 = null;
    if (app.opts.process_args) |pa| {
        if (reply != null) {
            const list = arena.allocator().alloc([]const u8, pa.len + 1) catch return;
            @memcpy(list[0..pa.len], pa);
            list[pa.len] = "--no-clipboard";
            args = list;
        } else args = arena.allocator().dupe([]const u8, pa) catch pa;
    }
    const notify_cb: ?*const fn (*worker.Done) void = if (reply == null and app.interactive) onDoneFromWorker else null;
    if (notify_cb != null and args != null) balloon("Session saved", "Transcribing… you'll get a notification when the brief is ready.", false);
    sendJobWith(arena, .{ .end = .{ .duration_ms = duration, .audio = audio_info, .process_args = args, .wait = wait, .reply = reply, .notify = notify_cb } });
    updateTray();
}

fn onDoneFromWorker(done: *worker.Done) void {
    post(.{ .done = done });
}

// ------------------------------------------------------------------ drawing

const TINT_KEEP: u32 = 227; // the Windows overlay's black at alpha 28

fn tinted(p: Bgra) Bgra {
    return .{ .b = @intCast((@as(u32, p.b) * TINT_KEEP + 127) / 255), .g = @intCast((@as(u32, p.g) * TINT_KEEP + 127) / 255), .r = @intCast((@as(u32, p.r) * TINT_KEEP + 127) / 255), .a = 255 };
}

const Shot = struct { px: []Bgra, w: i32, h: i32 };

/// The whole desktop, before anything of ours is shown.
fn screenshot() !Shot {
    if (sys.env("ANNOTATION_HELPER_TEST_SCREENSHOT")) |path| {
        const img = try desktop.loadPng(path);
        return .{ .px = img.px, .w = img.w, .h = img.h };
    }
    const d = app.disp orelse return error.NoDisplay;
    switch (d) {
        .x => |x| {
            const r = x.screenRect();
            return .{ .px = try x.capture(util.gpa, r), .w = r.w, .h = r.h };
        },
        .wl => {
            const bus = app.bus orelse return error.NoSessionBus;
            const img = try desktop.screenshot(bus);
            return .{ .px = img.px, .w = img.w, .h = img.h };
        },
    }
}

fn startDraw() !void {
    const disp = app.disp orelse return error.NoDisplay;
    try startSession(true);
    var fg_arena = std.heap.ArenaAllocator.init(util.gpa);
    errdefer fg_arena.deinit();
    var fg: ?model.WindowInfo = null;
    const cursor = cursorPos();
    if (disp == .x) {
        fg = disp.x.activeWindow(fg_arena.allocator());
        if (cursor) |c| if (worker.newArena()) |arena| {
            sendJobWith(arena, .{ .warmup = arena.allocator().dupe([2]i32, &.{c}) catch &.{} });
        } else |_| {};
    }
    const shot = screenshot() catch |e| {
        util.log("  screenshot failed: {s}{s}{s}", .{ @errorName(e), if (e == error.DBusError) " — " else "", if (e == error.DBusError) dbus.lastError() else "" });
        balloon("Screenshot failed", if (disp == .wl) "The desktop's screenshot portal (xdg-desktop-portal) did not answer or refused." else "Could not capture the screen.", true);
        return error.ScreenshotFailed;
    };
    errdefer util.gpa.free(shot.px);
    if (disp == .wl) disp.wl.setImageWidth(shot.w);
    const px = try util.gpa.alloc(Bgra, shot.px.len);
    errdefer util.gpa.free(px);
    const virt = Rect{ .w = shot.w, .h = shot.h };
    var d = Drawing{ .virt = virt, .base = shot.px, .px = px, .mons = disp.monitors(), .t_start = elapsed(), .fg_arena = fg_arena, .cursor = cursor };
    if (fg) |f| d.fg = f;
    const p = d.mons.primary();
    d.pill = .{ .x = p.right() - 64 - 16, .y = p.y + 12, .w = 64, .h = 34 };
    app.draw = d;
    redraw(virt);
    app.draw.?.dirty = null;
    switch (disp) {
        .x => |x| {
            x.showWindow(virt) catch |e| {
                util.log("  cannot show the drawing window: {s}", .{@errorName(e)});
                x.hideWindow();
                abortDraw();
                return error.ShowFailed;
            };
            x.present(px, virt.w, virt);
        },
        .wl => |w| w.show(px, virt.w, virt.h) catch |e| {
            util.log("  cannot show the drawing window: {s}", .{@errorName(e)});
            w.hide();
            abortDraw();
            return error.ShowFailed;
        },
    }
    util.log("  ✎ drawing ({s}, {s}) — Esc/right-click to finish", .{ app.tool.label(), @tagName(app.color) });
    updateTray();
}

/// Drops the drawing without a screenshot (window failed to show).
fn abortDraw() void {
    var d = app.draw orelse return;
    app.draw = null;
    freeDrawing(&d);
}

fn freeDrawing(d: *Drawing) void {
    for (d.strokes.items) |s| util.gpa.free(s.points);
    d.strokes.deinit(util.gpa);
    if (d.current) |*c| c.points.deinit(util.gpa);
    if (d.banner) |b| util.gpa.free(b.px);
    d.fg_arena.deinit();
    util.gpa.free(d.base);
    util.gpa.free(d.px);
}

fn hideOverlay() void {
    const disp = app.disp orelse return;
    switch (disp) {
        .x => |x| x.hideWindow(),
        .wl => |w| w.hide(),
    }
}

fn finishDraw() void {
    endStroke();
    var d = app.draw orelse return;
    app.draw = null;
    defer freeDrawing(&d);
    const t_end = elapsed();
    hideOverlay();

    // The monitors the annotations touch (or the one under the cursor).
    var area = Rect{};
    for (d.strokes.items) |s| for (d.mons.slice()) |m| {
        if (m.rect.intersect(s.bbox) != null) area = area.unite(m.rect);
    };
    if (area.isEmpty()) area = d.mons.at(d.cursor);
    area = area.intersect(d.virt) orelse d.virt;
    const pixels = util.gpa.alloc(Bgra, @intCast(area.w * area.h)) catch return;
    var y: i32 = 0;
    while (y < area.h) : (y += 1) {
        const src = d.base[@intCast((area.y + y) * d.virt.w + area.x)..][0..@intCast(area.w)];
        @memcpy(pixels[@intCast(y * area.w)..][0..@intCast(area.w)], src);
    }
    if (app.session == null) {
        util.gpa.free(pixels);
        return;
    }
    app.session.?.frames += 1;
    const index = app.session.?.frames;
    const arena = worker.newArena() catch return;
    const a = arena.allocator();
    const strokes = a.alloc(model.Stroke, d.strokes.items.len) catch return;
    for (d.strokes.items, strokes) |src, *dst| {
        dst.* = src;
        dst.points = a.dupe([2]i32, src.points) catch &.{};
    }
    const fg: ?model.WindowInfo = if (d.fg) |f| .{ .title = a.dupe(u8, f.title) catch "", .process = a.dupe(u8, f.process) catch "" } else null;
    sendJobWith(arena, .{ .frame = .{ .pixels = pixels, .frame = .{
        .index = index,
        .t_start_ms = d.t_start,
        .t_end_ms = t_end,
        .foreground = fg,
        .capture_rect = area,
        .image = a.print("frame-{d:0>2}.png", .{index}) catch "",
        .clean_image = a.print("frame-{d:0>2}-clean.png", .{index}) catch "",
        .strokes = strokes,
    } } });
    updateTray();
    if (app.request) |req| {
        app.request = null;
        endRequestUi();
        stopSession(false, req.reply);
    }
}

/// Re-renders `dirty` (image coordinates) into the shown buffer.
fn redraw(dirty: Rect) void {
    if (app.draw == null) return;
    const dr = &app.draw.?;
    const area = dirty.intersect(dr.virt) orelse return;
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const row: usize = @intCast(y * dr.virt.w + area.x);
        for (dr.px[row..][0..@intCast(area.w)], dr.base[row..][0..@intCast(area.w)]) |*dst, src| dst.* = tinted(src);
    }
    const canvas = raster.Canvas{ .px = dr.px, .w = dr.virt.w, .h = dr.virt.h };
    for (dr.strokes.items) |*s| raster.render(util.gpa, canvas, s, area, true);
    if (dr.current) |*c| {
        const preview = c.stroke(if (app.session) |s| s.next_id else 1);
        raster.render(util.gpa, canvas, &preview, area, true);
    }
    if (dr.pill.intersect(area) != null) drawPill(dr);
    if (dr.banner) |b| if (b.rect.intersect(area)) |o| {
        var by = o.y;
        while (by < o.bottom()) : (by += 1) {
            const src = b.px[@intCast((by - b.rect.y) * b.rect.w + (o.x - b.rect.x))..][0..@intCast(o.w)];
            @memcpy(dr.px[@intCast(by * dr.virt.w + o.x)..][0..@intCast(o.w)], src);
        }
    };
    dr.dirty = if (dr.dirty) |d| d.unite(area) else area;
}

/// Status pill top-right on the primary monitor: red dot plus the current tool/color.
fn drawPill(dr: *Drawing) void {
    const r = dr.pill;
    if (r.intersect(dr.virt) == null) return;
    const c = raster.Canvas{ .px = dr.px, .w = dr.virt.w, .h = dr.virt.h };
    const x: f32 = @floatFromInt(r.x);
    const y: f32 = @floatFromInt(r.y);
    raster.line(util.gpa, c, .{ x + 17, y + 17 }, .{ x + @as(f32, @floatFromInt(r.w)) - 17, y + 17 }, 15, .{ 25, 25, 25 }, 210);
    raster.disc(util.gpa, c, x + 17, y + 17, 7, .{ 230, 30, 30 }, 255);
    raster.toolGlyph(util.gpa, c, app.tool, app.color, x + 45, y + 17);
}

/// Pushes what changed to the screen (once per loop iteration).
fn presentDirty() void {
    const dr = if (app.draw) |*d| d else return;
    const dirty = dr.dirty orelse return;
    dr.dirty = null;
    const disp = app.disp orelse return;
    switch (disp) {
        .x => |x| x.present(dr.px, dr.virt.w, dirty),
        .wl => |w| w.present(dirty),
    }
}

fn beginStroke(p: [2]i32) void {
    if (app.draw == null) return;
    var c = Current{ .tool = app.tool, .color = app.color, .t_start = elapsed() };
    c.points.append(util.gpa, p) catch return;
    app.draw.?.current = c;
    redraw(raster.bounds(&c.stroke(0)));
}

fn moveStroke(p: [2]i32) void {
    if (app.draw == null or app.draw.?.current == null) return;
    const cur = &app.draw.?.current.?;
    const before = raster.bounds(&cur.stroke(0));
    switch (cur.tool) {
        .pen, .highlighter => {
            const last = cur.points.items[cur.points.items.len - 1];
            if (@abs(last[0] - p[0]) + @abs(last[1] - p[1]) < 2) return;
            const old_badge = (Rect{ .x = Rect.bounding(cur.points.items).x - 6, .y = Rect.bounding(cur.points.items).y - 6 }).inflate(raster.MARGIN);
            cur.points.append(util.gpa, p) catch return;
            const b = Rect.bounding(cur.points.items);
            const new_badge = (Rect{ .x = b.x - 6, .y = b.y - 6 }).inflate(raster.MARGIN);
            redraw(Rect.bounding(&.{ last, p }).inflate(raster.MARGIN).unite(old_badge).unite(new_badge));
        },
        else => {
            cur.points.shrinkRetainingCapacity(1);
            cur.points.append(util.gpa, p) catch return;
            redraw(before.unite(raster.bounds(&cur.stroke(0))));
        },
    }
}

fn endStroke() void {
    if (app.draw == null) return;
    var c = app.draw.?.current orelse return;
    app.draw.?.current = null;
    var s = c.stroke(0);
    const area = raster.bounds(&s);
    if (raster.isMeaningful(&s) and app.session != null) {
        s.id = app.session.?.next_id;
        app.session.?.next_id += 1;
        s.t_end_ms = elapsed();
        s.points = c.points.toOwnedSlice(util.gpa) catch return;
        app.draw.?.strokes.append(util.gpa, s) catch {};
    } else c.points.deinit(util.gpa);
    redraw(area);
}

fn addStroke(tool: model.Tool, color: model.ColorName, points: []const [2]i32) void {
    if (app.draw == null) return;
    var c = Current{ .tool = tool, .color = color, .t_start = elapsed() };
    c.points.appendSlice(util.gpa, points) catch return;
    app.draw.?.current = c;
    endStroke();
}

fn undo() void {
    if (app.draw == null) return;
    const d = &app.draw.?;
    if (d.current) |*c| {
        const area = raster.bounds(&c.stroke(0));
        c.points.deinit(util.gpa);
        d.current = null;
        return redraw(area);
    }
    const s = d.strokes.pop() orelse return;
    if (app.session) |*a| if (a.next_id == s.id + 1) {
        app.session.?.next_id = s.id;
    };
    const area = raster.bounds(&s);
    util.gpa.free(s.points);
    redraw(area);
}

fn clearAll() void {
    while (app.draw != null and (app.draw.?.strokes.items.len > 0 or app.draw.?.current != null)) undo();
}

/// Fixed test annotations on the primary monitor (selftest, MCP autodraw test hook).
fn scriptedStrokes() void {
    const m = if (app.draw) |d| d.mons.primary() else monitors().primary();
    const c = m.center();
    addStroke(.rectangle, .red, &.{ .{ c[0] - 220, c[1] - 70 }, .{ c[0] + 220, c[1] + 70 } });
    addStroke(.arrow, .blue, &.{ .{ m.x + @divTrunc(m.w, 6), m.y + @divTrunc(m.h, 5) }, .{ c[0] - 230, c[1] - 60 } });
    addStroke(.ellipse, .green, &.{ .{ m.x + @divTrunc(m.w * 2, 3), m.y + @divTrunc(m.h, 6) }, .{ m.x + @divTrunc(m.w * 5, 6), m.y + @divTrunc(m.h, 3) } });
    var hl: [40][2]i32 = undefined;
    for (&hl, 0..) |*p, i| p.* = .{ m.x + @divTrunc(m.w, 8) + @as(i32, @intCast(i)) * 8, m.y + @divTrunc(m.h * 3, 4) };
    addStroke(.highlighter, .yellow, &hl);
}

// ------------------------------------------------------------------ keys & hotkeys

fn modsToConfig(m: keys.Mods) u32 {
    var v: u32 = 0;
    if (m.ctrl) v |= config.MOD_CONTROL;
    if (m.alt) v |= config.MOD_ALT;
    if (m.shift) v |= config.MOD_SHIFT;
    if (m.super) v |= config.MOD_WIN;
    return v;
}

fn x11Mods(state: u16) keys.Mods {
    return .{ .ctrl = state & x11.MASK_CONTROL != 0, .shift = state & x11.MASK_SHIFT != 0, .alt = state & x11.MASK_ALT != 0, .super = state & x11.MASK_SUPER != 0 };
}

fn x11ModMask(mods: u32) u16 {
    var m: u16 = 0;
    if (mods & config.MOD_CONTROL != 0) m |= x11.MASK_CONTROL;
    if (mods & config.MOD_ALT != 0) m |= x11.MASK_ALT;
    if (mods & config.MOD_SHIFT != 0) m |= x11.MASK_SHIFT;
    if (mods & config.MOD_WIN != 0) m |= x11.MASK_SUPER;
    return m;
}

/// A key while drawing (`vk` in Windows virtual-key codes, like the Windows build).
fn onKey(vk: u32, mods: keys.Mods) void {
    // X11: our keyboard grab blocks the global hotkeys, so match them here.
    if (app.disp != null and app.disp.? == .x) {
        const combo = Hotkey{ .mods = modsToConfig(mods), .vk = vk };
        for (app.hotkeys, 0..) |h, slot| if (h) |hk| if (hk.eql(combo)) return onHotkey(slot);
    }
    if (mods.alt or mods.super) return;
    switch (vk) {
        0x1B => if (mods.shift and app.request != null) cancelRequest("the user cancelled") else finishDraw(),
        0x0D, 0x20 => finishDraw(),
        0x08 => undo(),
        0x2E => clearAll(),
        'Z' => if (mods.ctrl) undo(),
        'P', 'H', 'R', 'E', 'O', 'A' => {
            if (mods.ctrl) return;
            const t: model.Tool = switch (vk) {
                'P' => .pen,
                'H' => .highlighter,
                'R' => .rectangle,
                'A' => .arrow,
                else => .ellipse,
            };
            // The highlighter defaults to yellow; leaving it restores the previous color.
            if (t == .highlighter and app.tool != .highlighter) {
                app.prev_color = app.color;
                app.color = .yellow;
            } else if (t != .highlighter and app.tool == .highlighter) app.color = app.prev_color;
            app.tool = t;
            if (app.draw) |d| redraw(d.pill);
        },
        '1' => setColor(.red),
        '2' => setColor(.green),
        '3' => setColor(.blue),
        '4' => setColor(.yellow),
        else => {},
    }
}

fn setColor(c: model.ColorName) void {
    app.color = c;
    if (app.draw) |d| redraw(d.pill);
}

fn onHotkey(slot: usize) void {
    if (app.request != null or app.capturing != null) return;
    switch (slot) {
        0 => if (app.session != null) stopSession(false, null) else startSession(true) catch |e| util.log("  error: {s}", .{@errorName(e)}),
        1 => if (app.draw != null) finishDraw() else startDraw() catch |e| util.log("  error: {s}", .{@errorName(e)}),
        else => {},
    }
}

fn hotkeyLabel(slot: usize, buf: []u8) []const u8 {
    if (app.shortcut_label_len[slot] > 0) return app.shortcut_labels[slot][0..app.shortcut_label_len[slot]];
    if (isWayland() and app.shortcuts == null) return "no shortcut";
    return if (app.hotkeys[slot]) |h| h.label(buf) else "(none)";
}

/// (Re-)grabs both hotkeys (X11); returns the problems as text.
fn registerHotkeys(problem: []u8) []const u8 {
    const x = if (app.disp) |d| (if (d == .x) d.x else return problem[0..0]) else return problem[0..0];
    unregisterHotkeys();
    var n: usize = 0;
    for (0..2) |slot| {
        const hk = app.hotkeys[slot] orelse continue;
        if (x.grabKey(x11ModMask(hk.mods), hk.vk)) {
            app.grabbed[slot] = hk;
        } else {
            var lb: [64]u8 = undefined;
            const s = std.fmt.bufPrint(problem[n..], "{s} is already used by another app ({s}). ", .{ hk.label(&lb), HOTKEY_NAMES[slot] }) catch break;
            n += s.len;
        }
    }
    return problem[0..n];
}

fn unregisterHotkeys() void {
    const d = app.disp orelse return;
    if (d != .x) return;
    for (&app.grabbed) |*g| if (g.*) |hk| {
        d.x.ungrabKey(x11ModMask(hk.mods), hk.vk);
        g.* = null;
    };
}

/// Wayland: global shortcuts through the portal (the desktop may ask once).
fn bindPortalShortcuts() []const u8 {
    const bus = app.bus orelse return "no D-Bus session bus";
    if (app.shortcuts == null) app.shortcuts = desktop.Shortcuts.create(bus) catch |e| {
        util.log("  GlobalShortcuts portal unavailable: {s} {s}", .{ @errorName(e), if (e == error.DBusError) dbus.lastError() else "" });
        return "this desktop offers no global shortcuts to apps";
    };
    var tb: [2][64]u8 = undefined;
    var list: [2]desktop.Shortcut = undefined;
    for (0..2) |slot| {
        list[slot] = .{
            .id = SHORTCUT_IDS[slot],
            .description = HOTKEY_NAMES[slot],
            .trigger = if (app.hotkeys[slot]) |h| keys.portalTrigger(&tb[slot], h.mods, h.vk) else "",
        };
    }
    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();
    const assigned = app.shortcuts.?.bind(bus, arena.allocator(), &list) catch |e| {
        util.log("  binding shortcuts failed: {s}", .{@errorName(e)});
        return "binding the shortcuts failed";
    };
    for (assigned, 0..) |t, slot| {
        const n = @min(t.len, app.shortcut_labels[slot].len);
        @memcpy(app.shortcut_labels[slot][0..n], t[0..n]);
        app.shortcut_label_len[slot] = n;
    }
    return "";
}

fn beginCapture(slot: usize) void {
    if (app.capturing != null or app.draw != null or app.request != null) return;
    const d = app.disp orelse return;
    if (d != .x) return;
    unregisterHotkeys(); // so pressing the current combo is captured, not triggered
    if (!d.x.grabKeyboardRoot()) {
        var pb: [512]u8 = undefined;
        _ = registerHotkeys(&pb);
        return balloon("Hotkey not changed", "Could not take the keyboard (another app holds it).", true);
    }
    app.capturing = slot;
    showCapturePrompt(slot, null);
    setTimer(TIMER_CAPTURE, 20_000);
}

fn showCapturePrompt(slot: usize, err: ?[]const u8) void {
    var t: [128]u8 = undefined;
    var h: [256]u8 = undefined;
    var lb: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&t, "Press the new shortcut for \u{201c}{s}\u{201d}", .{HOTKEY_NAMES[slot]}) catch "";
    const help = if (err) |e|
        std.fmt.bufPrint(&h, "{s} — try another combination · Esc cancels", .{e}) catch ""
    else
        std.fmt.bufPrint(&h, "Currently {s} · use Ctrl, Alt or Super plus a key (or an F-key) · Esc cancels", .{hotkeyLabel(slot, &lb)}) catch "";
    util.log("  {s}: {s}", .{ title, help });
    balloon(title, help, err != null);
}

fn onCaptured(vk: u32, mods: u32) void {
    const slot = app.capturing orelse return;
    if (vk == 0x1B and mods == 0) return endCapture(null);
    const hk = Hotkey{ .mods = mods, .vk = vk };
    var lb: [64]u8 = undefined;
    var eb: [160]u8 = undefined;
    hk.validate() catch |e| {
        const msg = std.fmt.bufPrint(&eb, "{s} {s}", .{ hk.label(&lb), config.errorText(e) }) catch "";
        return showCapturePrompt(slot, msg);
    };
    if (app.hotkeys[1 - slot]) |other| if (other.eql(hk)) {
        const msg = std.fmt.bufPrint(&eb, "{s} is already the {s} hotkey", .{ hk.label(&lb), HOTKEY_NAMES[1 - slot] }) catch "";
        return showCapturePrompt(slot, msg);
    };
    endCapture(hk);
}

fn endCapture(new: ?Hotkey) void {
    const slot = app.capturing orelse return;
    app.capturing = null;
    killTimer(TIMER_CAPTURE);
    if (app.disp) |d| if (d == .x) d.x.ungrabKeyboard();
    var pb: [512]u8 = undefined;
    const hk = new orelse {
        _ = registerHotkeys(&pb);
        return;
    };
    const old = app.hotkeys[slot];
    app.hotkeys[slot] = hk;
    const problems = registerHotkeys(&pb);
    var lb: [64]u8 = undefined;
    var mb: [600]u8 = undefined;
    if (problems.len > 0) {
        const msg = std.fmt.bufPrint(&mb, "{s}Kept {s}.", .{ problems, if (old) |o| o.label(&lb) else "(none)" }) catch "";
        app.hotkeys[slot] = old;
        var pb2: [512]u8 = undefined;
        _ = registerHotkeys(&pb2);
        balloon("Hotkey not changed", msg, true);
    } else {
        saveHotkeys();
        balloon("Hotkey changed", std.fmt.bufPrint(&mb, "{s}: {s}", .{ HOTKEY_NAMES[slot], hk.label(&lb) }) catch "", false);
    }
    updateTray();
}

fn resetHotkeys() void {
    const d = config.Hotkeys{};
    app.hotkeys = .{ Hotkey.parse(d.session) catch null, Hotkey.parse(d.draw) catch null };
    var pb: [512]u8 = undefined;
    const problems = registerHotkeys(&pb);
    saveHotkeys();
    updateTray();
    if (problems.len > 0) balloon("Hotkey problem", problems, true) else balloon("Hotkeys reset", "Ctrl+Alt+D draw · Ctrl+Alt+R record", false);
}

var hk_label_store: [2][64]u8 = undefined;

fn saveHotkeys() void {
    var c = app.opts.config orelse return;
    c.hotkeys.session = if (app.hotkeys[0]) |h| h.label(&hk_label_store[0]) else "(none)";
    c.hotkeys.draw = if (app.hotkeys[1]) |h| h.label(&hk_label_store[1]) else "(none)";
    app.opts.config = c;
    config.save(c) catch balloon("Settings not saved", "Could not write config.json.", true);
}

// ------------------------------------------------------------------ requests (MCP)

/// Called from an MCP thread: ask the user to annotate; blocks until answered.
pub fn annotate(req: *Request) void {
    msg_lock.lock();
    req_queue.append(util.gpa, req) catch {};
    msg_lock.unlock();
    post(.annotate);
    _ = req.reply.event.wait(req.timeout_ms + 900_000);
}

pub fn cancelAnnotation() void {
    post(.cancel);
}

/// Whether annotate_screen can work here (a display to draw on).
pub fn canAnnotate() bool {
    return app_ready and app.disp != null;
}

fn replyErr(r: *worker.Reply, msg: []const u8) void {
    r.ok = false;
    r.text = util.gpa.dupe(u8, msg) catch &.{};
    r.event.set();
}

fn beginRequests() void {
    msg_lock.lock();
    const pending = req_queue.toOwnedSlice(util.gpa) catch &.{};
    msg_lock.unlock();
    defer util.gpa.free(pending);
    for (pending) |req| {
        if (app.request != null or app.session != null) {
            replyErr(req.reply, "the user is already recording or annotating; try again later");
            continue;
        }
        if (app.disp == null) {
            replyErr(req.reply, "no display to draw on (annotation-helper needs X11 or Wayland)");
            continue;
        }
        startSession(req.voice) catch {
            replyErr(req.reply, "could not start a session");
            continue;
        };
        startDraw() catch |e| {
            cancelSessionQuietly();
            replyErr(req.reply, if (e == error.ScreenshotFailed) "taking the screenshot failed" else "could not start drawing");
            continue;
        };
        util.log("  request from {s}: {s}", .{ req.asker, req.prompt });
        app.request = req;
        var tb: [600]u8 = undefined;
        const voice = req.voice and app.session.?.recorder != null;
        showBanner(
            std.fmt.bufPrint(&tb, "{s} asks: {s}", .{ req.asker, req.prompt }) catch req.prompt,
            if (voice) "Draw and talk — P pen · R box · E ellipse · A arrow · H highlight · 1-4 color · Ctrl+Z undo  ·  Esc = send  ·  Shift+Esc = cancel" else "Draw — P pen · R box · E ellipse · A arrow · H highlight · 1-4 color · Ctrl+Z undo  ·  Esc = send  ·  Shift+Esc = cancel",
        );
        setTimer(TIMER_REQUEST, req.timeout_ms);
        if (sys.env("ANNOTATION_HELPER_TEST_AUTODRAW") != null) setTimer(TIMER_AUTODRAW, 1500);
    }
}

fn cancelSessionQuietly() void {
    if (app.session) |s| {
        if (s.recorder) |rec| _ = rec.stop(s.t0);
        util.gpa.free(s.dir);
        app.session = null;
    }
    sendJob(.discard);
    updateTray();
}

/// Abort the agent request: no screenshot, recording discarded.
fn cancelRequest(why: []const u8) void {
    const req = app.request orelse return;
    app.request = null;
    endRequestUi();
    if (app.draw) |_| {
        hideOverlay();
        freeDrawing(&app.draw.?);
        app.draw = null;
    }
    cancelSessionQuietly();
    util.log("  request cancelled: {s}", .{why});
    replyErr(req.reply, why);
}

fn endRequestUi() void {
    killTimer(TIMER_REQUEST);
    killTimer(TIMER_AUTODRAW);
    if (app.draw) |*d| if (d.banner) |b| {
        d.banner = null;
        util.gpa.free(b.px);
        redraw(b.rect);
    };
}

// ------------------------------------------------------------------ banner

extern fn ah_font_load(path: [*:0]const u8) c_int;
extern fn ah_text(font: c_int, px: f32, text: [*:0]const u8, max_w: c_int, bgra: ?[*]Bgra, bw: c_int, bh: c_int, x: c_int, y: c_int, rgb: u32, out_w: ?*c_int) c_int;

fn loadFonts() void {
    const regular = [_][]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf",
    };
    const bold = [_][]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
        "/usr/share/fonts/noto/NotoSans-Bold.ttf",
        "/usr/share/fonts/google-noto/NotoSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf",
        "/usr/share/fonts/truetype/ubuntu/Ubuntu-B.ttf",
    };
    for ([_][]const []const u8{ &regular, &bold }, 0..) |list, i| {
        for (list) |p| {
            var b: [256]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&b, "{s}", .{p}, 0) catch continue;
            const f = ah_font_load(z.ptr);
            if (f >= 0) {
                app.fonts[i] = f;
                break;
            }
        }
        if (app.fonts[i] < 0) if (fcMatch(if (i == 0) "sans" else "sans:bold")) |p| {
            app.fonts[i] = ah_font_load(p.ptr);
        };
    }
    if (app.fonts[1] < 0) app.fonts[1] = app.fonts[0];
    if (app.fonts[0] < 0) util.log("  no TrueType font found: request banners will have no text", .{});
}

var fc_buf: [512]u8 = undefined;

fn fcMatch(pattern: []const u8) ?[:0]const u8 {
    var fds: [2]c_int = undefined;
    if (sys.pipe2(&fds, sys.O_CLOEXEC) != 0) return null;
    const pid = sys.spawn(util.gpa, &.{ "fc-match", "-f", "%{file}", pattern }, .{ .stdout_fd = fds[1] }) catch {
        _ = sys.close(fds[0]);
        _ = sys.close(fds[1]);
        return null;
    };
    _ = sys.close(fds[1]);
    var n: usize = 0;
    while (n < fc_buf.len - 1) {
        const r = sys.read(fds[0], fc_buf[n..].ptr, fc_buf.len - 1 - n);
        if (r <= 0) break;
        n += @intCast(r);
    }
    _ = sys.close(fds[0]);
    _ = sys.wait(pid);
    if (n == 0) return null;
    fc_buf[n] = 0;
    return fc_buf[0..n :0];
}

/// Request banner at the top of the monitor under the cursor, drawn into the frozen frame.
fn showBanner(title: []const u8, help: []const u8) void {
    const dr = if (app.draw) |*d| d else return;
    const k: f32 = if (app.disp) |d| (if (d == .wl) @floatCast(d.wl.ratio) else 1) else 1;
    const sc = struct {
        fn f(v: f32, kk: f32) i32 {
            return @intFromFloat(@round(v * kk));
        }
    }.f;
    const mon = dr.mons.at(dr.cursor);
    const max_w = @min(@divTrunc(mon.w * 6, 10), sc(980, k));
    var tz: [700]u8 = undefined;
    var hz: [400]u8 = undefined;
    const t = std.fmt.bufPrintSentinel(&tz, "{s}", .{title[0..@min(title.len, tz.len - 1)]}, 0) catch return;
    const h = std.fmt.bufPrintSentinel(&hz, "{s}", .{help[0..@min(help.len, hz.len - 1)]}, 0) catch return;
    const title_px: f32 = 22 * k;
    const help_px: f32 = 15 * k;
    var tw: c_int = 0;
    var hw: c_int = 0;
    const th = ah_text(app.fonts[1], title_px, t.ptr, max_w, null, 0, 0, 0, 0, 0, &tw);
    const hh = ah_text(app.fonts[0], help_px, h.ptr, max_w, null, 0, 0, 0, 0, 0, &hw);
    const pad = sc(14, k);
    const gap = sc(6, k);
    const bar = sc(5, k);
    const bw = @max(@max(tw, hw), sc(200, k)) + 2 * pad + bar;
    const bh = th + gap + hh + 2 * pad;
    const px = util.gpa.alloc(Bgra, @intCast(bw * bh)) catch return;
    for (px, 0..) |*p, i| {
        const x: i32 = @intCast(i % @as(usize, @intCast(bw)));
        p.* = if (x < bar) .{ .b = 0x30, .g = 0x8c, .r = 0xe8, .a = 255 } else .{ .b = 0x24, .g = 0x24, .r = 0x24, .a = 255 };
    }
    _ = ah_text(app.fonts[1], title_px, t.ptr, max_w, px.ptr, bw, bh, pad + bar, pad, 0xffffff, null);
    _ = ah_text(app.fonts[0], help_px, h.ptr, max_w, px.ptr, bw, bh, pad + bar, pad + th + gap, 0xb8b8b8, null);
    const rect = (Rect{ .x = mon.x + @divTrunc(mon.w - bw, 2), .y = mon.y + sc(18, k), .w = bw, .h = bh });
    const inside = rect.intersect(dr.virt) orelse {
        util.gpa.free(px);
        return;
    };
    if (inside.w != rect.w or inside.h != rect.h) {
        util.gpa.free(px);
        return;
    }
    if (dr.banner) |old| {
        util.gpa.free(old.px);
        redraw(old.rect);
    }
    dr.banner = .{ .px = px, .rect = rect };
    redraw(rect);
}

// ------------------------------------------------------------------ tray & notifications

fn balloon(title: []const u8, text: []const u8, warning: bool) void {
    if (!app.interactive) return;
    const bus = app.bus orelse return util.log("  {s}: {s}", .{ title, text });
    const id = desktop.notify(bus, title, text, warning, std.mem.eql(u8, title, "Brief ready"));
    if (id == 0) util.log("  {s}: {s}", .{ title, text }) else app.last_note = id;
}

fn updateTray() void {
    const t = app.tray orelse return;
    var buf: [160]u8 = undefined;
    t.setState(app.session != null, trayTip(&buf));
    buildMenu();
}

fn trayTip(buf: []u8) []const u8 {
    if (app.session) |s| return std.fmt.bufPrint(buf, "Recording ({d} screenshot(s))", .{s.frames}) catch "";
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} draw · {s} record", .{ hotkeyLabel(1, &a), hotkeyLabel(0, &b) }) catch "";
}

fn buildMenu() void {
    const t = app.tray orelse return;
    var arena = std.heap.ArenaAllocator.init(util.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const recording = app.session != null;
    const enabled = app.request == null and app.capturing == null;
    var l0: [64]u8 = undefined;
    var l1: [64]u8 = undefined;
    const labels = [2][]const u8{ hotkeyLabel(0, &l0), hotkeyLabel(1, &l1) };
    var items: std.ArrayList(tray_mod.Item) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList(tray_mod.Item), al: std.mem.Allocator, it: tray_mod.Item) void {
            list.append(al, it) catch {};
        }
    }.f;
    var sep_id: i32 = 1000;
    const status = if (app.session) |s| a.print("Recording · {d} screenshot(s)", .{s.frames}) catch "" else "Idle";
    add(&items, a, .{ .id = 1, .label = a.print("annotation-helper — {s}", .{status}) catch "", .enabled = false });
    add(&items, a, .{ .id = sep_id, .separator = true });
    sep_id += 1;
    add(&items, a, .{ .id = ID_SESSION, .label = a.print("{s} ({s})", .{ if (recording) "Stop recording" else "Start recording", labels[0] }) catch "", .enabled = enabled });
    add(&items, a, .{ .id = ID_DRAW, .label = a.print("{s} ({s})", .{ if (app.draw != null) "Finish screenshot" else "Draw on screen", labels[1] }) catch "", .enabled = enabled and app.disp != null });
    add(&items, a, .{ .id = sep_id, .separator = true });
    sep_id += 1;
    add(&items, a, .{ .id = ID_SHOW_LAST, .label = "Show last brief", .enabled = app.last_dir != null });
    add(&items, a, .{ .id = ID_OPEN_SESSIONS, .label = "Open sessions folder" });
    add(&items, a, .{ .id = sep_id, .separator = true });
    sep_id += 1;
    if (isWayland()) {
        if (app.shortcuts != null) add(&items, a, .{ .id = ID_HK_CONFIGURE, .label = "Change shortcuts…", .enabled = enabled });
    } else {
        add(&items, a, .{ .id = ID_HOTKEYS, .label = "Hotkeys", .submenu = true });
        add(&items, a, .{ .id = ID_HK_SESSION, .parent = ID_HOTKEYS, .label = a.print("{s}… ({s})", .{ HOTKEY_NAMES[0], labels[0] }) catch "", .enabled = enabled and !recording });
        add(&items, a, .{ .id = ID_HK_DRAW, .parent = ID_HOTKEYS, .label = a.print("{s}… ({s})", .{ HOTKEY_NAMES[1], labels[1] }) catch "", .enabled = enabled and !recording });
        add(&items, a, .{ .id = sep_id, .parent = ID_HOTKEYS, .separator = true });
        sep_id += 1;
        add(&items, a, .{ .id = ID_HK_RESET, .parent = ID_HOTKEYS, .label = "Reset to defaults", .enabled = enabled and !recording });
    }
    add(&items, a, .{ .id = ID_CONFIG, .label = "Edit config.json" });
    add(&items, a, .{ .id = sep_id, .separator = true });
    add(&items, a, .{ .id = ID_QUIT, .label = "Quit" });
    t.setMenu(items.items);
}

fn onMenu(id: i32) void {
    switch (id) {
        ID_SESSION => onHotkey(0),
        ID_DRAW => onHotkey(1),
        ID_SHOW_LAST => if (app.last_dir) |d| {
            const p = util.join(util.gpa, &.{ d, "brief.md" }) catch return;
            defer util.gpa.free(p);
            desktop.reveal(app.bus, p);
        },
        ID_OPEN_SESSIONS => desktop.openPath(app.opts.out_dir),
        ID_HK_SESSION => beginCapture(0),
        ID_HK_DRAW => beginCapture(1),
        ID_HK_RESET => resetHotkeys(),
        ID_HK_CONFIGURE => if (app.shortcuts) |s| {
            if (!s.configure(app.bus.?)) balloon("Shortcuts", "Change them in your desktop's keyboard settings (look for annotation-helper).", false);
        },
        ID_CONFIG => {
            if (app.opts.config) |c| config.save(c) catch {};
            const p = config.path(util.gpa) catch return;
            defer util.gpa.free(p);
            desktop.openPath(p);
        },
        ID_QUIT => quit(),
        else => {},
    }
}

fn onDone(done: *worker.Done) void {
    defer util.gpa.destroy(done);
    if (done.ok) {
        if (app.last_dir) |d| util.gpa.free(d);
        app.last_dir = done.text;
        const brief = util.join(util.gpa, &.{ done.text, "brief.md" }) catch return;
        defer util.gpa.free(brief);
        if (util.exists(brief)) balloon("Brief ready", "Hand-off prompt copied to the clipboard — paste it into your agent. Click to show the files.", false);
        updateTray();
    } else {
        balloon("Processing failed", done.text, true);
        util.gpa.free(done.text);
    }
}

// ------------------------------------------------------------------ D-Bus

const CONTROL_XML =
    \\<node><interface name="dev.annotationhelper.AnnotationHelper">
    \\<method name="Draw"/><method name="Toggle"/><method name="Quit"/>
    \\</interface></node>
;

fn onBus(m: *const dbus.Message) void {
    const bus = app.bus.?;
    if (app.tray) |t| {
        var handled = false;
        if (t.handle(m, &handled)) |id| onMenu(id);
        if (handled) return;
    }
    if (m.type == .signal) {
        if (app.shortcuts) |s| if (s.activated(m)) |act| {
            if (act.token) |tok| if (app.disp) |d| if (d == .wl) d.wl.setActivationToken(tok);
            for (SHORTCUT_IDS, 0..) |id, slot| if (std.mem.eql(u8, id, act.id)) onHotkey(slot);
            return;
        };
        if (desktop.notificationClicked(m)) |id| if (id == app.last_note and id != 0) if (app.last_dir) |d| {
            const p = util.join(util.gpa, &.{ d, "brief.md" }) catch return;
            defer util.gpa.free(p);
            desktop.reveal(app.bus, p);
        };
        return;
    }
    if (m.type != .call) return;
    if (std.mem.eql(u8, m.path, "/") or std.mem.eql(u8, m.path, "/dev/annotationhelper/AnnotationHelper")) {
        if (m.is("org.freedesktop.DBus.Introspectable", "Introspect")) {
            var o = bus.methodReturn(m);
            defer o.deinit();
            o.sig = "s";
            o.body.string(CONTROL_XML);
            _ = bus.send(&o) catch {};
            return;
        }
        const known = std.mem.eql(u8, m.member, "Draw") or std.mem.eql(u8, m.member, "Toggle") or std.mem.eql(u8, m.member, "Quit");
        if (!known) return bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        if (m.flags & dbus.NO_REPLY == 0) {
            var o = bus.methodReturn(m);
            defer o.deinit();
            _ = bus.send(&o) catch {};
        }
        if (std.mem.eql(u8, m.member, "Draw")) onHotkey(1) else if (std.mem.eql(u8, m.member, "Toggle")) onHotkey(0) else quit();
        return;
    }
    bus.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", "no such object");
}

/// `annotation-helper draw|toggle|quit`: tells the running tray app (bind these to
/// keyboard shortcuts where the desktop offers no global shortcuts to apps).
pub fn control(cmd: []const u8) !void {
    const bus = try dbus.Conn.session(util.gpa);
    defer bus.close();
    if (!bus.nameHasOwner(desktop.APP_ID)) {
        util.log("annotation-helper is not running (start it first: annotation-helper)", .{});
        return error.NotRunning;
    }
    const member = if (std.mem.eql(u8, cmd, "draw")) "Draw" else if (std.mem.eql(u8, cmd, "toggle")) "Toggle" else "Quit";
    var o = bus.call(desktop.APP_ID, "/", desktop.APP_ID, member);
    defer o.deinit();
    var rep = try bus.callWait(&o, 5000);
    rep.deinit(util.gpa);
}

// ------------------------------------------------------------------ loop

fn quit() void {
    if (app.quitting) return;
    cancelRequest("the annotation server is shutting down");
    endCapture(null);
    stopSession(true, null);
    app.wk.shutdown();
    app.quitting = true;
}

fn handleMessages() void {
    msg_lock.lock();
    const list = msgs.toOwnedSlice(util.gpa) catch &.{};
    msg_lock.unlock();
    defer util.gpa.free(list);
    for (list) |m| switch (m) {
        .annotate => beginRequests(),
        .cancel => cancelRequest("the agent cancelled the request"),
        .done => |d| onDone(d),
        .quit => quit(),
        .control => |c| onHotkey(if (c == .draw) 1 else 0),
    };
}

fn handleDisplayEvents() void {
    const d = app.disp orelse return;
    switch (d) {
        .x => |x| while (x.nextEvent()) |ev| switch (ev) {
            .key => |k| {
                const vk = keys.vkFromKeysym(k.keysym);
                if (app.capturing != null) {
                    if (keys.isModifierKeysym(k.keysym) or vk == 0) continue;
                    onCaptured(vk, modsToConfig(x11Mods(k.state)));
                } else if (app.draw != null and k.window == x.win) {
                    if (vk != 0) onKey(vk, x11Mods(k.state));
                } else if (k.window == x.root) {
                    // A grabbed hotkey.
                    const combo = Hotkey{ .mods = modsToConfig(x11Mods(k.state)), .vk = vk };
                    for (app.hotkeys, 0..) |h, slot| if (h) |hk| if (hk.eql(combo)) onHotkey(slot);
                }
            },
            .button => |b| onButton(b.x, b.y, b.button, b.down),
            .motion => |m| onMotion(m.x, m.y),
            .expose => if (app.draw) |dr| redraw(dr.virt),
        },
        .wl => |w| while (w.nextEvent()) |ev| switch (ev) {
            .key => |k| if (app.draw != null) {
                const vk = keys.vkFromKeysym(k.keysym);
                if (vk != 0) onKey(vk, k.mods);
            },
            .button => |b| onButton(b.x, b.y, b.button, b.down),
            .motion => |m| onMotion(m.x, m.y),
            .closed => if (app.request != null) cancelRequest("the drawing window was closed") else finishDraw(),
        },
    }
}

fn onButton(x: i32, y: i32, button: u8, down: bool) void {
    if (app.draw == null) return;
    app.draw.?.cursor = .{ x, y };
    if (button == 1) {
        if (down) beginStroke(.{ x, y }) else endStroke();
    } else if (button == 3 and !down) finishDraw();
}

fn onMotion(x: i32, y: i32) void {
    if (app.draw == null) return;
    app.draw.?.cursor = .{ x, y };
    if (app.draw.?.current != null) moveStroke(.{ x, y });
}

fn runTimers() void {
    const now = util.nowMs();
    for (&app.timers, 0..) |*t, id| {
        if (t.* == 0 or t.* > now) continue;
        t.* = 0;
        switch (id) {
            TIMER_REQUEST => cancelRequest("timed out waiting for the user"),
            TIMER_CAPTURE => endCapture(null),
            TIMER_AUTODRAW => {
                scriptedStrokes();
                finishDraw();
            },
            else => {},
        }
    }
}

/// One iteration of the main loop; waits at most `max_wait_ms`.
fn step(max_wait_ms: i32) void {
    var timeout: i32 = max_wait_ms;
    const now = util.nowMs();
    for (app.timers) |t| if (t != 0) {
        timeout = @min(timeout, @as(i32, @intCast(@min(if (t > now) t - now else 0, 1 << 30))));
    };
    if (app.bus) |b| if (b.queue.items.len > 0) {
        timeout = 0;
    };
    var fds: [3]sys.PollFd = undefined;
    var n: usize = 0;
    fds[n] = .{ .fd = wake.fd, .events = sys.POLLIN };
    n += 1;
    const disp_i = n;
    if (app.disp) |d| {
        fds[n] = .{ .fd = d.fd(), .events = sys.POLLIN };
        n += 1;
    }
    const bus_i = n;
    if (app.bus) |b| {
        fds[n] = .{ .fd = b.fd, .events = sys.POLLIN };
        n += 1;
    }
    _ = sys.poll(&fds, n, timeout);
    if (signalled.load(.acquire)) {
        signalled.store(false, .release);
        quit();
        return;
    }
    if (fds[0].revents != 0) {
        wake.drain();
        handleMessages();
    }
    if (app.disp) |d| if (fds[disp_i].revents != 0) {
        const r = switch (d) {
            .x => |x| x.dispatch(),
            .wl => |w| w.dispatch(),
        };
        r catch {
            util.log("  lost the connection to the display", .{});
            app.disp = null;
            if (app.request != null) cancelRequest("the display connection was lost");
            if (app.draw) |_| abortDraw();
        };
    };
    handleDisplayEvents();
    if (app.bus) |b| {
        if (bus_i < n and fds[bus_i].revents != 0) b.fill() catch {
            util.log("  lost the D-Bus connection", .{});
        };
        while (b.next()) |msg| {
            var m = msg;
            onBus(&m);
            m.deinit(util.gpa);
            if (app.quitting) break;
        }
    }
    runTimers();
    presentDirty();
}

fn loop() void {
    while (!app.quitting) step(60_000);
}

fn onSignal(_: c_int) callconv(.c) void {
    signalled.store(true, .release);
    wake.signal();
}

// ------------------------------------------------------------------ setup & entry points

fn connectDisplay() ?Disp {
    if (sys.env("WAYLAND_DISPLAY") != null) {
        if (wayland.Wl.connect(util.gpa)) |w| return .{ .wl = w } else |e| util.log("  Wayland: {s}", .{@errorName(e)});
    }
    if (sys.env("DISPLAY") != null) {
        if (x11.X11.connect(util.gpa)) |x| return .{ .x = x } else |e| util.log("  X11: {s}", .{@errorName(e)});
    }
    return null;
}

fn init(opts: Options, interactive: bool) !void {
    wake = try sys.Wake.init();
    const disp = connectDisplay();
    app = .{
        .opts = opts,
        .disp = disp,
        .wk = try worker.Worker.spawn(if (disp) |d| d == .wl else false),
        .interactive = interactive,
    };
    app.bus = dbus.Conn.session(util.gpa) catch null;
    if (app.bus) |b| if (disp != null and disp.? == .wl) desktop.registerHostApp(b);
    loadFonts();
    try util.mkdirAll(opts.out_dir);
    _ = sys.signal(sys.SIGINT, @intFromPtr(&onSignal));
    _ = sys.signal(sys.SIGTERM, @intFromPtr(&onSignal));
    _ = sys.signal(sys.SIGHUP, @intFromPtr(&onSignal));
    _ = sys.signal(sys.SIGPIPE, sys.SIG_IGN);
    app_ready = true;
}

/// Interactive tray app.
pub fn run(opts: Options) !void {
    try init(opts, true);
    const bus = app.bus orelse {
        util.log("no D-Bus session bus: the tray icon, notifications and Wayland screenshots need one", .{});
        return error.NoSessionBus;
    };
    if (!(bus.requestName(desktop.APP_ID) catch false)) {
        util.log("annotation-helper is already running — look for its icon in the panel/tray.", .{});
        _ = desktop.notify(bus, "annotation-helper is already running", "Look for its icon in the panel or tray.", false, false);
        return;
    }
    if (app.disp == null) util.log("  no display (X11 or Wayland): drawing is unavailable", .{});
    const cfg = opts.config orelse config.Config{};
    const cfg_path = try config.path(util.gpa);
    defer util.gpa.free(cfg_path);
    if (!util.exists(cfg_path)) config.save(cfg) catch {};

    // "Show last brief" works right after a restart, too.
    if (util.listDir(util.gpa, opts.out_dir, true)) |names| {
        defer util.freeNames(util.gpa, names);
        std.mem.sort([]u8, names, {}, struct {
            fn gt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .gt;
            }
        }.gt);
        for (names) |n| {
            const brief = util.join(util.gpa, &.{ opts.out_dir, n, "brief.md" }) catch continue;
            defer util.gpa.free(brief);
            if (util.exists(brief)) {
                app.last_dir = util.join(util.gpa, &.{ opts.out_dir, n }) catch null;
                break;
            }
        }
    } else |_| {}

    var problems: [700]u8 = undefined;
    var np: usize = 0;
    for ([_][]const u8{ cfg.hotkeys.session, cfg.hotkeys.draw }, 0..) |s, slot| {
        app.hotkeys[slot] = Hotkey.parse(s) catch |e| blk: {
            const m = std.fmt.bufPrint(problems[np..], "{s} hotkey: {s}. ", .{ HOTKEY_NAMES[slot], config.errorText(e) }) catch "";
            np += m.len;
            break :blk null;
        };
    }

    app.tray = tray_mod.Tray.init(bus) catch null;
    desktop.watchNotifications(bus);
    updateTray();
    if (app.tray) |t| if (!t.registered) util.log("  no tray host found (GNOME needs the AppIndicator extension); use the hotkeys or `annotation-helper draw`", .{});

    var shortcut_problem: []const u8 = "";
    if (isWayland()) {
        shortcut_problem = bindPortalShortcuts();
    } else np += registerHotkeys(problems[np..]).len;
    updateTray();

    var l0: [64]u8 = undefined;
    var l1: [64]u8 = undefined;
    util.log("  {s}  start/stop recording\n  {s}  draw / finish screenshot", .{ hotkeyLabel(0, &l0), hotkeyLabel(1, &l1) });
    util.log("Sessions go to {s}", .{opts.out_dir});
    if (shortcut_problem.len > 0) {
        var mb: [400]u8 = undefined;
        balloon("No global shortcuts", std.fmt.bufPrint(&mb, "Wayland: {s}. Bind the commands \u{201c}annotation-helper draw\u{201d} and \u{201c}annotation-helper toggle\u{201d} in your keyboard settings.", .{shortcut_problem}) catch "", true);
    } else if (np == 0) {
        var mb: [256]u8 = undefined;
        balloon("annotation-helper is running", std.fmt.bufPrint(&mb, "{s} draw on screen · {s} start/stop recording.", .{ hotkeyLabel(1, &l1), hotkeyLabel(0, &l0) }) catch "", false);
    } else {
        var mb: [800]u8 = undefined;
        balloon("Hotkey problem", std.fmt.bufPrint(&mb, "{s}Change it via the tray menu → Hotkeys.", .{problems[0..np]}) catch "", true);
    }
    loop();
}

/// MCP server mode: protocol on another thread, UI here; no hotkeys, no tray.
pub fn runMcp(opts: Options, serve: *const fn () void) !void {
    try init(opts, false);
    const t = try std.Thread.spawn(util.thread_cfg, struct {
        fn go(f: *const fn () void) void {
            f();
            post(.quit); // stdin closed: the client is gone
        }
    }.go, .{serve});
    t.detach();
    loop();
}

/// Non-interactive end-to-end check: a session with one scripted screenshot.
pub fn selftest(opts: Options) !void {
    try init(opts, false);
    if (app.disp == null) {
        util.log("selftest needs a display (X11 or Wayland)", .{});
        return error.NoDisplay;
    }
    const pump = struct {
        fn f(ms: u64) void {
            const until = util.nowMs() + ms;
            while (util.nowMs() < until and !app.quitting) step(10);
        }
    }.f;
    try startDraw();
    scriptedStrokes();
    pump(1200);
    finishDraw();
    pump(200);
    quit();
}
