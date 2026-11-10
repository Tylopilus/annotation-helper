//! Recorder UI on the main thread: tray icon + menu, global hotkeys, the drawing overlay,
//! status pill, request banner, hotkey capture, agent requests and the session state machine.

const std = @import("std");
const w = @import("win32").everything;
const util = @import("util.zig");
const model = @import("model.zig");
const raster = @import("raster.zig");
const config = @import("config.zig");
const audio = @import("audio.zig");
const worker = @import("worker.zig");
const Hotkey = config.Hotkey;
const Rect = model.Rect;
const Bgra = raster.Bgra;
const L = util.L;

const HK_SESSION = 1;
const HK_DRAW = 2;
const WM_APP_KEY = w.WM_APP + 1;
const WM_APP_QUIT = w.WM_APP + 2;
const WM_APP_ANNOTATE = w.WM_APP + 3;
const WM_APP_CANCEL = w.WM_APP + 4;
const WM_APP_CAPTURED = w.WM_APP + 5;
const WM_APP_TRAY = w.WM_APP + 20;
const TIMER_REQUEST = 1;
const TIMER_AUTODRAW = 2;
const TIMER_CAPTURE = 3;
const KEY_CTRL: isize = 1;
const KEY_SHIFT: isize = 2;

const ID_SESSION = 10;
const ID_DRAW = 11;
const ID_OPEN_SESSIONS = 12;
const ID_SHOW_LAST = 13;
const ID_HK_SESSION = 20;
const ID_HK_DRAW = 21;
const ID_HK_RESET = 22;
const ID_CONFIG = 23;
const ID_QUIT = 99;

const HOOK_DRAW = 1;
const HOOK_CAPTURE = 2;
var hook_mode = std.atomic.Value(u8).init(HOOK_DRAW);

const HOTKEY_NAMES = [2][]const u8{ "Start/stop recording", "Draw on screen" };
/// Overlay tint while drawing; non-zero alpha so the overlay receives the mouse.
const TINT = Bgra{ .b = 0, .g = 0, .r = 0, .a = 28 };

pub const Options = struct {
    out_dir: []const u8,
    no_audio: bool = false,
    /// Use this WAV instead of the microphone (selftest).
    audio_file: ?[]const u8 = null,
    /// Extra arguments for `process` (quoted), or null to skip processing.
    process_args: ?[]const u8 = "",
    /// Interactive tray app with hotkeys (null for selftest / MCP mode).
    config: ?config.Config = null,
};

// ------------------------------------------------------------------ surface

/// A premultiplied 32-bit DIB selected into a memory DC (layered-window content).
const Surface = struct {
    dc: w.HDC,
    bmp: w.HBITMAP,
    old: ?w.HGDIOBJ,
    px: []Bgra,
    width: i32,
    height: i32,

    fn init(width: i32, height: i32) !Surface {
        const dc = w.CreateCompatibleDC(null);
        var bmi = std.mem.zeroes(w.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = width;
        bmi.bmiHeader.biHeight = -height;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        var bits: ?*anyopaque = null;
        const bmp = w.CreateDIBSection(dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0) orelse {
            _ = w.DeleteDC(dc);
            return error.OutOfMemory;
        };
        const old = w.SelectObject(dc, bmp);
        const ptr: [*]Bgra = @ptrCast(@alignCast(bits.?));
        return .{ .dc = dc, .bmp = bmp, .old = old, .px = ptr[0..@intCast(width * height)], .width = width, .height = height };
    }

    fn deinit(s: *Surface) void {
        _ = w.SelectObject(s.dc, s.old);
        _ = w.DeleteObject(s.bmp);
        _ = w.DeleteDC(s.dc);
    }

    fn canvas(s: *Surface) raster.Canvas {
        return .{ .px = s.px, .w = s.width, .h = s.height };
    }

    fn present(s: *const Surface, hwnd: w.HWND, x: i32, y: i32, dirty: ?Rect) void {
        const dst = w.POINT{ .x = x, .y = y };
        const size = w.SIZE{ .cx = s.width, .cy = s.height };
        const src = w.POINT{ .x = 0, .y = 0 };
        const bf = w.BLENDFUNCTION{ .BlendOp = w.AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = w.AC_SRC_ALPHA };
        const rc: ?w.RECT = if (dirty) |d| .{ .left = d.x, .top = d.y, .right = d.right(), .bottom = d.bottom() } else null;
        var info = w.UPDATELAYEREDWINDOWINFO{
            .cbSize = @sizeOf(w.UPDATELAYEREDWINDOWINFO),
            .hdcDst = null,
            .pptDst = &dst,
            .psize = &size,
            .hdcSrc = s.dc,
            .pptSrc = &src,
            .crKey = .fromInt(0),
            .pblend = &bf,
            .dwFlags = w.ULW_ALPHA,
            .prcDirty = if (rc) |*r| r else null,
        };
        _ = w.UpdateLayeredWindowIndirect(hwnd, &info);
    }
};

// ------------------------------------------------------------------ screen helpers

pub fn virtualScreen() Rect {
    const x = w.GetSystemMetrics(w.SM_XVIRTUALSCREEN);
    const y = w.GetSystemMetrics(w.SM_YVIRTUALSCREEN);
    return .{ .x = x, .y = y, .w = w.GetSystemMetrics(w.SM_CXVIRTUALSCREEN), .h = w.GetSystemMetrics(w.SM_CYVIRTUALSCREEN) };
}

const MonitorList = struct { items: [16]model.Monitor = undefined, n: usize = 0 };

fn monitorCb(hm: ?w.HMONITOR, _: ?w.HDC, _: ?*w.RECT, data: w.LPARAM) callconv(.winapi) w.BOOL {
    const list: *MonitorList = @ptrFromInt(@as(usize, @bitCast(data)));
    var mi = std.mem.zeroes(w.MONITORINFO);
    mi.cbSize = @sizeOf(w.MONITORINFO);
    if (list.n < list.items.len and w.GetMonitorInfoW(hm, &mi) != 0) {
        const r = mi.rcMonitor;
        list.items[list.n] = .{ .rect = Rect.ltrb(r.left, r.top, r.right, r.bottom), .primary = mi.dwFlags & w.MONITORINFOF_PRIMARY != 0 };
        list.n += 1;
    }
    return w.TRUE;
}

pub fn monitors() MonitorList {
    var list = MonitorList{};
    _ = w.EnumDisplayMonitors(null, null, monitorCb, @bitCast(@intFromPtr(&list)));
    return list;
}

fn primary() Rect {
    const m = monitors();
    for (m.items[0..m.n]) |x| if (x.primary) return x.rect;
    return if (m.n > 0) m.items[0].rect else .{ .w = 1920, .h = 1080 };
}

/// BitBlt a screen area into opaque BGRA (gpa-owned).
fn capture(r: Rect) ![]Bgra {
    var s = try Surface.init(r.w, r.h);
    defer s.deinit();
    const screen = w.GetDC(null);
    defer _ = w.ReleaseDC(null, screen);
    if (w.BitBlt(s.dc, 0, 0, r.w, r.h, screen, r.x, r.y, w.SRCCOPY) == 0) return error.BitBlt;
    const out = try util.gpa.dupe(Bgra, s.px);
    for (out) |*p| p.a = 255;
    return out;
}

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

const Drawing = struct {
    virt: Rect,
    surface: Surface,
    /// Finished strokes; points are gpa-owned.
    strokes: std.ArrayList(model.Stroke) = .empty,
    current: ?Current = null,
    t_start: u64,
    fg_title: []u8 = &.{},
    fg_process: []u8 = &.{},
    hook: ?w.HHOOK = null,
};

pub const Request = struct {
    prompt: []const u8,
    asker: []const u8,
    voice: bool,
    timeout_ms: u32,
    reply: *worker.Reply,
};

var req_lock: w.RTL_SRWLOCK = .{ .Ptr = null };
var req_queue: std.ArrayList(*Request) = .empty;

const App = struct {
    opts: Options,
    overlay: w.HWND,
    indicator: w.HWND,
    banner: w.HWND,
    tray_hwnd: w.HWND,
    wk: *worker.Worker,
    session: ?Active = null,
    draw: ?Drawing = null,
    tool: model.Tool = .pen,
    color: model.ColorName = .red,
    prev_color: model.ColorName = .red,
    request: ?*Request = null,
    tray: ?Tray = null,
    hotkeys: [2]?Hotkey = .{ null, null },
    capturing: ?struct { slot: usize, hook: ?w.HHOOK } = null,
    last_dir: ?[]u8 = null,
};

var app: App = undefined;
var app_ready = false;

fn elapsed() u64 {
    return if (app.session) |s| util.nowMs() - s.t0 else 0;
}

fn sendJob(kind: worker.Kind) void {
    const arena = worker.newArena() catch return;
    const job = util.gpa.create(worker.Job) catch return;
    job.* = .{ .arena = arena, .kind = kind };
    app.wk.send(job);
}

fn sendJobWith(arena: *std.heap.ArenaAllocator, kind: worker.Kind) void {
    const job = util.gpa.create(worker.Job) catch return;
    job.* = .{ .arena = arena, .kind = kind };
    app.wk.send(job);
}

// ------------------------------------------------------------------ session

fn startSession(with_audio: bool, for_request: bool) !void {
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
    // Transcribe while recording, so the brief is ready right after the session ends.
    var live_args: ?[]const u8 = null;
    if (active.recorder != null) if (app.opts.process_args) |pa| {
        live_args = if (for_request) try a.print("{s} --no-clipboard", .{pa}) else try a.dupe(u8, pa);
    };
    sendJobWith(arena, .{ .begin = .{
        .session = .{ .id = try a.dupe(u8, &ts.id), .started_local = try a.dupe(u8, &ts.human), .monitors = try a.dupe(model.Monitor, mons.items[0..mons.n]) },
        .dir = try a.dupe(u8, dir),
        .live_args = live_args,
    } });
    app.session = active;
    updateIndicator();
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
        const dst = util.join(util.gpa, &.{ s.dir, "audio.wav" }) catch null;
        if (dst) |d| {
            defer util.gpa.free(d);
            if (util.readFile(util.gpa, src)) |bytes| {
                defer util.gpa.free(bytes);
                util.writeFile(d, bytes) catch {};
                if (bytes.len > 28) audio_info = .{ .file = "audio.wav", .sample_rate = std.mem.readInt(u32, bytes[24..28], .little), .offset_ms = 0 };
            } else |_| {}
        }
    }
    var tbuf: [16]u8 = undefined;
    util.log("■ Session stopped ({s}, {d} screenshot(s))", .{ util.fmtTime(&tbuf, @intCast(duration)), s.frames });
    const arena = worker.newArena() catch return;
    var args: ?[]const u8 = null;
    if (app.opts.process_args) |pa| {
        args = if (reply != null) arena.allocator().print("{s} --no-clipboard", .{pa}) catch pa else pa;
    }
    const notify: ?w.HWND = if (reply == null and app.tray != null) app.overlay else null;
    if (notify != null and args != null) balloon("Session saved", "Transcribing… you'll get a notification when the brief is ready.", false);
    sendJobWith(arena, .{ .end = .{ .duration_ms = duration, .audio = audio_info, .process_args = args, .wait = wait, .reply = reply, .notify_hwnd = notify } });
    updateIndicator();
}

// ------------------------------------------------------------------ drawing

fn startDraw() !void {
    try startSession(true, false);
    const fg = w.GetForegroundWindow();
    var warm: [2][2]i32 = undefined;
    var nwarm: usize = 0;
    var cursor: w.POINT = undefined;
    if (w.GetCursorPos(&cursor) != 0) {
        warm[nwarm] = .{ cursor.x, cursor.y };
        nwarm += 1;
    }
    var wr: w.RECT = undefined;
    if (fg != null and w.GetWindowRect(fg, &wr) != 0) {
        warm[nwarm] = .{ @divTrunc(wr.left + wr.right, 2), @divTrunc(wr.top + wr.bottom, 2) };
        nwarm += 1;
    }
    if (worker.newArena()) |arena| {
        sendJobWith(arena, .{ .warmup = arena.allocator().dupe([2]i32, warm[0..nwarm]) catch &.{} });
    } else |_| {}

    const virt = virtualScreen();
    var surface = try Surface.init(virt.w, virt.h);
    @memset(surface.px, TINT);
    _ = w.SetWindowPos(app.overlay, w.HWND_TOPMOST, virt.x, virt.y, virt.w, virt.h, w.SWP_NOACTIVATE);
    surface.present(app.overlay, virt.x, virt.y, null);
    _ = w.ShowWindow(app.overlay, w.SW_SHOWNOACTIVATE);
    var d = Drawing{ .virt = virt, .surface = surface, .t_start = elapsed() };
    if (util.windowInfo(util.gpa, fg)) |info| {
        d.fg_title = info.title;
        d.fg_process = info.process;
    }
    hook_mode.store(HOOK_DRAW, .release);
    d.hook = w.SetWindowsHookExW(w.WH_KEYBOARD_LL, kbHook, w.GetModuleHandleW(null), 0);
    app.draw = d;
    util.log("  ✎ drawing ({s}, {s}) — Esc/right-click to finish", .{ app.tool.label(), @tagName(app.color) });
    updateIndicator();
}

fn freeDrawing(d: *Drawing) void {
    for (d.strokes.items) |s| util.gpa.free(s.points);
    d.strokes.deinit(util.gpa);
    if (d.current) |*c| c.points.deinit(util.gpa);
    util.gpa.free(d.fg_title);
    util.gpa.free(d.fg_process);
    d.surface.deinit();
}

fn hideOverlay(d: *Drawing) void {
    if (d.hook) |h| _ = w.UnhookWindowsHookEx(h);
    d.hook = null;
    _ = w.ReleaseCapture();
    _ = w.ShowWindow(app.overlay, w.SW_HIDE);
    _ = w.ShowWindow(app.banner, w.SW_HIDE);
}

fn finishDraw() void {
    endStroke();
    var d = app.draw orelse return;
    app.draw = null;
    defer freeDrawing(&d);
    const t_end = elapsed();
    hideOverlay(&d);
    _ = w.DwmFlush(); // make sure the overlay is gone from the composed screen

    // Capture the monitors the annotations touch (or the one under the cursor).
    const mons = monitors();
    var area = Rect{};
    for (d.strokes.items) |s| for (mons.items[0..mons.n]) |m| {
        if (m.rect.intersect(s.bbox) != null) area = area.unite(m.rect);
    };
    if (area.isEmpty()) {
        var p: w.POINT = .{ .x = 0, .y = 0 };
        _ = w.GetCursorPos(&p);
        area = primary();
        for (mons.items[0..mons.n]) |m| if (m.rect.contains(p.x, p.y)) {
            area = m.rect;
        };
    }
    const pixels = capture(area) catch |e| {
        util.log("  screenshot failed: {s}", .{@errorName(e)});
        cancelRequest("taking the screenshot failed");
        updateIndicator();
        return;
    };
    if (app.session == null) return;
    app.session.?.frames += 1;
    const index = app.session.?.frames;
    const arena = worker.newArena() catch return;
    const a = arena.allocator();
    const strokes = a.alloc(model.Stroke, d.strokes.items.len) catch return;
    for (d.strokes.items, strokes) |src, *dst| {
        dst.* = src;
        dst.points = a.dupe([2]i32, src.points) catch &.{};
    }
    const fg: ?model.WindowInfo = if (d.fg_process.len > 0 or d.fg_title.len > 0) .{ .title = a.dupe(u8, d.fg_title) catch "", .process = a.dupe(u8, d.fg_process) catch "" } else null;
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
    updateIndicator();
    if (app.request) |req| {
        app.request = null;
        endRequestUi();
        stopSession(false, req.reply);
    }
}

/// Re-render `dirty` (absolute coords) of the overlay and push it to the window.
fn redraw(dirty: Rect) void {
    if (app.draw == null) return;
    const dr = &app.draw.?;
    const area = dirty.intersect(dr.virt) orelse return;
    const canvas = raster.Canvas{ .px = dr.surface.px, .w = dr.surface.width, .h = dr.surface.height, .ox = dr.virt.x, .oy = dr.virt.y };
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const row: usize = @intCast((y - dr.virt.y) * dr.surface.width + (area.x - dr.virt.x));
        @memset(dr.surface.px[row..][0..@intCast(area.w)], TINT);
    }
    for (dr.strokes.items) |*s| raster.render(util.gpa, canvas, s, area, true);
    if (dr.current) |*c| {
        const preview = c.stroke(if (app.session) |s| s.next_id else 1);
        raster.render(util.gpa, canvas, &preview, area, true);
    }
    dr.surface.present(app.overlay, dr.virt.x, dr.virt.y, area.offset(-dr.virt.x, -dr.virt.y));
}

fn beginStroke(p: [2]i32) void {
    if (app.draw == null) return;
    var c = Current{ .tool = app.tool, .color = app.color, .t_start = elapsed() };
    c.points.append(util.gpa, p) catch return;
    app.draw.?.current = c;
    _ = w.SetCapture(app.overlay);
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
    _ = w.ReleaseCapture();
    var s = c.stroke(0);
    const area = raster.bounds(&s);
    if (raster.isMeaningful(&s)) {
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
    const m = primary();
    const c = m.center();
    addStroke(.rectangle, .red, &.{ .{ c[0] - 220, c[1] - 70 }, .{ c[0] + 220, c[1] + 70 } });
    addStroke(.arrow, .blue, &.{ .{ m.x + @divTrunc(m.w, 6), m.y + @divTrunc(m.h, 5) }, .{ c[0] - 230, c[1] - 60 } });
    addStroke(.ellipse, .green, &.{ .{ m.x + @divTrunc(m.w * 2, 3), m.y + @divTrunc(m.h, 6) }, .{ m.x + @divTrunc(m.w * 5, 6), m.y + @divTrunc(m.h, 3) } });
    var hl: [40][2]i32 = undefined;
    for (&hl, 0..) |*p, i| p.* = .{ m.x + @divTrunc(m.w, 8) + @as(i32, @intCast(i)) * 8, m.y + @divTrunc(m.h * 3, 4) };
    addStroke(.highlighter, .yellow, &hl);
}

// ------------------------------------------------------------------ keys & hotkeys

fn onKey(vk: u32, flags: isize) void {
    const ctrl = flags & KEY_CTRL != 0;
    const shift = flags & KEY_SHIFT != 0;
    switch (vk) {
        0x1B => if (shift and app.request != null) cancelRequest("the user cancelled") else finishDraw(),
        0x0D, 0x20 => finishDraw(),
        0x08 => undo(),
        0x2E => clearAll(),
        'Z' => if (ctrl) undo(),
        'P', 'H', 'R', 'E', 'O', 'A' => {
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
            updateIndicator();
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
    updateIndicator();
}

fn onHotkey(id: usize) void {
    switch (id) {
        HK_SESSION => if (app.session != null) stopSession(false, null) else startSession(true, false) catch |e| util.log("  error: {s}", .{@errorName(e)}),
        HK_DRAW => if (app.draw != null) finishDraw() else startDraw() catch |e| util.log("  error: {s}", .{@errorName(e)}),
        else => {},
    }
}

fn hotkeyLabel(slot: usize, buf: []u8) []const u8 {
    return if (app.hotkeys[slot]) |h| h.label(buf) else "(none)";
}

/// (Re-)register both hotkeys; returns the number of failures (and a message).
fn registerHotkeys(problem: []u8) []const u8 {
    var n: usize = 0;
    for ([_]usize{ 0, 1 }, [_]i32{ HK_SESSION, HK_DRAW }) |slot, id| {
        _ = w.UnregisterHotKey(app.overlay, id);
        const hk = app.hotkeys[slot] orelse continue;
        const mods: w.HOT_KEY_MODIFIERS = @bitCast(hk.mods | 0x4000); // MOD_NOREPEAT
        if (w.RegisterHotKey(app.overlay, id, mods, hk.vk) == 0) {
            var lb: [64]u8 = undefined;
            const s = std.fmt.bufPrint(problem[n..], "{s} is already used by another app ({s}). ", .{ hk.label(&lb), HOTKEY_NAMES[slot] }) catch break;
            n += s.len;
        }
    }
    return problem[0..n];
}

fn unregisterHotkeys() void {
    _ = w.UnregisterHotKey(app.overlay, HK_SESSION);
    _ = w.UnregisterHotKey(app.overlay, HK_DRAW);
}

fn beginCapture(slot: usize) void {
    if (app.capturing != null or app.draw != null or app.request != null) return;
    unregisterHotkeys(); // so pressing the current combo is captured, not triggered
    hook_mode.store(HOOK_CAPTURE, .release);
    const hook = w.SetWindowsHookExW(w.WH_KEYBOARD_LL, kbHook, w.GetModuleHandleW(null), 0);
    app.capturing = .{ .slot = slot, .hook = hook };
    showCaptureBanner(slot, null);
    _ = w.SetTimer(app.overlay, TIMER_CAPTURE, 20_000, null);
}

fn showCaptureBanner(slot: usize, err: ?[]const u8) void {
    var t: [128]u8 = undefined;
    var h: [256]u8 = undefined;
    var lb: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&t, "Press the new shortcut for \u{201c}{s}\u{201d}", .{HOTKEY_NAMES[slot]}) catch "";
    const help = if (err) |e|
        std.fmt.bufPrint(&h, "{s} — try another combination · Esc cancels", .{e}) catch ""
    else
        std.fmt.bufPrint(&h, "Currently {s} · use Ctrl, Alt or Win plus a key (or an F-key) · Esc cancels", .{hotkeyLabel(slot, &lb)}) catch "";
    showBanner(title, help);
}

fn onCaptured(vk: u32, mods: u32) void {
    const c = app.capturing orelse return;
    if (vk == 0x1B and mods == 0) return endCapture(null);
    const hk = Hotkey{ .mods = mods, .vk = vk };
    var lb: [64]u8 = undefined;
    var eb: [160]u8 = undefined;
    hk.validate() catch |e| {
        const msg = std.fmt.bufPrint(&eb, "{s} {s}", .{ hk.label(&lb), config.errorText(e) }) catch "";
        return showCaptureBanner(c.slot, msg);
    };
    if (app.hotkeys[1 - c.slot]) |other| if (other.eql(hk)) {
        const msg = std.fmt.bufPrint(&eb, "{s} is already the {s} hotkey", .{ hk.label(&lb), HOTKEY_NAMES[1 - c.slot] }) catch "";
        return showCaptureBanner(c.slot, msg);
    };
    endCapture(hk);
}

fn endCapture(new: ?Hotkey) void {
    const c = app.capturing orelse return;
    app.capturing = null;
    if (c.hook) |h| _ = w.UnhookWindowsHookEx(h);
    _ = w.KillTimer(app.overlay, TIMER_CAPTURE);
    _ = w.ShowWindow(app.banner, w.SW_HIDE);
    hook_mode.store(HOOK_DRAW, .release);
    var pb: [512]u8 = undefined;
    const hk = new orelse {
        _ = registerHotkeys(&pb);
        return;
    };
    const old = app.hotkeys[c.slot];
    app.hotkeys[c.slot] = hk;
    const problems = registerHotkeys(&pb);
    var lb: [64]u8 = undefined;
    var mb: [600]u8 = undefined;
    if (problems.len > 0) {
        const msg = std.fmt.bufPrint(&mb, "{s}Kept {s}.", .{ problems, if (old) |o| o.label(&lb) else "(none)" }) catch "";
        app.hotkeys[c.slot] = old;
        var pb2: [512]u8 = undefined;
        _ = registerHotkeys(&pb2);
        balloon("Hotkey not changed", msg, true);
    } else {
        saveHotkeys();
        balloon("Hotkey changed", std.fmt.bufPrint(&mb, "{s}: {s}", .{ HOTKEY_NAMES[c.slot], hk.label(&lb) }) catch "", false);
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
    c.hotkeys.session = hotkeyLabel(0, &hk_label_store[0]);
    c.hotkeys.draw = hotkeyLabel(1, &hk_label_store[1]);
    app.opts.config = c;
    config.save(c) catch balloon("Settings not saved", "Could not write config.json next to the exe.", true);
}

// ------------------------------------------------------------------ requests (MCP)

/// Called from an MCP thread: ask the user to annotate; blocks until answered.
pub fn annotate(req: *Request) void {
    w.AcquireSRWLockExclusive(&req_lock);
    req_queue.append(util.gpa, req) catch {};
    w.ReleaseSRWLockExclusive(&req_lock);
    _ = w.PostMessageW(app.overlay, WM_APP_ANNOTATE, 0, 0);
    _ = w.WaitForSingleObject(req.reply.event, req.timeout_ms + 900_000);
}

pub fn cancelAnnotation() void {
    _ = w.PostMessageW(app.overlay, WM_APP_CANCEL, 0, 0);
}

fn replyErr(r: *worker.Reply, msg: []const u8) void {
    r.ok = false;
    r.text = util.gpa.dupe(u8, msg) catch &.{};
    _ = w.SetEvent(r.event);
}

fn beginRequests() void {
    w.AcquireSRWLockExclusive(&req_lock);
    const pending = req_queue.toOwnedSlice(util.gpa) catch &.{};
    w.ReleaseSRWLockExclusive(&req_lock);
    defer util.gpa.free(pending);
    for (pending) |req| {
        if (app.request != null or app.session != null) {
            replyErr(req.reply, "the user is already recording or annotating; try again later");
            continue;
        }
        startSession(req.voice, true) catch {
            replyErr(req.reply, "could not start a session");
            continue;
        };
        startDraw() catch {
            stopSession(false, null);
            replyErr(req.reply, "could not start drawing");
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
        _ = w.SetTimer(app.overlay, TIMER_REQUEST, req.timeout_ms, null);
        var env: [8]u16 = undefined;
        if (w.GetEnvironmentVariableW(L("ANNOTATION_HELPER_TEST_AUTODRAW"), @ptrCast(&env), env.len) > 0) {
            _ = w.SetTimer(app.overlay, TIMER_AUTODRAW, 1500, null);
        }
    }
}

/// Abort the agent request: no screenshot, recording discarded.
fn cancelRequest(why: []const u8) void {
    const req = app.request orelse return;
    app.request = null;
    endRequestUi();
    if (app.draw) |_| {
        hideOverlay(&app.draw.?);
        freeDrawing(&app.draw.?);
        app.draw = null;
    }
    if (app.session) |s| {
        if (s.recorder) |rec| _ = rec.stop(s.t0);
        util.gpa.free(s.dir);
        app.session = null;
    }
    sendJob(.discard);
    updateIndicator();
    util.log("  request cancelled: {s}", .{why});
    replyErr(req.reply, why);
}

fn endRequestUi() void {
    _ = w.KillTimer(app.overlay, TIMER_REQUEST);
    _ = w.KillTimer(app.overlay, TIMER_AUTODRAW);
    _ = w.ShowWindow(app.banner, w.SW_HIDE);
}

// ------------------------------------------------------------------ indicator & banner

/// Status pill top-right on the primary monitor: red dot while recording, plus the
/// current tool/color while drawing. Hidden when idle.
fn updateIndicator() void {
    updateTray();
    if (app.session == null) {
        _ = w.ShowWindow(app.indicator, w.SW_HIDE);
        return;
    }
    const iw: i32 = if (app.draw != null) 64 else 34;
    const ih: i32 = 34;
    var s = Surface.init(iw, ih) catch return;
    defer s.deinit();
    @memset(s.px, .{ .b = 0, .g = 0, .r = 0, .a = 0 });
    const c = s.canvas();
    raster.line(util.gpa, c, .{ 17, 17 }, .{ @floatFromInt(iw - 17), 17 }, 15, .{ 25, 25, 25 }, 210);
    raster.disc(util.gpa, c, 17, 17, 7, .{ 230, 30, 30 }, 255);
    if (app.draw != null) raster.toolGlyph(util.gpa, c, app.tool, app.color, 45, 17);
    const p = primary();
    const x = p.right() - iw - 16;
    const y = p.y + 12;
    _ = w.SetWindowPos(app.indicator, w.HWND_TOPMOST, x, y, iw, ih, w.SWP_NOACTIVATE);
    s.present(app.indicator, x, y, null);
    _ = w.ShowWindow(app.indicator, w.SW_SHOWNOACTIVATE);
}

/// Opaque text banner at the top of the monitor under the cursor (GDI text).
fn showBanner(title: []const u8, help: []const u8) void {
    const dpi: i32 = @intCast(@max(w.GetDpiForSystem(), 96));
    const sc = struct {
        fn f(v: i32, d: i32) i32 {
            return @divTrunc(v * d, 96);
        }
    }.f;
    var cursor: w.POINT = .{ .x = 0, .y = 0 };
    _ = w.GetCursorPos(&cursor);
    var mon = primary();
    const mons = monitors();
    for (mons.items[0..mons.n]) |m| if (m.rect.contains(cursor.x, cursor.y)) {
        mon = m.rect;
    };
    const max_w = @min(@divTrunc(mon.w * 6, 10), sc(980, dpi));
    const f_title = w.CreateFontW(-sc(19, dpi), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 4, 0x20, L("Segoe UI"));
    const f_help = w.CreateFontW(-sc(13, dpi), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0x20, L("Segoe UI"));
    defer _ = w.DeleteObject(f_title);
    defer _ = w.DeleteObject(f_help);
    var tw16: [700]u16 = undefined;
    var hw16: [400]u16 = undefined;
    const t16 = util.wideInto(&tw16, title);
    const h16 = util.wideInto(&hw16, help);
    const fmt_calc = w.DRAW_TEXT_FORMAT{ .CALCRECT = 1, .WORDBREAK = 1, .NOPREFIX = 1 };
    const tmp = w.CreateCompatibleDC(null);
    var tr = w.RECT{ .left = 0, .top = 0, .right = max_w, .bottom = 0 };
    var hr = tr;
    _ = w.SelectObject(tmp, f_title);
    _ = w.DrawTextW(tmp, t16.ptr, @intCast(t16.len), &tr, fmt_calc);
    _ = w.SelectObject(tmp, f_help);
    _ = w.DrawTextW(tmp, h16.ptr, @intCast(h16.len), &hr, fmt_calc);
    _ = w.DeleteDC(tmp);
    const pad = sc(14, dpi);
    const gap = sc(6, dpi);
    const bar = sc(5, dpi);
    const bw = @max(tr.right, hr.right) + 2 * pad + bar;
    const bh = tr.bottom + gap + hr.bottom + 2 * pad;
    var s = Surface.init(bw, bh) catch return;
    defer s.deinit();
    for (s.px, 0..) |*p, i| {
        const x: i32 = @intCast(@mod(@as(i32, @intCast(i)), bw));
        p.* = if (x < bar) .{ .b = 0x30, .g = 0x8c, .r = 0xe8, .a = 255 } else .{ .b = 0x24, .g = 0x24, .r = 0x24, .a = 255 };
    }
    _ = w.SetBkMode(s.dc, .TRANSPARENT);
    const fmt_draw = w.DRAW_TEXT_FORMAT{ .WORDBREAK = 1, .NOPREFIX = 1 };
    _ = w.SelectObject(s.dc, f_title);
    _ = w.SetTextColor(s.dc, .rgb(255, 255, 255));
    var r1 = w.RECT{ .left = pad + bar, .top = pad, .right = pad + bar + max_w, .bottom = bh };
    _ = w.DrawTextW(s.dc, t16.ptr, @intCast(t16.len), &r1, fmt_draw);
    _ = w.SelectObject(s.dc, f_help);
    _ = w.SetTextColor(s.dc, .rgb(0xb8, 0xb8, 0xb8));
    var r2 = w.RECT{ .left = pad + bar, .top = pad + tr.bottom + gap, .right = pad + bar + max_w, .bottom = bh };
    _ = w.DrawTextW(s.dc, h16.ptr, @intCast(h16.len), &r2, fmt_draw);
    _ = w.SelectObject(s.dc, s.bmp);
    // GDI leaves alpha at 0 where it drew; the banner is fully opaque.
    for (s.px) |*p| p.a = 255;
    const x = mon.x + @divTrunc(mon.w - bw, 2);
    const y = mon.y + sc(18, dpi);
    _ = w.SetWindowPos(app.banner, w.HWND_TOPMOST, x, y, bw, bh, w.SWP_NOACTIVATE);
    s.present(app.banner, x, y, null);
    _ = w.ShowWindow(app.banner, w.SW_SHOWNOACTIVATE);
}

// ------------------------------------------------------------------ tray

const Tray = struct {
    idle: ?w.HICON,
    recording: ?w.HICON,
    taskbar_created: u32,

    fn data() w.NOTIFYICONDATAW {
        var d = std.mem.zeroes(w.NOTIFYICONDATAW);
        d.cbSize = @sizeOf(w.NOTIFYICONDATAW);
        d.hWnd = app.tray_hwnd;
        d.uID = 1;
        return d;
    }

    fn add(t: Tray, tip: []const u8, rec: bool) void {
        var d = data();
        _ = w.Shell_NotifyIconW(w.NIM_DELETE, &d);
        d.uFlags = .{ .MESSAGE = 1, .ICON = 1, .TIP = 1, .SHOWTIP = 1 };
        d.uCallbackMessage = WM_APP_TRAY;
        d.hIcon = if (rec) t.recording else t.idle;
        _ = util.wideInto(&d.szTip, tip);
        _ = w.Shell_NotifyIconW(w.NIM_ADD, &d);
        d.Anonymous.uVersion = w.NOTIFYICON_VERSION_4;
        _ = w.Shell_NotifyIconW(w.NIM_SETVERSION, &d);
    }

    fn set(t: Tray, tip: []const u8, rec: bool) void {
        var d = data();
        d.uFlags = .{ .ICON = 1, .TIP = 1, .SHOWTIP = 1 };
        d.hIcon = if (rec) t.recording else t.idle;
        _ = util.wideInto(&d.szTip, tip);
        _ = w.Shell_NotifyIconW(w.NIM_MODIFY, &d);
    }

    fn remove() void {
        var d = data();
        _ = w.Shell_NotifyIconW(w.NIM_DELETE, &d);
    }
};

fn balloon(title: []const u8, text: []const u8, warning: bool) void {
    if (app.tray == null) return;
    var d = Tray.data();
    d.uFlags = .{ .INFO = 1 };
    d.dwInfoFlags = if (warning) w.NIIF_WARNING else w.NIIF_INFO;
    _ = util.wideInto(&d.szInfoTitle, title);
    _ = util.wideInto(&d.szInfo, text);
    _ = w.Shell_NotifyIconW(w.NIM_MODIFY, &d);
}

fn trayTip(buf: []u8) []const u8 {
    if (app.session) |s| return std.fmt.bufPrint(buf, "annotation-helper — recording ({d} screenshot(s))", .{s.frames}) catch "";
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "annotation-helper — {s} draw · {s} record", .{ hotkeyLabel(1, &a), hotkeyLabel(0, &b) }) catch "";
}

fn updateTray() void {
    const t = app.tray orelse return;
    var buf: [128]u8 = undefined;
    t.set(trayTip(&buf), app.session != null);
}

/// Dark round badge with a white pen stroke; recording adds a red dot.
fn makeIcon(size: i32, rec: bool) ?w.HICON {
    var s = Surface.init(size, size) catch return null;
    defer s.deinit();
    @memset(s.px, .{ .b = 0, .g = 0, .r = 0, .a = 0 });
    const k = @as(f32, @floatFromInt(size)) / 32;
    const c = s.canvas();
    raster.disc(util.gpa, c, 16 * k, 16 * k, 15 * k, .{ 0x1e, 0x5a, 0xb0 }, 255);
    raster.line(util.gpa, c, .{ 9 * k, 23 * k }, .{ 22 * k, 10 * k }, 2.5 * k, .{ 255, 255, 255 }, 255);
    if (rec) {
        raster.disc(util.gpa, c, 24 * k, 24 * k, 7.5 * k, .{ 255, 255, 255 }, 255);
        raster.disc(util.gpa, c, 24 * k, 24 * k, 5.8 * k, .{ 230, 34, 34 }, 255);
    }
    // Icons want straight (non-premultiplied) alpha.
    for (s.px) |*p| {
        if (p.a == 0) continue;
        const a: u32 = p.a;
        p.b = @intCast(@min(255, (@as(u32, p.b) * 255 + a / 2) / a));
        p.g = @intCast(@min(255, (@as(u32, p.g) * 255 + a / 2) / a));
        p.r = @intCast(@min(255, (@as(u32, p.r) * 255 + a / 2) / a));
    }
    var zeros: [64 * 8]u8 = @splat(0);
    const mask = w.CreateBitmap(size, size, 1, 1, &zeros) orelse return null;
    defer _ = w.DeleteObject(mask);
    _ = w.SelectObject(s.dc, s.old);
    defer _ = w.SelectObject(s.dc, s.bmp);
    var info = w.ICONINFO{ .fIcon = w.TRUE, .xHotspot = 0, .yHotspot = 0, .hbmMask = mask, .hbmColor = s.bmp };
    return w.CreateIconIndirect(&info);
}

/// Dark tray menu when Windows is in dark mode (undocumented uxtheme ordinals,
/// stable since Windows 10 1903; skipped if absent).
fn allowDarkMenus(owner: w.HWND) void {
    const ux = w.LoadLibraryW(L("uxtheme.dll")) orelse return;
    if (w.GetProcAddress(ux, @ptrFromInt(135))) |f| {
        const set: *const fn (i32) callconv(.winapi) i32 = @ptrCast(f);
        _ = set(1);
    }
    if (w.GetProcAddress(ux, @ptrFromInt(133))) |f| {
        const allow: *const fn (w.HWND, w.BOOL) callconv(.winapi) w.BOOL = @ptrCast(f);
        _ = allow(owner, w.TRUE);
    }
    if (w.GetProcAddress(ux, @ptrFromInt(136))) |f| {
        const flush: *const fn () callconv(.winapi) void = @ptrCast(f);
        flush();
    }
}

fn reveal(path: []const u8) void {
    var buf: [1100]u8 = undefined;
    const args = std.fmt.bufPrint(&buf, "/select,\"{s}\"", .{path}) catch return;
    var w16: [1100]u16 = undefined;
    _ = w.ShellExecuteW(null, L("open"), L("explorer.exe"), util.wideInto(&w16, args), null, w.SW_SHOWNORMAL);
}

fn openPath(path: []const u8) void {
    var w16: [1024]u16 = undefined;
    _ = w.ShellExecuteW(null, L("open"), util.wideInto(&w16, path), null, null, w.SW_SHOWNORMAL);
}

fn menuItem(m: w.HMENU, id: usize, text: []const u8, enabled: bool) void {
    var buf: [256]u16 = undefined;
    _ = w.AppendMenuW(m, if (enabled) w.MF_STRING else w.MF_GRAYED, id, util.wideInto(&buf, text));
}

fn trayMenu(x: i32, y: i32) void {
    const prev = w.GetForegroundWindow();
    const menu = w.CreatePopupMenu() orelse return;
    defer _ = w.DestroyMenu(menu); // also destroys the submenu
    const hk = w.CreatePopupMenu() orelse return;
    const recording = app.session != null;
    const enabled = app.request == null and app.capturing == null;
    var sb: [128]u8 = undefined;
    var tb: [16]u8 = undefined;
    const status = if (app.session) |s|
        std.fmt.bufPrint(&sb, "annotation-helper — Recording · {s} · {d} screenshot(s)", .{ util.fmtTime(&tb, @intCast(util.nowMs() - s.t0)), s.frames }) catch ""
    else
        "annotation-helper — Idle";
    var l0: [64]u8 = undefined;
    var l1: [64]u8 = undefined;
    const labels = [2][]const u8{ hotkeyLabel(0, &l0), hotkeyLabel(1, &l1) };
    var b: [256]u8 = undefined;
    menuItem(menu, 0, status, false);
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    menuItem(menu, ID_SESSION, std.fmt.bufPrint(&b, "{s}\t{s}", .{ if (recording) "&Stop recording" else "&Start recording", labels[0] }) catch "", enabled);
    menuItem(menu, ID_DRAW, std.fmt.bufPrint(&b, "{s}\t{s}", .{ if (app.draw != null) "&Finish screenshot" else "&Draw on screen", labels[1] }) catch "", enabled);
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    menuItem(menu, ID_SHOW_LAST, "Show &last brief", app.last_dir != null);
    menuItem(menu, ID_OPEN_SESSIONS, "&Open sessions folder", true);
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    menuItem(hk, ID_HK_SESSION, std.fmt.bufPrint(&b, "&{s}…\t{s}", .{ HOTKEY_NAMES[0], labels[0] }) catch "", enabled and !recording);
    menuItem(hk, ID_HK_DRAW, std.fmt.bufPrint(&b, "&{s}…\t{s}", .{ HOTKEY_NAMES[1], labels[1] }) catch "", enabled and !recording);
    _ = w.AppendMenuW(hk, w.MF_SEPARATOR, 0, null);
    menuItem(hk, ID_HK_RESET, "&Reset to defaults", enabled and !recording);
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(hk), L("&Hotkeys"));
    menuItem(menu, ID_CONFIG, "&Edit config.json", true);
    _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
    menuItem(menu, ID_QUIT, "&Quit", true);

    _ = w.SetForegroundWindow(app.tray_hwnd);
    const cmd: usize = @intCast(w.TrackPopupMenu(menu, .{ .RETURNCMD = 1, .NONOTIFY = 1, .RIGHTBUTTON = 1 }, x, y, 0, app.tray_hwnd, null));
    _ = w.PostMessageW(app.tray_hwnd, w.WM_NULL, 0, 0);
    if ((cmd == ID_SESSION or cmd == ID_DRAW) and prev != null) _ = w.SetForegroundWindow(prev); // focus back to the app being annotated
    switch (cmd) {
        ID_SESSION => onHotkey(HK_SESSION),
        ID_DRAW => onHotkey(HK_DRAW),
        ID_SHOW_LAST => if (app.last_dir) |d| {
            const p = util.join(util.gpa, &.{ d, "brief.md" }) catch return;
            defer util.gpa.free(p);
            reveal(p);
        },
        ID_OPEN_SESSIONS => openPath(app.opts.out_dir),
        ID_HK_SESSION => beginCapture(0),
        ID_HK_DRAW => beginCapture(1),
        ID_HK_RESET => resetHotkeys(),
        ID_CONFIG => {
            if (app.opts.config) |c| config.save(c) catch {};
            const p = config.path(util.gpa) catch return;
            defer util.gpa.free(p);
            var w16: [1024]u16 = undefined;
            _ = w.ShellExecuteW(null, L("open"), L("notepad.exe"), util.wideInto(&w16, p), null, w.SW_SHOWNORMAL);
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
    } else {
        balloon("Processing failed", done.text, true);
        util.gpa.free(done.text);
    }
}

fn quit() void {
    cancelRequest("the annotation server is shutting down");
    endCapture(null);
    stopSession(true, null);
    app.wk.shutdown();
    if (app.tray != null) Tray.remove();
    app.tray = null;
    w.PostQuitMessage(0);
}

// ------------------------------------------------------------------ window procs

fn lo(v: isize) i32 {
    return @as(i16, @truncate(v));
}
fn hi(v: isize) i32 {
    return @as(i16, @truncate(v >> 16));
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (!app_ready) return w.DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        w.WM_MOUSEACTIVATE => return w.MA_NOACTIVATE,
        w.WM_SETCURSOR => {
            _ = w.SetCursor(w.LoadCursorW(null, w.IDC_CROSS));
            return 1;
        },
        w.WM_HOTKEY => onHotkey(wp),
        WM_APP_KEY => if (app.draw != null) onKey(@intCast(wp), lp),
        WM_APP_QUIT, w.WM_CLOSE, w.WM_ENDSESSION => quit(),
        WM_APP_ANNOTATE => beginRequests(),
        WM_APP_CANCEL => cancelRequest("the agent cancelled the request"),
        WM_APP_CAPTURED => onCaptured(@intCast(wp), @intCast(lp)),
        worker.WM_APP_DONE => onDone(@ptrFromInt(@as(usize, @bitCast(lp)))),
        w.WM_TIMER => switch (wp) {
            TIMER_REQUEST => cancelRequest("timed out waiting for the user"),
            TIMER_CAPTURE => endCapture(null),
            TIMER_AUTODRAW => {
                _ = w.KillTimer(app.overlay, TIMER_AUTODRAW);
                scriptedStrokes();
                finishDraw();
            },
            else => {},
        },
        WM_APP_TRAY => {
            const event: u32 = @intCast(lp & 0xFFFF);
            if (event == w.WM_CONTEXTMENU or event == w.NIN_SELECT or event == w.NIN_SELECT + 1) {
                trayMenu(lo(@bitCast(wp)), hi(@bitCast(wp)));
            } else if (event == w.NIN_BALLOONUSERCLICK) if (app.last_dir) |d| {
                const p = util.join(util.gpa, &.{ d, "brief.md" }) catch return 0;
                defer util.gpa.free(p);
                reveal(p);
            };
            return 0;
        },
        w.WM_LBUTTONDOWN => if (app.draw) |d| beginStroke(.{ lo(lp) + d.virt.x, hi(lp) + d.virt.y }),
        w.WM_MOUSEMOVE => if (app.draw) |d| if (d.current != null) moveStroke(.{ lo(lp) + d.virt.x, hi(lp) + d.virt.y }),
        w.WM_LBUTTONUP => endStroke(),
        w.WM_RBUTTONUP => if (app.draw != null) finishDraw(),
        else => if (app.tray) |t| if (msg == t.taskbar_created) {
            var buf: [128]u8 = undefined;
            t.add(trayTip(&buf), app.session != null);
        },
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn isModifier(vk: u32) bool {
    return switch (vk) {
        0x10, 0x11, 0x12, 0x5B, 0x5C, 0xA0...0xA5 => true,
        else => false,
    };
}

fn keyDown(vk: u16) bool {
    return w.GetAsyncKeyState(vk) < 0;
}

/// Drawing: swallow plain keys (tool keys) so the app below keeps focus; Alt/Win combos
/// and global hotkeys pass. Capturing: report the first key combination and swallow it.
fn kbHook(code: i32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (code < 0) return w.CallNextHookEx(null, code, wp, lp);
    const k: *const w.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
    const down = wp == w.WM_KEYDOWN or wp == w.WM_SYSKEYDOWN;
    const vk = k.vkCode;
    const ctrl = keyDown(0x11);
    const alt = keyDown(0x12);
    const shift = keyDown(0x10);
    const win = keyDown(0x5B) or keyDown(0x5C);
    if (hook_mode.load(.acquire) == HOOK_CAPTURE) {
        // 0xE8 is our own dummy key (below); other injected input counts.
        if (isModifier(vk) or vk == 0xE8) return w.CallNextHookEx(null, code, wp, lp);
        if (down) {
            var mods: u32 = 0;
            if (ctrl) mods |= config.MOD_CONTROL;
            if (alt) mods |= config.MOD_ALT;
            if (shift) mods |= config.MOD_SHIFT;
            if (win) {
                mods |= config.MOD_WIN;
                // We swallow the key, so Windows would see a lone Win press and open Start.
                var inputs = [2]w.INPUT{ dummyKey(false), dummyKey(true) };
                _ = w.SendInput(2, &inputs, @sizeOf(w.INPUT));
            }
            _ = w.PostMessageW(app.overlay, WM_APP_CAPTURED, vk, @intCast(mods));
        }
        return 1;
    }
    if (down and !isModifier(vk) and !alt and !win) {
        const flags: isize = (if (ctrl) KEY_CTRL else 0) | (if (shift) KEY_SHIFT else 0);
        _ = w.PostMessageW(app.overlay, WM_APP_KEY, vk, flags);
        return 1;
    }
    return w.CallNextHookEx(null, code, wp, lp);
}

fn dummyKey(up: bool) w.INPUT {
    var i = std.mem.zeroes(w.INPUT);
    i.type = w.INPUT_KEYBOARD;
    // 0xE8 is unassigned, so VIRTUAL_KEY (an exhaustive enum) has no tag for it.
    @as(*u16, @ptrCast(&i.Anonymous.ki.wVk)).* = 0xE8;
    if (up) i.Anonymous.ki.dwFlags = .{ .KEYUP = 1 };
    return i;
}

fn ctrlHandler(kind: u32) callconv(.winapi) w.BOOL {
    _ = w.PostMessageW(app.overlay, WM_APP_QUIT, 0, 0);
    if (kind == 2) w.Sleep(5000); // CTRL_CLOSE_EVENT: Windows kills us when this returns
    return w.TRUE;
}

// ------------------------------------------------------------------ setup & entry points

fn createWindow(ex: w.WINDOW_EX_STYLE, title: [*:0]const u16) !w.HWND {
    return w.CreateWindowExW(ex, L("AnnotationHelperZig"), title, w.WS_POPUP, 0, 0, 1, 1, null, null, w.GetModuleHandleW(null), null) orelse error.CreateWindow;
}

fn init(opts: Options) !void {
    _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    var wc = std.mem.zeroes(w.WNDCLASSEXW);
    wc.cbSize = @sizeOf(w.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = w.GetModuleHandleW(null);
    wc.lpszClassName = L("AnnotationHelperZig");
    _ = w.RegisterClassExW(&wc);
    const ex = w.WINDOW_EX_STYLE{ .LAYERED = 1, .TOPMOST = 1, .TOOLWINDOW = 1, .NOACTIVATE = 1 };
    var ex_t = ex;
    ex_t.TRANSPARENT = 1;
    app = .{
        .opts = opts,
        .overlay = try createWindow(ex, L("annotation-helper overlay")),
        .indicator = try createWindow(ex_t, L("annotation-helper status")),
        .banner = try createWindow(ex_t, L("annotation-helper request")),
        // Plain hidden window owning the tray icon (menus need an activatable owner).
        .tray_hwnd = try createWindow(.{ .TOOLWINDOW = 1 }, L("annotation-helper")),
        .wk = try worker.Worker.spawn(),
    };
    // Keep status pill and request banner out of our own (and anyone's) screenshots.
    _ = w.SetWindowDisplayAffinity(app.indicator, w.WDA_EXCLUDEFROMCAPTURE);
    _ = w.SetWindowDisplayAffinity(app.banner, w.WDA_EXCLUDEFROMCAPTURE);
    try util.mkdirAll(opts.out_dir);
    _ = w.SetConsoleCtrlHandler(ctrlHandler, w.TRUE);
    app_ready = true;
}

fn messageLoop() void {
    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

/// Interactive tray app.
pub fn run(opts: Options) !void {
    // One tray instance per user (the mutex is held for the life of the process).
    _ = w.CreateMutexW(null, w.TRUE, L("Local\\annotation-helper-tray"));
    if (w.GetLastError() == w.ERROR_ALREADY_EXISTS) {
        _ = w.MessageBoxW(null, L("annotation-helper is already running — look for its icon in the notification area."), L("annotation-helper"), w.MB_ICONINFORMATION);
        return;
    }
    const cfg = opts.config orelse config.Config{};
    const cfg_path = try config.path(util.gpa);
    defer util.gpa.free(cfg_path);
    if (!util.exists(cfg_path)) config.save(cfg) catch {};
    try init(opts);
    allowDarkMenus(app.tray_hwnd);

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
    np += registerHotkeys(problems[np..]).len;

    const size = std.math.clamp(w.GetSystemMetrics(w.SM_CXSMICON), 16, 64);
    app.tray = .{ .idle = makeIcon(size, false), .recording = makeIcon(size, true), .taskbar_created = w.RegisterWindowMessageW(L("TaskbarCreated")) };
    var tb: [128]u8 = undefined;
    app.tray.?.add(trayTip(&tb), false);
    var l0: [64]u8 = undefined;
    var l1: [64]u8 = undefined;
    util.log("  {s}  start/stop recording\r\n  {s}  draw / finish screenshot", .{ hotkeyLabel(0, &l0), hotkeyLabel(1, &l1) });
    util.log("Sessions go to {s}\r\nRight-click the tray icon for options.", .{opts.out_dir});
    if (np == 0) {
        var mb: [256]u8 = undefined;
        balloon("annotation-helper is running", std.fmt.bufPrint(&mb, "{s} draw on screen · {s} start/stop recording. Right-click the tray icon for options.", .{ hotkeyLabel(1, &l1), hotkeyLabel(0, &l0) }) catch "", false);
    } else {
        var mb: [800]u8 = undefined;
        balloon("Hotkey problem", std.fmt.bufPrint(&mb, "{s}Change it via the tray menu → Hotkeys.", .{problems[0..np]}) catch "", true);
    }
    messageLoop();
}

/// MCP server mode: protocol on another thread, UI here; no hotkeys, no tray.
pub fn runMcp(opts: Options, serve: *const fn () void) !void {
    try init(opts);
    const t = try std.Thread.spawn(util.thread_cfg, struct {
        fn go(f: *const fn () void) void {
            f();
            _ = w.PostMessageW(app.overlay, WM_APP_QUIT, 0, 0); // stdin closed: the client is gone
        }
    }.go, .{serve});
    t.detach();
    messageLoop();
}

/// Non-interactive end-to-end check: a session with one scripted screenshot.
pub fn selftest(opts: Options) !void {
    try init(opts);
    const pump = struct {
        fn f(ms: u64) void {
            const until = util.nowMs() + ms;
            var msg: w.MSG = undefined;
            while (util.nowMs() < until) {
                while (w.PeekMessageW(&msg, null, 0, 0, .{ .REMOVE = 1 }) != 0) {
                    _ = w.TranslateMessage(&msg);
                    _ = w.DispatchMessageW(&msg);
                }
                w.Sleep(10);
            }
        }
    }.f;
    try startDraw();
    scriptedStrokes();
    pump(1200);
    finishDraw();
    pump(200);
    quit();
}
