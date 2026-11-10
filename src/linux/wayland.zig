//! Minimal Wayland client speaking the wire protocol directly (no libwayland):
//! outputs with their logical layout, one full-screen xdg_toplevel per output showing
//! a region of the frozen screenshot (wl_shm, double-buffered with damage tracking,
//! scaled with wp_viewporter), pointer and keyboard input, and a crosshair cursor.

const std = @import("std");
const sys = @import("sys.zig");
const xkb = @import("xkb.zig");
const keys = @import("keys.zig");
const model = @import("../model.zig");
const raster = @import("../raster.zig");
const util = @import("../util.zig");

const Allocator = std.mem.Allocator;
const Rect = model.Rect;
const Bgra = raster.Bgra;

pub const Event = union(enum) {
    key: struct { keysym: u32, mods: keys.Mods },
    button: struct { x: i32, y: i32, button: u8, down: bool },
    motion: struct { x: i32, y: i32 },
    closed,
};

const Kind = enum(u8) {
    none,
    display,
    registry,
    sync_cb,
    frame_cb,
    compositor,
    shm,
    pool,
    buffer,
    surface,
    seat,
    pointer,
    keyboard,
    output,
    xdg_output_mgr,
    xdg_output,
    wm_base,
    xdg_surface,
    toplevel,
    viewporter,
    viewport,
    cursor_shape_mgr,
    cursor_shape_dev,
    activation,
    other,
};

const Obj = struct { kind: Kind = .none, idx: u16 = 0 };

const Output = struct {
    id: u32,
    global: u32,
    xdg: u32 = 0,
    gx: i32 = 0,
    gy: i32 = 0,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    scale: i32 = 1,
    lx: i32 = 0,
    ly: i32 = 0,
    lw: i32 = 0,
    lh: i32 = 0,
    has_logical: bool = false,

    fn logical(o: Output) Rect {
        if (o.has_logical and o.lw > 0) return .{ .x = o.lx, .y = o.ly, .w = o.lw, .h = o.lh };
        const s = @max(o.scale, 1);
        return .{ .x = o.gx, .y = o.gy, .w = @divTrunc(o.mode_w, s), .h = @divTrunc(o.mode_h, s) };
    }
};

const Buffer = struct { id: u32 = 0, busy: bool = false, damage: ?Rect = null };

const Win = struct {
    output: usize,
    surface: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    viewport: u32 = 0,
    configured: bool = false,
    conf_w: i32 = 0,
    conf_h: i32 = 0,
    /// The part of the image (image pixels) this window shows.
    region: Rect,
    pool: u32 = 0,
    shm: ?sys.Shm = null,
    buffers: [2]Buffer = .{ .{}, .{} },
    frame_cb: u32 = 0,
    pending: ?Rect = null,
    shown: bool = false,
};

pub const Wl = struct {
    a: Allocator,
    fd: sys.fd_t,
    rbuf: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(sys.fd_t) = .empty,
    objs: std.ArrayList(Obj) = .empty,
    free_ids: std.ArrayList(u32) = .empty,
    broken: bool = false,
    sync_done: u32 = 0,

    compositor: u32 = 0,
    shm: u32 = 0,
    seat: u32 = 0,
    pointer: u32 = 0,
    keyboard: u32 = 0,
    wm_base: u32 = 0,
    xdg_output_mgr: u32 = 0,
    viewporter: u32 = 0,
    cursor_shape_mgr: u32 = 0,
    cursor_shape_dev: u32 = 0,
    activation: u32 = 0,
    outputs: std.ArrayList(Output) = .empty,
    kb: xkb.Keyboard = .{},

    wins: std.ArrayList(Win) = .empty,
    /// Image → logical scale (image pixels per logical pixel) and image origin in logical coords.
    ratio: f64 = 1,
    origin: [2]i32 = .{ 0, 0 },
    canvas: []const Bgra = &.{},
    canvas_w: i32 = 0,
    pointer_win: ?usize = null,
    cursor_surface: u32 = 0,
    events: std.ArrayList(Event) = .empty,
    activation_token: ?[]u8 = null,

    pub fn connect(a: Allocator) !*Wl {
        const name = sys.env("WAYLAND_DISPLAY") orelse return error.NoWayland;
        var buf: [512]u8 = undefined;
        const path = if (name[0] == '/') name else std.fmt.bufPrint(&buf, "{s}/{s}", .{ sys.env("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir, name }) catch return error.NameTooLong;
        const fd = try sys.connectUnix(path, false);
        const wl = try a.create(Wl);
        wl.* = .{ .a = a, .fd = fd };
        errdefer wl.close();
        try wl.objs.append(a, .{}); // id 0 = null
        try wl.objs.append(a, .{ .kind = .display });
        const reg = wl.newId(.registry, 0);
        var m = Msg.init();
        m.u(reg);
        try wl.sendMsg(1, 1, &m, null);
        try wl.roundtrip();
        try wl.roundtrip(); // outputs' and seat's initial events
        if (wl.compositor == 0 or wl.shm == 0 or wl.wm_base == 0) return error.MissingGlobals;
        if (sys.env("XDG_ACTIVATION_TOKEN")) |t| wl.activation_token = a.dupe(u8, t) catch null;
        return wl;
    }

    pub fn close(wl: *Wl) void {
        wl.hide();
        _ = sys.close(wl.fd);
        for (wl.fds.items) |f| _ = sys.close(f);
        wl.fds.deinit(wl.a);
        wl.rbuf.deinit(wl.a);
        wl.objs.deinit(wl.a);
        wl.free_ids.deinit(wl.a);
        wl.outputs.deinit(wl.a);
        wl.wins.deinit(wl.a);
        wl.events.deinit(wl.a);
        if (wl.activation_token) |t| wl.a.free(t);
        wl.a.destroy(wl);
    }

    fn newId(wl: *Wl, kind: Kind, idx: usize) u32 {
        if (wl.free_ids.pop()) |id| {
            wl.objs.items[id] = .{ .kind = kind, .idx = @intCast(idx) };
            return id;
        }
        wl.objs.append(wl.a, .{ .kind = kind, .idx = @intCast(idx) }) catch {};
        return @intCast(wl.objs.items.len - 1);
    }

    /// Marks an object we destroyed; the id returns once the server confirms (delete_id).
    fn forget(wl: *Wl, id: u32) void {
        if (id < wl.objs.items.len) wl.objs.items[id] = .{ .kind = .other };
    }

    fn sendMsg(wl: *Wl, obj: u32, opcode: u16, m: *Msg, fd: ?sys.fd_t) !void {
        const size: u32 = @intCast(m.n);
        std.mem.writeInt(u32, m.b[0..4], obj, .little);
        std.mem.writeInt(u32, m.b[4..8], (size << 16) | opcode, .little);
        if (fd) |f| try sys.sendWithFds(wl.fd, m.b[0..m.n], &.{f}) else try sys.writeAll(wl.fd, m.b[0..m.n]);
    }

    fn req(wl: *Wl, obj: u32, opcode: u16, m: *Msg) void {
        wl.sendMsg(obj, opcode, m, null) catch {
            wl.broken = true;
        };
    }

    pub fn roundtrip(wl: *Wl) !void {
        const cb = wl.newId(.sync_cb, 0);
        var m = Msg.init();
        m.u(cb);
        try wl.sendMsg(1, 0, &m, null);
        while (wl.sync_done != cb) {
            if (wl.broken) return error.ProtocolError;
            if (!sys.waitReadable(wl.fd, 5000)) return error.Timeout;
            try wl.dispatch();
        }
        wl.sync_done = 0;
    }

    /// Reads what is available and handles the events.
    pub fn dispatch(wl: *Wl) !void {
        var chunk: [32768]u8 = undefined;
        const n = sys.recvWithFds(wl.fd, &chunk, &wl.fds, wl.a) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return error.Disconnected,
        };
        if (n == 0) return error.Disconnected;
        try wl.rbuf.appendSlice(wl.a, chunk[0..n]);
        while (wl.rbuf.items.len >= 8) {
            const obj = std.mem.readInt(u32, wl.rbuf.items[0..4], .little);
            const w2 = std.mem.readInt(u32, wl.rbuf.items[4..8], .little);
            const size: usize = w2 >> 16;
            const op: u16 = @truncate(w2);
            if (size < 8 or wl.rbuf.items.len < size) break;
            const body = try wl.a.dupe(u8, wl.rbuf.items[8..size]);
            defer wl.a.free(body);
            wl.rbuf.replaceRange(wl.a, 0, size, &.{}) catch unreachable;
            wl.handle(obj, op, body);
        }
    }

    pub fn nextEvent(wl: *Wl) ?Event {
        if (wl.events.items.len == 0) return null;
        return wl.events.orderedRemove(0);
    }

    fn takeFd(wl: *Wl) ?sys.fd_t {
        if (wl.fds.items.len == 0) return null;
        return wl.fds.orderedRemove(0);
    }

    fn handle(wl: *Wl, obj: u32, op: u16, body: []const u8) void {
        var r = Rd{ .b = body };
        const o: Obj = if (obj < wl.objs.items.len) wl.objs.items[obj] else .{ .kind = .other };
        switch (o.kind) {
            .display => switch (op) {
                0 => {
                    const target = r.u();
                    const code = r.u();
                    util.log("  wayland error on object {d} (code {d}): {s}", .{ target, code, r.s() });
                    wl.broken = true;
                },
                1 => {
                    const id = r.u();
                    if (id < wl.objs.items.len and wl.objs.items[id].kind != .none) {
                        wl.objs.items[id] = .{};
                        wl.free_ids.append(wl.a, id) catch {};
                    }
                },
                else => {},
            },
            .registry => if (op == 0) wl.onGlobal(r.u(), r.s(), r.u()),
            // The id comes back with the server's delete_id that follows.
            .sync_cb => wl.sync_done = obj,
            .frame_cb => {
                if (o.idx < wl.wins.items.len and wl.wins.items[o.idx].frame_cb == obj) {
                    wl.wins.items[o.idx].frame_cb = 0;
                    wl.flush(o.idx);
                }
            },
            .buffer => if (op == 0) {
                const wi = o.idx / 2;
                if (wi < wl.wins.items.len) {
                    wl.wins.items[wi].buffers[o.idx % 2].busy = false;
                    wl.flush(wi);
                }
            },
            .seat => if (op == 0) {
                const caps = r.u();
                if (caps & 1 != 0 and wl.pointer == 0) {
                    wl.pointer = wl.newId(.pointer, 0);
                    var m = Msg.init();
                    m.u(wl.pointer);
                    wl.req(wl.seat, 0, &m);
                }
                if (caps & 2 != 0 and wl.keyboard == 0) {
                    wl.keyboard = wl.newId(.keyboard, 0);
                    var m = Msg.init();
                    m.u(wl.keyboard);
                    wl.req(wl.seat, 1, &m);
                }
            },
            .pointer => wl.onPointer(op, &r),
            .keyboard => wl.onKeyboard(op, &r),
            .output => {
                const out = &wl.outputs.items[o.idx];
                switch (op) {
                    0 => {
                        out.gx = r.i();
                        out.gy = r.i();
                    },
                    1 => {
                        const flags = r.u();
                        const mw = r.i();
                        const mh = r.i();
                        if (flags & 1 != 0) {
                            out.mode_w = mw;
                            out.mode_h = mh;
                        }
                    },
                    3 => out.scale = r.i(),
                    else => {},
                }
            },
            .xdg_output => {
                const out = &wl.outputs.items[o.idx];
                switch (op) {
                    0 => {
                        out.lx = r.i();
                        out.ly = r.i();
                    },
                    1 => {
                        out.lw = r.i();
                        out.lh = r.i();
                        out.has_logical = true;
                    },
                    else => {},
                }
            },
            .wm_base => if (op == 0) {
                var m = Msg.init();
                m.u(r.u());
                wl.req(wl.wm_base, 3, &m);
            },
            .xdg_surface => if (op == 0) {
                var m = Msg.init();
                m.u(r.u());
                wl.req(obj, 4, &m);
                if (o.idx < wl.wins.items.len) wl.wins.items[o.idx].configured = true;
            },
            .toplevel => switch (op) {
                0 => if (o.idx < wl.wins.items.len) {
                    const cw = r.i();
                    const ch = r.i();
                    if (cw > 0 and ch > 0) {
                        wl.wins.items[o.idx].conf_w = cw;
                        wl.wins.items[o.idx].conf_h = ch;
                    }
                },
                1 => wl.events.append(wl.a, .closed) catch {},
                else => {},
            },
            else => {},
        }
    }

    fn onGlobal(wl: *Wl, name: u32, iface: []const u8, version: u32) void {
        const Bind = struct { iface: []const u8, kind: Kind, max: u32 };
        const wanted = [_]Bind{
            .{ .iface = "wl_compositor", .kind = .compositor, .max = 4 },
            .{ .iface = "wl_shm", .kind = .shm, .max = 1 },
            .{ .iface = "wl_seat", .kind = .seat, .max = 5 },
            .{ .iface = "wl_output", .kind = .output, .max = 3 },
            .{ .iface = "xdg_wm_base", .kind = .wm_base, .max = 2 },
            .{ .iface = "zxdg_output_manager_v1", .kind = .xdg_output_mgr, .max = 3 },
            .{ .iface = "wp_viewporter", .kind = .viewporter, .max = 1 },
            .{ .iface = "wp_cursor_shape_manager_v1", .kind = .cursor_shape_mgr, .max = 1 },
            .{ .iface = "xdg_activation_v1", .kind = .activation, .max = 1 },
        };
        for (wanted) |b| if (std.mem.eql(u8, iface, b.iface)) {
            if (b.kind == .compositor and version < 4) return;
            if (b.kind == .seat and wl.seat != 0) return;
            const idx = if (b.kind == .output) wl.outputs.items.len else 0;
            const id = wl.newId(b.kind, idx);
            var m = Msg.init();
            m.u(name);
            m.s(iface);
            m.u(@min(version, b.max));
            m.u(id);
            wl.req(2, 0, &m);
            switch (b.kind) {
                .compositor => wl.compositor = id,
                .shm => wl.shm = id,
                .seat => wl.seat = id,
                .wm_base => wl.wm_base = id,
                .viewporter => wl.viewporter = id,
                .cursor_shape_mgr => wl.cursor_shape_mgr = id,
                .activation => wl.activation = id,
                .xdg_output_mgr => {
                    wl.xdg_output_mgr = id;
                    for (wl.outputs.items, 0..) |*out, i| wl.bindXdgOutput(out, i);
                },
                .output => {
                    wl.outputs.append(wl.a, .{ .id = id, .global = name }) catch return;
                    if (wl.xdg_output_mgr != 0) wl.bindXdgOutput(&wl.outputs.items[idx], idx);
                },
                else => {},
            }
            return;
        };
    }

    fn bindXdgOutput(wl: *Wl, out: *Output, idx: usize) void {
        if (out.xdg != 0) return;
        out.xdg = wl.newId(.xdg_output, idx);
        var m = Msg.init();
        m.u(out.xdg);
        m.u(out.id);
        wl.req(wl.xdg_output_mgr, 1, &m);
    }

    fn surfaceWin(wl: *Wl, surface: u32) ?usize {
        for (wl.wins.items, 0..) |w, i| if (w.surface == surface) return i;
        return null;
    }

    fn toImage(wl: *Wl, wi: usize, sx: i32, sy: i32) [2]i32 {
        const w = wl.wins.items[wi];
        const lw: f64 = @floatFromInt(if (w.conf_w > 0) w.conf_w else w.region.w);
        const lh: f64 = @floatFromInt(if (w.conf_h > 0) w.conf_h else w.region.h);
        const fx = @as(f64, @floatFromInt(sx)) / 256.0 * @as(f64, @floatFromInt(w.region.w)) / lw;
        const fy = @as(f64, @floatFromInt(sy)) / 256.0 * @as(f64, @floatFromInt(w.region.h)) / lh;
        return .{ w.region.x + @as(i32, @intFromFloat(@round(fx))), w.region.y + @as(i32, @intFromFloat(@round(fy))) };
    }

    var last_pos: [2]i32 = .{ 0, 0 };

    fn onPointer(wl: *Wl, op: u16, r: *Rd) void {
        switch (op) {
            0 => { // enter
                const serial = r.u();
                const surface = r.u();
                const sx = r.i();
                const sy = r.i();
                wl.pointer_win = wl.surfaceWin(surface);
                wl.setCursor(serial);
                if (wl.pointer_win) |wi| {
                    last_pos = wl.toImage(wi, sx, sy);
                    wl.events.append(wl.a, .{ .motion = .{ .x = last_pos[0], .y = last_pos[1] } }) catch {};
                }
            },
            1 => wl.pointer_win = null,
            2 => {
                _ = r.u();
                const sx = r.i();
                const sy = r.i();
                if (wl.pointer_win) |wi| {
                    last_pos = wl.toImage(wi, sx, sy);
                    wl.events.append(wl.a, .{ .motion = .{ .x = last_pos[0], .y = last_pos[1] } }) catch {};
                }
            },
            3 => {
                _ = r.u();
                _ = r.u();
                const button = r.u();
                const state = r.u();
                const b: u8 = switch (button) {
                    0x110 => 1,
                    0x111 => 3,
                    0x112 => 2,
                    else => 0,
                };
                if (b != 0 and wl.pointer_win != null) wl.events.append(wl.a, .{ .button = .{ .x = last_pos[0], .y = last_pos[1], .button = b, .down = state == 1 } }) catch {};
            },
            else => {},
        }
    }

    fn onKeyboard(wl: *Wl, op: u16, r: *Rd) void {
        switch (op) {
            0 => { // keymap
                const format = r.u();
                const size = r.u();
                const fd = wl.takeFd() orelse return;
                defer _ = sys.close(fd);
                if (format != 1 or size == 0) return;
                const p = sys.mmap(null, size, sys.PROT_READ, sys.MAP_PRIVATE, fd, 0) orelse return;
                if (@intFromPtr(p) == std.math.maxInt(usize)) return;
                defer _ = sys.munmap(p, size);
                const bytes: [*]const u8 = @ptrCast(p);
                const text = wl.a.dupeSentinel(u8, std.mem.sliceTo(bytes[0..size], 0), 0) catch return;
                defer wl.a.free(text);
                wl.kb.setKeymap(text);
            },
            3 => { // key
                _ = r.u();
                _ = r.u();
                const key = r.u();
                const state = r.u();
                if (state != 1) return;
                const ks = wl.kb.keysym(key);
                if (ks != 0) wl.events.append(wl.a, .{ .key = .{ .keysym = ks, .mods = wl.kb.mods() } }) catch {};
            },
            4 => {
                _ = r.u();
                const dep = r.u();
                const lat = r.u();
                const loc = r.u();
                wl.kb.updateMods(dep, lat, loc, r.u());
            },
            else => {},
        }
    }

    fn setCursor(wl: *Wl, serial: u32) void {
        if (wl.pointer == 0) return;
        if (wl.cursor_shape_mgr != 0) {
            if (wl.cursor_shape_dev == 0) {
                wl.cursor_shape_dev = wl.newId(.cursor_shape_dev, 0);
                var m = Msg.init();
                m.u(wl.cursor_shape_dev);
                m.u(wl.pointer);
                wl.req(wl.cursor_shape_mgr, 1, &m);
            }
            var m = Msg.init();
            m.u(serial);
            m.u(8); // crosshair
            wl.req(wl.cursor_shape_dev, 1, &m);
            return;
        }
        if (wl.cursor_surface == 0) wl.makeCursor() catch return;
        var m = Msg.init();
        m.u(serial);
        m.u(wl.cursor_surface);
        m.i(11);
        m.i(11);
        wl.req(wl.pointer, 0, &m);
    }

    /// A 23×23 crosshair (white with a dark outline) for compositors without cursor-shape.
    fn makeCursor(wl: *Wl) !void {
        const size = 23;
        var shm = try sys.Shm.create(size * size * 4);
        defer shm.deinit();
        const px: []Bgra = @as([*]Bgra, @ptrCast(shm.mem.ptr))[0 .. size * size];
        for (px, 0..) |*p, i| {
            const x: i32 = @intCast(i % size);
            const y: i32 = @intCast(i / size);
            const dx = @abs(x - 11);
            const dy = @abs(y - 11);
            const core = (dx == 0 and dy <= 10 and dy >= 2) or (dy == 0 and dx <= 10 and dx >= 2);
            const edge = (dx <= 1 and dy <= 11 and dy >= 1) or (dy <= 1 and dx <= 11 and dx >= 1);
            p.* = if (core) .{ .b = 255, .g = 255, .r = 255, .a = 255 } else if (edge) .{ .b = 0, .g = 0, .r = 0, .a = 200 } else .{ .b = 0, .g = 0, .r = 0, .a = 0 };
        }
        const pool = wl.newId(.pool, 0);
        var m = Msg.init();
        m.u(pool);
        m.i(@intCast(shm.mem.len));
        try wl.sendMsg(wl.shm, 0, &m, shm.fd);
        const buf = wl.newId(.other, 0);
        var b = Msg.init();
        b.u(buf);
        b.i(0);
        b.i(size);
        b.i(size);
        b.i(size * 4);
        b.u(0); // ARGB8888
        wl.req(pool, 0, &b);
        var d = Msg.init();
        wl.req(pool, 1, &d);
        wl.cursor_surface = wl.newId(.surface, 0xffff);
        var s = Msg.init();
        s.u(wl.cursor_surface);
        wl.req(wl.compositor, 0, &s);
        var at = Msg.init();
        at.u(buf);
        at.i(0);
        at.i(0);
        wl.req(wl.cursor_surface, 1, &at);
        var c = Msg.init();
        wl.req(wl.cursor_surface, 6, &c);
    }

    // ------------------------------------------------------------------ layout

    fn logicalBounds(wl: *Wl) Rect {
        var r = Rect{};
        for (wl.outputs.items) |o| r = r.unite(o.logical());
        return r;
    }

    /// Image pixels per logical pixel when no screenshot fixes it (largest output scale).
    fn nativeRatio(wl: *Wl) f64 {
        var best: f64 = 1;
        for (wl.outputs.items) |o| {
            const l = o.logical();
            if (l.w > 0 and o.mode_w > 0) best = @max(best, @as(f64, @floatFromInt(o.mode_w)) / @as(f64, @floatFromInt(l.w)));
        }
        return best;
    }

    /// Fixes the mapping from logical coordinates to an image of `img_w` pixels width.
    pub fn setImageWidth(wl: *Wl, img_w: i32) void {
        const b = wl.logicalBounds();
        wl.origin = .{ b.x, b.y };
        wl.ratio = if (b.w > 0) @as(f64, @floatFromInt(img_w)) / @as(f64, @floatFromInt(b.w)) else 1;
    }

    fn toImageRect(wl: *Wl, l: Rect) Rect {
        const f = wl.ratio;
        const x0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(l.x - wl.origin[0])) * f));
        const y0: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(l.y - wl.origin[1])) * f));
        const x1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(l.right() - wl.origin[0])) * f));
        const y1: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(l.bottom() - wl.origin[1])) * f));
        return Rect.ltrb(x0, y0, x1, y1);
    }

    pub const MonitorList = struct { items: [16]model.Monitor = undefined, n: usize = 0 };

    /// Monitors in image coordinates (before a screenshot: at the native scale).
    pub fn monitors(wl: *Wl) MonitorList {
        if (wl.wins.items.len == 0) {
            const b = wl.logicalBounds();
            wl.origin = .{ b.x, b.y };
            wl.ratio = wl.nativeRatio();
        }
        var list = MonitorList{};
        for (wl.outputs.items, 0..) |o, i| {
            if (list.n == list.items.len) break;
            list.items[list.n] = .{ .rect = wl.toImageRect(o.logical()), .primary = i == 0 };
            list.n += 1;
        }
        return list;
    }

    // ------------------------------------------------------------------ windows

    /// One full-screen window per output, showing `canvas` (image of `width` pixels per row).
    pub fn show(wl: *Wl, canvas: []const Bgra, width: i32, height: i32) !void {
        wl.hide();
        wl.setImageWidth(width);
        wl.canvas = canvas;
        wl.canvas_w = width;
        const img = Rect{ .w = width, .h = height };
        for (wl.outputs.items, 0..) |o, i| {
            const region = (wl.toImageRect(o.logical())).intersect(img) orelse continue;
            try wl.wins.append(wl.a, .{ .output = i, .region = region });
        }
        if (wl.wins.items.len == 0) return error.NoOutputs;
        for (wl.wins.items, 0..) |*w, i| {
            w.surface = wl.newId(.surface, i);
            var m = Msg.init();
            m.u(w.surface);
            wl.req(wl.compositor, 0, &m);
            if (wl.viewporter != 0) {
                w.viewport = wl.newId(.viewport, i);
                var v = Msg.init();
                v.u(w.viewport);
                v.u(w.surface);
                wl.req(wl.viewporter, 1, &v);
            }
            w.xdg_surface = wl.newId(.xdg_surface, i);
            var xs = Msg.init();
            xs.u(w.xdg_surface);
            xs.u(w.surface);
            wl.req(wl.wm_base, 2, &xs);
            w.toplevel = wl.newId(.toplevel, i);
            var t = Msg.init();
            t.u(w.toplevel);
            wl.req(w.xdg_surface, 1, &t);
            var title = Msg.init();
            title.s("annotation-helper");
            wl.req(w.toplevel, 2, &title);
            var app_id = Msg.init();
            app_id.s("annotation-helper");
            wl.req(w.toplevel, 3, &app_id);
            var fs = Msg.init();
            fs.u(wl.outputs.items[w.output].id);
            wl.req(w.toplevel, 11, &fs);
            var c = Msg.init();
            wl.req(w.surface, 6, &c);
        }
        // Wait for the first configure of every window.
        const deadline = util.nowMs() + 3000;
        while (util.nowMs() < deadline) {
            var all = true;
            for (wl.wins.items) |w| all = all and w.configured;
            if (all) break;
            try wl.roundtrip();
        }
        for (wl.wins.items, 0..) |*w, i| {
            const stride: usize = @intCast(w.region.w * 4);
            const one = stride * @as(usize, @intCast(w.region.h));
            w.shm = try sys.Shm.create(one * 2);
            w.pool = wl.newId(.pool, i);
            var m = Msg.init();
            m.u(w.pool);
            m.i(@intCast(one * 2));
            try wl.sendMsg(wl.shm, 0, &m, w.shm.?.fd);
            for (&w.buffers, 0..) |*b, j| {
                b.* = .{ .id = wl.newId(.buffer, i * 2 + j), .damage = .{ .w = w.region.w, .h = w.region.h } };
                var bm = Msg.init();
                bm.u(b.id);
                bm.i(@intCast(one * j));
                bm.i(w.region.w);
                bm.i(w.region.h);
                bm.i(@intCast(stride));
                bm.u(1); // XRGB8888
                wl.req(w.pool, 0, &bm);
            }
            if (w.viewport != 0) {
                const o = wl.outputs.items[w.output].logical();
                var d = Msg.init();
                d.i(if (w.conf_w > 0) w.conf_w else o.w);
                d.i(if (w.conf_h > 0) w.conf_h else o.h);
                wl.req(w.viewport, 2, &d);
            } else {
                const s: i32 = @intFromFloat(@round(wl.ratio));
                if (s > 1) {
                    var bs = Msg.init();
                    bs.i(s);
                    wl.req(w.surface, 8, &bs);
                }
            }
            w.pending = w.region;
            w.shown = true;
            wl.flush(i);
            if (wl.activation != 0) if (wl.activation_token) |tok| {
                var am = Msg.init();
                am.s(tok);
                am.u(w.surface);
                wl.req(wl.activation, 2, &am);
            };
        }
        if (wl.activation_token) |t| {
            wl.a.free(t);
            wl.activation_token = null;
        }
        try wl.roundtrip();
        if (wl.broken) return error.ProtocolError;
    }

    pub fn setActivationToken(wl: *Wl, token: []const u8) void {
        if (wl.activation_token) |t| wl.a.free(t);
        wl.activation_token = wl.a.dupe(u8, token) catch null;
    }

    /// Queues `dirty` (image coordinates) for presenting.
    pub fn present(wl: *Wl, dirty: Rect) void {
        for (wl.wins.items, 0..) |*w, i| {
            const d = dirty.intersect(w.region) orelse continue;
            w.pending = if (w.pending) |p| p.unite(d) else d;
            wl.flush(i);
        }
    }

    fn flush(wl: *Wl, wi: usize) void {
        const w = &wl.wins.items[wi];
        if (!w.shown or w.frame_cb != 0) return;
        const pending = w.pending orelse return;
        const bi: usize = if (!w.buffers[0].busy) 0 else if (!w.buffers[1].busy) 1 else return;
        const b = &w.buffers[bi];
        const area = (if (b.damage) |d| d.offset(w.region.x, w.region.y).unite(pending) else pending).intersect(w.region) orelse return;
        const shm = w.shm orelse return;
        const one: usize = @intCast(w.region.w * w.region.h);
        const dst: []Bgra = @as([*]Bgra, @ptrCast(shm.mem.ptr))[one * bi ..][0..one];
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            const src_off: usize = @intCast(y * wl.canvas_w + area.x);
            const dst_off: usize = @intCast((y - w.region.y) * w.region.w + (area.x - w.region.x));
            @memcpy(dst[dst_off..][0..@intCast(area.w)], wl.canvas[src_off..][0..@intCast(area.w)]);
        }
        b.damage = null;
        const local = pending.offset(-w.region.x, -w.region.y);
        const other = &w.buffers[1 - bi];
        other.damage = if (other.damage) |d| d.unite(local) else local;
        w.pending = null;
        var at = Msg.init();
        at.u(b.id);
        at.i(0);
        at.i(0);
        wl.req(w.surface, 1, &at);
        var dm = Msg.init();
        dm.i(local.x);
        dm.i(local.y);
        dm.i(local.w);
        dm.i(local.h);
        wl.req(w.surface, 9, &dm);
        w.frame_cb = wl.newId(.frame_cb, wi);
        var fm = Msg.init();
        fm.u(w.frame_cb);
        wl.req(w.surface, 3, &fm);
        var c = Msg.init();
        wl.req(w.surface, 6, &c);
        b.busy = true;
    }

    pub fn hide(wl: *Wl) void {
        if (wl.wins.items.len == 0) return;
        for (wl.wins.items) |*w| {
            var m = Msg.init();
            if (w.viewport != 0) {
                wl.req(w.viewport, 0, &m);
                wl.forget(w.viewport);
            }
            wl.req(w.toplevel, 0, &m);
            wl.forget(w.toplevel);
            wl.req(w.xdg_surface, 0, &m);
            wl.forget(w.xdg_surface);
            wl.req(w.surface, 0, &m);
            wl.forget(w.surface);
            for (w.buffers) |b| if (b.id != 0) {
                wl.req(b.id, 0, &m);
                wl.forget(b.id);
            };
            if (w.pool != 0) {
                wl.req(w.pool, 1, &m);
                wl.forget(w.pool);
            }
            if (w.frame_cb != 0) wl.forget(w.frame_cb);
            if (w.shm) |*s| s.deinit();
        }
        wl.wins.clearRetainingCapacity();
        wl.pointer_win = null;
        wl.canvas = &.{};
        wl.roundtrip() catch {};
        wl.events.clearRetainingCapacity();
    }
};

// ------------------------------------------------------------------ wire helpers

const Msg = struct {
    b: [512]u8 = undefined,
    n: usize = 8,

    fn init() Msg {
        return .{};
    }
    fn u(m: *Msg, v: u32) void {
        std.mem.writeInt(u32, m.b[m.n..][0..4], v, .little);
        m.n += 4;
    }
    fn i(m: *Msg, v: i32) void {
        m.u(@bitCast(v));
    }
    fn s(m: *Msg, v: []const u8) void {
        m.u(@intCast(v.len + 1));
        @memcpy(m.b[m.n..][0..v.len], v);
        m.b[m.n + v.len] = 0;
        const padded = std.mem.alignForward(usize, v.len + 1, 4);
        @memset(m.b[m.n + v.len + 1 .. m.n + padded], 0);
        m.n += padded;
    }
};

const Rd = struct {
    b: []const u8,
    pos: usize = 0,

    fn u(r: *Rd) u32 {
        if (r.pos + 4 > r.b.len) return 0;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.b[r.pos..][0..4], .little);
    }
    fn i(r: *Rd) i32 {
        return @bitCast(r.u());
    }
    fn s(r: *Rd) []const u8 {
        const len = r.u();
        if (len == 0 or r.pos + len > r.b.len) return "";
        defer r.pos += std.mem.alignForward(usize, len, 4);
        return r.b[r.pos..][0 .. len - 1];
    }
};
