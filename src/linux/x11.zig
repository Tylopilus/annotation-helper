//! Minimal X11 client speaking the wire protocol directly (no libX11): screenshots
//! (GetImage), a full-screen override-redirect window for drawing, keyboard/pointer
//! grabs, global hotkeys (GrabKey), monitors (RandR 1.5) and the active window (EWMH).

const std = @import("std");
const sys = @import("sys.zig");
const keys = @import("keys.zig");
const model = @import("../model.zig");
const raster = @import("../raster.zig");

const Allocator = std.mem.Allocator;
const Rect = model.Rect;
const Bgra = raster.Bgra;

pub const Event = union(enum) {
    key: struct { window: u32, keysym: u32, state: u16 },
    button: struct { x: i32, y: i32, button: u8, down: bool },
    motion: struct { x: i32, y: i32 },
    expose: u32,
};

pub const MASK_SHIFT: u16 = 1;
pub const MASK_LOCK: u16 = 2;
pub const MASK_CONTROL: u16 = 4;
pub const MASK_ALT: u16 = 8;
pub const MASK_NUM: u16 = 16;
pub const MASK_SUPER: u16 = 64;

const XError = struct { seq: u16, code: u8, major: u8 };

pub const X11 = struct {
    a: Allocator,
    fd: sys.fd_t,
    seq: u16 = 0,
    id_base: u32 = 0,
    id_mask: u32 = 0,
    next_id: u32 = 1,
    root: u32 = 0,
    root_depth: u8 = 24,
    width: u16 = 0,
    height: u16 = 0,
    max_req_bytes: usize = 262140,
    min_keycode: u8 = 8,
    max_keycode: u8 = 255,
    keysyms_per: u8 = 0,
    keymap: []u32 = &.{},
    rbuf: std.ArrayList(u8) = .empty,
    events: std.ArrayList(Event) = .empty,
    errors: std.ArrayList(XError) = .empty,
    randr_major: u8 = 0,
    // Drawing window
    win: u32 = 0,
    gc: u32 = 0,
    cursor: u32 = 0,

    pub fn connect(a: Allocator) !*X11 {
        const display = sys.env("DISPLAY") orelse return error.NoDisplay;
        // ":N" or ":N.S" (local only)
        const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return error.BadDisplay;
        if (colon != 0 and !std.mem.eql(u8, display[0..colon], "unix") and !std.mem.eql(u8, display[0..colon], "localhost")) return error.RemoteDisplayUnsupported;
        var num_s = display[colon + 1 ..];
        if (std.mem.indexOfScalar(u8, num_s, '.')) |d| num_s = num_s[0..d];
        var pbuf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "/tmp/.X11-unix/X{s}", .{num_s});
        const fd = sys.connectUnix(path, false) catch try sys.connectUnix(path, true);
        errdefer _ = sys.close(fd);
        const x = try a.create(X11);
        errdefer a.destroy(x);
        x.* = .{ .a = a, .fd = fd };
        try x.setup(num_s);
        x.loadKeymap() catch {};
        x.initRandr() catch {};
        x.initCursor() catch {};
        return x;
    }

    pub fn close(x: *X11) void {
        _ = sys.close(x.fd);
        x.a.free(x.keymap);
        x.rbuf.deinit(x.a);
        x.events.deinit(x.a);
        x.errors.deinit(x.a);
        x.a.destroy(x);
    }

    fn setup(x: *X11, display_num: []const u8) !void {
        var auth_name: []const u8 = "";
        var auth_data: []const u8 = "";
        var auth_buf: [512]u8 = undefined;
        if (findCookie(&auth_buf, display_num)) |c| {
            auth_name = "MIT-MAGIC-COOKIE-1";
            auth_data = c;
        }
        var w = Buf{};
        w.u8_(0x6c);
        w.u8_(0);
        w.u16_(11);
        w.u16_(0);
        w.u16_(@intCast(auth_name.len));
        w.u16_(@intCast(auth_data.len));
        w.u16_(0);
        w.str(auth_name);
        w.str(auth_data);
        try sys.writeAll(x.fd, w.slice());
        var head: [8]u8 = undefined;
        try sys.readExact(x.fd, &head);
        const extra = @as(usize, std.mem.readInt(u16, head[6..8], .little)) * 4;
        const data = try x.a.alloc(u8, extra);
        defer x.a.free(data);
        try sys.readExact(x.fd, data);
        if (head[0] != 1) return error.SetupRefused;
        x.id_base = rd32(data, 4);
        x.id_mask = rd32(data, 8);
        const vendor_len = rd16(data, 16);
        const max_req = rd16(data, 18);
        x.max_req_bytes = @as(usize, max_req) * 4;
        const n_formats = data[21];
        x.min_keycode = data[26];
        x.max_keycode = data[27];
        const screens_off = 32 + std.mem.alignForward(usize, vendor_len, 4) + @as(usize, n_formats) * 8;
        const s = data[screens_off..];
        x.root = rd32(s, 0);
        x.width = rd16(s, 20);
        x.height = rd16(s, 22);
        x.root_depth = s[38];
        // Pixmap format for the root depth must be 32 bpp (BGRX), true everywhere today.
        var i: usize = 0;
        while (i < n_formats) : (i += 1) {
            const f = data[32 + std.mem.alignForward(usize, vendor_len, 4) + i * 8 ..];
            if (f[0] == x.root_depth and f[1] != 32) return error.UnsupportedPixelFormat;
        }
    }

    fn newId(x: *X11) u32 {
        const shift: u5 = @intCast(@ctz(x.id_mask));
        defer x.next_id += 1;
        return x.id_base | ((x.next_id << shift) & x.id_mask);
    }

    fn send(x: *X11, bytes: []const u8) !void {
        x.seq +%= 1;
        try sys.writeAll(x.fd, bytes);
    }

    /// Sends a request and waits for its reply (events and errors are queued).
    fn request(x: *X11, bytes: []const u8) anyerror![]u8 {
        try x.send(bytes);
        const want = x.seq;
        while (true) {
            if (x.rbuf.items.len >= 32) {
                const kind = x.rbuf.items[0];
                const seq = rd16(x.rbuf.items, 2);
                if (kind == 1) {
                    const total = 32 + @as(usize, rd32(x.rbuf.items, 4)) * 4;
                    if (x.rbuf.items.len < total) {
                        try x.readMore(true);
                        continue;
                    }
                    const out = try x.a.dupe(u8, x.rbuf.items[0..total]);
                    x.rbuf.replaceRange(x.a, 0, total, &.{}) catch unreachable;
                    if (seq == want) return out;
                    x.a.free(out); // stale reply
                    continue;
                }
                if (kind == 0 and seq == want) {
                    const code = x.rbuf.items[1];
                    x.rbuf.replaceRange(x.a, 0, 32, &.{}) catch unreachable;
                    _ = code;
                    return error.XRequestFailed;
                }
                try x.takeOne();
                continue;
            }
            try x.readMore(true);
        }
    }

    fn readMore(x: *X11, block: bool) !void {
        if (block and !sys.waitReadable(x.fd, 10000)) return error.Timeout;
        var chunk: [65536]u8 = undefined;
        const n = sys.recv(x.fd, &chunk, chunk.len, if (block) 0 else 0x40);
        if (n == 0) return error.Disconnected;
        if (n < 0) {
            if (sys.errno() == sys.EAGAIN or sys.errno() == sys.EINTR) return;
            return error.Disconnected;
        }
        try x.rbuf.appendSlice(x.a, chunk[0..@intCast(n)]);
    }

    /// Consumes one event or error from the read buffer (needs ≥ 32 bytes).
    fn takeOne(x: *X11) anyerror!void {
        const b = x.rbuf.items;
        var len: usize = 32;
        const code = b[0] & 0x7f;
        if (code == 35) len += @as(usize, rd32(b, 4)) * 4; // GenericEvent
        if (b.len < len) return x.readMore(true);
        switch (code) {
            0 => x.errors.append(x.a, .{ .seq = rd16(b, 2), .code = b[1], .major = b[10] }) catch {},
            2, 3 => if (code == 2) {
                const kc = b[1];
                x.events.append(x.a, .{ .key = .{ .window = rd32(b, 12), .keysym = x.keysymFor(kc), .state = rd16(b, 28) } }) catch {};
            },
            4, 5 => x.events.append(x.a, .{ .button = .{ .x = rd16s(b, 20), .y = rd16s(b, 22), .button = b[1], .down = code == 4 } }) catch {},
            6 => x.events.append(x.a, .{ .motion = .{ .x = rd16s(b, 20), .y = rd16s(b, 22) } }) catch {},
            12 => x.events.append(x.a, .{ .expose = rd32(b, 4) }) catch {},
            34 => x.loadKeymap() catch {}, // MappingNotify
            else => {},
        }
        x.rbuf.replaceRange(x.a, 0, len, &.{}) catch unreachable;
    }

    /// Reads what is available (poll said readable) and decodes events.
    pub fn dispatch(x: *X11) !void {
        try x.readMore(false);
        while (x.rbuf.items.len >= 32) {
            if (x.rbuf.items[0] == 1) {
                // A reply nobody waits for (shouldn't happen); drop it.
                const total = 32 + @as(usize, rd32(x.rbuf.items, 4)) * 4;
                if (x.rbuf.items.len < total) break;
                x.rbuf.replaceRange(x.a, 0, total, &.{}) catch unreachable;
                continue;
            }
            const code = x.rbuf.items[0] & 0x7f;
            if (code == 35 and x.rbuf.items.len < 32 + @as(usize, rd32(x.rbuf.items, 4)) * 4) break;
            try x.takeOne();
        }
    }

    pub fn nextEvent(x: *X11) ?Event {
        if (x.events.items.len == 0) return null;
        return x.events.orderedRemove(0);
    }

    /// Round trip; returns true if an error for a request after `since` arrived.
    fn sync(x: *X11, since: u16) bool {
        var w = Buf{};
        w.u8_(43);
        w.u8_(0);
        w.u16_(1);
        const r = x.request(w.slice()) catch return true;
        x.a.free(r);
        var failed = false;
        var i: usize = 0;
        while (i < x.errors.items.len) {
            const e = x.errors.items[i];
            if (e.seq -% since < 0x8000) {
                failed = true;
                _ = x.errors.orderedRemove(i);
            } else i += 1;
        }
        return failed;
    }

    // ------------------------------------------------------------------ keyboard

    fn loadKeymap(x: *X11) !void {
        var w = Buf{};
        w.u8_(101);
        w.u8_(0);
        w.u16_(2);
        w.u8_(x.min_keycode);
        w.u8_(x.max_keycode - x.min_keycode + 1);
        w.u16_(0);
        const r = try x.request(w.slice());
        defer x.a.free(r);
        x.keysyms_per = r[1];
        const n = (r.len - 32) / 4;
        x.a.free(x.keymap);
        x.keymap = try x.a.alloc(u32, n);
        for (x.keymap, 0..) |*k, i| k.* = rd32(r, 32 + i * 4);
    }

    pub fn keysymFor(x: *X11, keycode: u8) u32 {
        if (keycode < x.min_keycode or x.keysyms_per == 0) return 0;
        const i = @as(usize, keycode - x.min_keycode) * x.keysyms_per;
        return if (i < x.keymap.len) x.keymap[i] else 0;
    }

    fn keycodeFor(x: *X11, keysym: u32) ?u8 {
        if (x.keysyms_per == 0) return null;
        var i: usize = 0;
        while (i < x.keymap.len) : (i += x.keysyms_per) {
            var j: usize = 0;
            while (j < @min(x.keysyms_per, 2)) : (j += 1) if (x.keymap[i + j] == keysym) return @intCast(x.min_keycode + i / x.keysyms_per);
        }
        return null;
    }

    /// Grabs a global hotkey on the root window (all Caps/Num lock variants).
    /// Returns false if another client already owns it.
    pub fn grabKey(x: *X11, mods: u16, vk: u32) bool {
        const kc = x.keycodeFor(keys.keysymFromVk(vk)) orelse return false;
        const since = x.seq +% 1;
        for ([_]u16{ 0, MASK_LOCK, MASK_NUM, MASK_LOCK | MASK_NUM }) |extra| {
            var w = Buf{};
            w.u8_(33);
            w.u8_(1); // owner_events
            w.u16_(4);
            w.u32_(x.root);
            w.u16_(mods | extra);
            w.u8_(kc);
            w.u8_(1); // pointer async
            w.u8_(1); // keyboard async
            w.pad(3);
            x.send(w.slice()) catch return false;
        }
        if (x.sync(since)) {
            x.ungrabKey(mods, vk);
            return false;
        }
        return true;
    }

    pub fn ungrabKey(x: *X11, mods: u16, vk: u32) void {
        const kc = x.keycodeFor(keys.keysymFromVk(vk)) orelse return;
        for ([_]u16{ 0, MASK_LOCK, MASK_NUM, MASK_LOCK | MASK_NUM }) |extra| {
            var w = Buf{};
            w.u8_(34);
            w.u8_(kc);
            w.u16_(3);
            w.u32_(x.root);
            w.u16_(mods | extra);
            w.u16_(0);
            x.send(w.slice()) catch {};
        }
        _ = x.sync(x.seq);
    }

    /// Active keyboard grab on the root window (hotkey capture). True on success.
    pub fn grabKeyboardRoot(x: *X11) bool {
        return x.grabKeyboard(x.root);
    }

    fn grabKeyboard(x: *X11, window: u32) bool {
        var tries: u32 = 0;
        while (tries < 20) : (tries += 1) {
            var w = Buf{};
            w.u8_(31);
            w.u8_(0);
            w.u16_(4);
            w.u32_(window);
            w.u32_(0);
            w.u8_(1);
            w.u8_(1);
            w.u16_(0);
            const r = x.request(w.slice()) catch return false;
            defer x.a.free(r);
            if (r[1] == 0) return true;
            sys.sleepMs(25); // another client (e.g. a menu) still holds it
        }
        return false;
    }

    pub fn ungrabKeyboard(x: *X11) void {
        var w = Buf{};
        w.u8_(32);
        w.u8_(0);
        w.u16_(2);
        w.u32_(0);
        x.send(w.slice()) catch {};
    }

    // ------------------------------------------------------------------ screen

    fn initRandr(x: *X11) !void {
        var w = Buf{};
        w.u8_(98);
        w.u8_(0);
        w.u16_(2 + 2);
        w.u16_(5);
        w.u16_(0);
        w.str("RANDR");
        const r = try x.request(w.slice());
        defer x.a.free(r);
        if (r[8] == 0) return;
        x.randr_major = r[9];
        var q = Buf{};
        q.u8_(x.randr_major);
        q.u8_(0); // QueryVersion
        q.u16_(3);
        q.u32_(1);
        q.u32_(5);
        const v = try x.request(q.slice());
        x.a.free(v);
    }

    pub const MonitorList = struct { items: [16]model.Monitor = undefined, n: usize = 0 };

    pub fn monitors(x: *X11) MonitorList {
        var list = MonitorList{};
        if (x.randr_major != 0) blk: {
            var w = Buf{};
            w.u8_(x.randr_major);
            w.u8_(42); // GetMonitors
            w.u16_(3);
            w.u32_(x.root);
            w.u8_(1);
            w.pad(3);
            const r = x.request(w.slice()) catch break :blk;
            defer x.a.free(r);
            const n = rd32(r, 12);
            var off: usize = 32;
            var i: usize = 0;
            while (i < n and off + 24 <= r.len and list.n < list.items.len) : (i += 1) {
                const noutputs = rd16(r, off + 6);
                list.items[list.n] = .{
                    .rect = .{ .x = rd16s(r, off + 8), .y = rd16s(r, off + 10), .w = rd16(r, off + 12), .h = rd16(r, off + 14) },
                    .primary = r[off + 4] != 0,
                };
                list.n += 1;
                off += 24 + @as(usize, noutputs) * 4;
            }
        }
        if (list.n == 0) {
            list.items[0] = .{ .rect = .{ .w = x.width, .h = x.height }, .primary = true };
            list.n = 1;
        }
        return list;
    }

    pub fn screenRect(x: *X11) Rect {
        return .{ .w = x.width, .h = x.height };
    }

    /// Captures `r` of the root window as opaque BGRA (allocated in `a`).
    pub fn capture(x: *X11, a: Allocator, r: Rect) ![]Bgra {
        const out = try a.alloc(Bgra, @intCast(r.w * r.h));
        errdefer a.free(out);
        // Large GetImage replies are fine, but keep each under ~16 MB.
        const rows_per = @max(1, @divTrunc(4 * 1024 * 1024, r.w));
        var y: i32 = 0;
        while (y < r.h) {
            const h = @min(rows_per, r.h - y);
            var w = Buf{};
            w.u8_(73);
            w.u8_(2); // ZPixmap
            w.u16_(5);
            w.u32_(x.root);
            w.u16_(@bitCast(@as(i16, @intCast(r.x))));
            w.u16_(@bitCast(@as(i16, @intCast(r.y + y))));
            w.u16_(@intCast(r.w));
            w.u16_(@intCast(h));
            w.u32_(0xffffffff);
            const rep = try x.request(w.slice());
            defer x.a.free(rep);
            const px = rep[32..];
            const need: usize = @intCast(r.w * h * 4);
            if (px.len < need) return error.ShortImage;
            const dst = std.mem.sliceAsBytes(out[@intCast(y * r.w)..][0..@intCast(r.w * h)]);
            @memcpy(dst, px[0..need]);
            y += h;
        }
        for (out) |*p| p.a = 255;
        return out;
    }

    pub fn cursorPos(x: *X11) ?[2]i32 {
        var w = Buf{};
        w.u8_(38);
        w.u8_(0);
        w.u16_(2);
        w.u32_(x.root);
        const r = x.request(w.slice()) catch return null;
        defer x.a.free(r);
        return .{ rd16s(r, 16), rd16s(r, 18) };
    }

    // ------------------------------------------------------------------ windows

    fn initCursor(x: *X11) !void {
        const font = x.newId();
        var w = Buf{};
        w.u8_(45); // OpenFont
        w.u8_(0);
        w.u16_(3 + 2);
        w.u32_(font);
        w.u16_(6);
        w.u16_(0);
        w.str("cursor");
        try x.send(w.slice());
        x.cursor = x.newId();
        var c = Buf{};
        c.u8_(94); // CreateGlyphCursor
        c.u8_(0);
        c.u16_(8);
        c.u32_(x.cursor);
        c.u32_(font);
        c.u32_(font);
        c.u16_(34); // XC_crosshair
        c.u16_(35);
        c.u16_(0xffff);
        c.u16_(0xffff);
        c.u16_(0xffff);
        c.u16_(0);
        c.u16_(0);
        c.u16_(0);
        try x.send(c.slice());
        if (x.sync(x.seq -% 1)) x.cursor = 0;
    }

    /// Shows an override-redirect window over `r` and grabs keyboard and pointer.
    pub fn showWindow(x: *X11, r: Rect) !void {
        if (x.win != 0) x.hideWindow();
        x.win = x.newId();
        var w = Buf{};
        w.u8_(1); // CreateWindow
        w.u8_(0); // CopyFromParent depth
        w.u16_(8 + 4);
        w.u32_(x.win);
        w.u32_(x.root);
        w.u16_(@bitCast(@as(i16, @intCast(r.x))));
        w.u16_(@bitCast(@as(i16, @intCast(r.y))));
        w.u16_(@intCast(r.w));
        w.u16_(@intCast(r.h));
        w.u16_(0);
        w.u16_(1); // InputOutput
        w.u32_(0); // CopyFromParent visual
        w.u32_(0x200 | 0x800 | 0x4000 | 0x2); // background pixel, override-redirect, event-mask, cursor
        w.u32_(0); // background pixel: black
        w.u32_(1); // override-redirect
        w.u32_(1 | 2 | 4 | 8 | 0x40 | 0x8000); // key, button, motion, exposure
        w.u32_(x.cursor);
        try x.send(w.slice());
        x.gc = x.newId();
        var g = Buf{};
        g.u8_(55);
        g.u8_(0);
        g.u16_(4);
        g.u32_(x.gc);
        g.u32_(x.win);
        g.u32_(0);
        try x.send(g.slice());
        var m = Buf{};
        m.u8_(8); // MapWindow
        m.u8_(0);
        m.u16_(2);
        m.u32_(x.win);
        try x.send(m.slice());
        _ = x.sync(x.seq);
        if (!x.grabKeyboard(x.win)) return error.KeyboardGrabFailed;
        var p = Buf{};
        p.u8_(26); // GrabPointer
        p.u8_(0);
        p.u16_(6);
        p.u32_(x.win);
        p.u16_(4 | 8 | 0x40);
        p.u8_(1);
        p.u8_(1);
        p.u32_(x.win);
        p.u32_(x.cursor);
        p.u32_(0);
        const rep = try x.request(p.slice());
        x.a.free(rep);
    }

    pub fn hideWindow(x: *X11) void {
        if (x.win == 0) return;
        x.ungrabKeyboard();
        var u = Buf{};
        u.u8_(27); // UngrabPointer
        u.u8_(0);
        u.u16_(2);
        u.u32_(0);
        x.send(u.slice()) catch {};
        var g = Buf{};
        g.u8_(60); // FreeGC
        g.u8_(0);
        g.u16_(2);
        g.u32_(x.gc);
        x.send(g.slice()) catch {};
        var d = Buf{};
        d.u8_(4); // DestroyWindow
        d.u8_(0);
        d.u16_(2);
        d.u32_(x.win);
        x.send(d.slice()) catch {};
        _ = x.sync(x.seq);
        x.win = 0;
        // Drop input events still addressed to the old window.
        x.events.clearRetainingCapacity();
    }

    /// Copies `dirty` (window coordinates) of `px` (window-sized BGRA) to the window.
    pub fn present(x: *X11, px: []const Bgra, width: i32, dirty: Rect) void {
        if (x.win == 0 or dirty.isEmpty()) return;
        const row_bytes: usize = @intCast(dirty.w * 4);
        const rows_per: i32 = @intCast(@max(1, (x.max_req_bytes - 24) / row_bytes));
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(x.a);
        var y: i32 = 0;
        while (y < dirty.h) {
            const h = @min(rows_per, dirty.h - y);
            tmp.clearRetainingCapacity();
            const total = 24 + row_bytes * @as(usize, @intCast(h));
            tmp.ensureTotalCapacity(x.a, total) catch return;
            var w = Buf{};
            w.u8_(72);
            w.u8_(2);
            w.u16_(@intCast(total / 4));
            w.u32_(x.win);
            w.u32_(x.gc);
            w.u16_(@intCast(dirty.w));
            w.u16_(@intCast(h));
            w.u16_(@bitCast(@as(i16, @intCast(dirty.x))));
            w.u16_(@bitCast(@as(i16, @intCast(dirty.y + y))));
            w.u8_(0);
            w.u8_(x.root_depth);
            w.u16_(0);
            tmp.appendSliceAssumeCapacity(w.slice());
            var row: i32 = 0;
            while (row < h) : (row += 1) {
                const start: usize = @intCast((dirty.y + y + row) * width + dirty.x);
                tmp.appendSliceAssumeCapacity(std.mem.sliceAsBytes(px[start..][0..@intCast(dirty.w)]));
            }
            x.send(tmp.items) catch return;
            y += h;
        }
    }

    // ------------------------------------------------------------------ properties

    fn atom(x: *X11, name: []const u8) u32 {
        var w = Buf{};
        w.u8_(16);
        w.u8_(1); // only if exists
        w.u16_(@intCast(2 + std.mem.alignForward(usize, name.len, 4) / 4));
        w.u16_(@intCast(name.len));
        w.u16_(0);
        w.str(name);
        const r = x.request(w.slice()) catch return 0;
        defer x.a.free(r);
        return rd32(r, 8);
    }

    /// Property bytes (allocated in `a`), or null.
    fn property(x: *X11, a: Allocator, window: u32, prop: u32) ?[]u8 {
        if (prop == 0) return null;
        var w = Buf{};
        w.u8_(20);
        w.u8_(0);
        w.u16_(6);
        w.u32_(window);
        w.u32_(prop);
        w.u32_(0);
        w.u32_(0);
        w.u32_(4096);
        const r = x.request(w.slice()) catch return null;
        defer x.a.free(r);
        const format = r[1];
        if (format == 0) return null;
        const n = @as(usize, rd32(r, 16)) * (format / 8);
        if (32 + n > r.len) return null;
        return a.dupe(u8, r[32..][0..n]) catch null;
    }

    /// Title and process of the active window (EWMH).
    pub fn activeWindow(x: *X11, a: Allocator) ?model.WindowInfo {
        const active = x.property(a, x.root, x.atom("_NET_ACTIVE_WINDOW")) orelse return null;
        if (active.len < 4) return null;
        const win = rd32(active, 0);
        if (win == 0) return null;
        const title = x.property(a, win, x.atom("_NET_WM_NAME")) orelse x.property(a, win, 39) orelse ""; // 39 = WM_NAME
        var process: []const u8 = "";
        if (x.property(a, win, x.atom("_NET_WM_PID"))) |pid| if (pid.len >= 4) {
            process = sys.processName(a, rd32(pid, 0));
        };
        return .{ .title = title, .process = process };
    }
};

// ------------------------------------------------------------------ helpers

const Buf = struct {
    b: [64]u8 = undefined,
    n: usize = 0,
    fn u8_(s: *Buf, v: u8) void {
        s.b[s.n] = v;
        s.n += 1;
    }
    fn u16_(s: *Buf, v: u16) void {
        std.mem.writeInt(u16, s.b[s.n..][0..2], v, .little);
        s.n += 2;
    }
    fn u32_(s: *Buf, v: u32) void {
        std.mem.writeInt(u32, s.b[s.n..][0..4], v, .little);
        s.n += 4;
    }
    fn pad(s: *Buf, n: usize) void {
        @memset(s.b[s.n..][0..n], 0);
        s.n += n;
    }
    fn str(s: *Buf, v: []const u8) void {
        @memcpy(s.b[s.n..][0..v.len], v);
        s.n += v.len;
        s.pad(std.mem.alignForward(usize, v.len, 4) - v.len);
    }
    fn slice(s: *const Buf) []const u8 {
        return s.b[0..s.n];
    }
};

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd16s(b: []const u8, off: usize) i32 {
    return @as(i16, @bitCast(rd16(b, off)));
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// MIT-MAGIC-COOKIE-1 for this display from $XAUTHORITY or ~/.Xauthority.
fn findCookie(out: []u8, display_num: []const u8) ?[]const u8 {
    var pbuf: [512]u8 = undefined;
    const path: [:0]const u8 = if (sys.env("XAUTHORITY")) |p|
        std.fmt.bufPrintSentinel(&pbuf, "{s}", .{p}, 0) catch return null
    else
        std.fmt.bufPrintSentinel(&pbuf, "{s}/.Xauthority", .{sys.env("HOME") orelse return null}, 0) catch return null;
    const fd = sys.open(path.ptr, sys.O_RDONLY | sys.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = sys.close(fd);
    var data: [16384]u8 = undefined;
    const n = sys.read(fd, &data, data.len);
    if (n <= 0) return null;
    const d = data[0..@intCast(n)];
    var off: usize = 0;
    const field = struct {
        fn f(b: []const u8, o: *usize) ?[]const u8 {
            if (o.* + 2 > b.len) return null;
            const len = std.mem.readInt(u16, b[o.*..][0..2], .big);
            o.* += 2;
            if (o.* + len > b.len) return null;
            defer o.* += len;
            return b[o.*..][0..len];
        }
    }.f;
    while (off + 2 <= d.len) {
        const family = std.mem.readInt(u16, d[off..][0..2], .big);
        off += 2;
        _ = field(d, &off) orelse return null; // address
        const number = field(d, &off) orelse return null;
        const name = field(d, &off) orelse return null;
        const cookie = field(d, &off) orelse return null;
        if (!std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1")) continue;
        if (family != 256 and family != 0xffff) continue; // Local or Wild
        if (number.len > 0 and !std.mem.eql(u8, number, display_num)) continue;
        if (cookie.len > out.len) continue;
        @memcpy(out[0..cookie.len], cookie);
        return out[0..cookie.len];
    }
    return null;
}
