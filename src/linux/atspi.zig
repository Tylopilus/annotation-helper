//! UI element under a point via AT-SPI (the Linux accessibility bus), the counterpart
//! of UI Automation. Works for GTK, Qt, LibreOffice, Firefox and (with accessibility
//! enabled) Chromium/Electron apps. On Wayland, apps report window-relative positions,
//! so only the active window can be named there; on X11 the element itself is found.

const std = @import("std");
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");
const model = @import("../model.zig");

const Allocator = std.mem.Allocator;
const Ref = struct { bus: []const u8, path: []const u8 };

const ACC = "org.a11y.atspi.Accessible";
const COMP = "org.a11y.atspi.Component";
const TEXT = "org.a11y.atspi.Text";
const NULL_PATH = "/org/a11y/atspi/null";
const STATE_ACTIVE = 1;
const STATE_SHOWING = 25;
const TIMEOUT = 800;

pub const Atspi = struct {
    conn: *dbus.Conn,
    /// On Wayland the screen coordinates apps report are not trustworthy.
    wayland: bool,

    pub fn init(a: Allocator, wayland: bool) !Atspi {
        const session = try dbus.Conn.session(a);
        defer session.close();
        var o = session.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress");
        defer o.deinit();
        var rep = try session.callWait(&o, 3000);
        defer rep.deinit(a);
        var r = rep.reader();
        const addr = try r.string();
        return .{ .conn = try dbus.Conn.open(a, addr), .wayland = wayland };
    }

    pub fn deinit(s: *Atspi) void {
        s.conn.close();
    }

    fn call(s: *Atspi, ref: Ref, iface: []const u8, member: []const u8, comptime sig: []const u8, args: anytype) ?dbus.Message {
        var o = s.conn.call(ref.bus, ref.path, iface, member);
        defer o.deinit();
        o.sig = sig;
        inline for (args) |v| switch (@TypeOf(v)) {
            i32, comptime_int => o.body.int32(v),
            u32 => o.body.uint32(v),
            else => o.body.string(v),
        };
        return s.conn.callWait(&o, TIMEOUT) catch null;
    }

    fn children(s: *Atspi, a: Allocator, ref: Ref) []Ref {
        var rep = s.call(ref, ACC, "GetChildren", "", .{}) orelse return &.{};
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        var out: std.ArrayList(Ref) = .empty;
        const end = r.beginArray(8) catch return &.{};
        while (r.pos < end) {
            r.beginStruct() catch break;
            const bus = r.string() catch break;
            const path = r.objectPath() catch break;
            out.append(a, .{ .bus = a.dupe(u8, bus) catch break, .path = a.dupe(u8, path) catch break }) catch break;
        }
        return out.items;
    }

    fn stateHas(s: *Atspi, ref: Ref, bit: u5) bool {
        var rep = s.call(ref, ACC, "GetState", "", .{}) orelse return false;
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        _ = r.beginArray(4) catch return false;
        const lo = r.uint32() catch return false;
        return lo & (@as(u32, 1) << bit) != 0;
    }

    fn extents(s: *Atspi, ref: Ref) ?model.Rect {
        var rep = s.call(ref, COMP, "GetExtents", "u", .{@as(u32, 0)}) orelse return null;
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        r.beginStruct() catch return null;
        const x = r.int32() catch return null;
        const y = r.int32() catch return null;
        const w = r.int32() catch return null;
        const h = r.int32() catch return null;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    fn stringProp(s: *Atspi, a: Allocator, ref: Ref, name: []const u8) []const u8 {
        var rep = s.conn.getProperty(ref.bus, ref.path, ACC, name, TIMEOUT) catch return "";
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        const v = (r.variantString() catch null) orelse return "";
        return a.dupe(u8, v) catch "";
    }

    fn parent(s: *Atspi, a: Allocator, ref: Ref) ?Ref {
        var rep = s.conn.getProperty(ref.bus, ref.path, ACC, "Parent", TIMEOUT) catch return null;
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        const vs = r.signature() catch return null;
        if (!std.mem.eql(u8, vs, "(so)")) return null;
        r.beginStruct() catch return null;
        const bus = r.string() catch return null;
        const path = r.objectPath() catch return null;
        if (std.mem.eql(u8, path, NULL_PATH)) return null;
        return .{ .bus = a.dupe(u8, bus) catch return null, .path = a.dupe(u8, path) catch return null };
    }

    fn roleName(s: *Atspi, a: Allocator, ref: Ref) []const u8 {
        var rep = s.call(ref, ACC, "GetLocalizedRoleName", "", .{}) orelse s.call(ref, ACC, "GetRoleName", "", .{}) orelse return "";
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        return a.dupe(u8, r.string() catch return "") catch "";
    }

    fn atPoint(s: *Atspi, a: Allocator, ref: Ref, x: i32, y: i32) ?Ref {
        var rep = s.call(ref, COMP, "GetAccessibleAtPoint", "iiu", .{ x, y, @as(u32, 0) }) orelse return null;
        defer rep.deinit(s.conn.a);
        var r = rep.reader();
        r.beginStruct() catch return null;
        const bus = r.string() catch return null;
        const path = r.objectPath() catch return null;
        if (std.mem.eql(u8, path, NULL_PATH) or bus.len == 0) return null;
        return .{ .bus = a.dupe(u8, bus) catch return null, .path = a.dupe(u8, path) catch return null };
    }

    /// The child of `ref` under (x, y). The toolkit's own answer is used only if its
    /// bounds really contain the point (GTK 4 returns wrong children); otherwise the
    /// smallest showing child whose bounds contain it.
    fn childAt(s: *Atspi, a: Allocator, ref: Ref, x: i32, y: i32) ?Ref {
        if (s.atPoint(a, ref, x, y)) |c| {
            const same = std.mem.eql(u8, c.bus, ref.bus) and std.mem.eql(u8, c.path, ref.path);
            if (!same) if (s.extents(c)) |r| if (r.contains(x, y)) return c;
        }
        var best: ?Ref = null;
        var best_area: i64 = std.math.maxInt(i64);
        const kids = s.children(a, ref);
        for (kids[0..@min(kids.len, 200)]) |c| {
            const r = s.extents(c) orelse continue;
            if (!r.contains(x, y) or r.w <= 0 or r.h <= 0) continue;
            const area = @as(i64, r.w) * r.h;
            if (area < best_area and s.stateHas(c, STATE_SHOWING)) {
                best = c;
                best_area = area;
            }
        }
        return best;
    }

    fn textLineAt(s: *Atspi, a: Allocator, ref: Ref, x: i32, y: i32) ?[]const u8 {
        var rep = s.call(ref, TEXT, "GetOffsetAtPoint", "iiu", .{ x, y, @as(u32, 0) }) orelse return null;
        var r = rep.reader();
        const off = r.int32() catch -1;
        rep.deinit(s.conn.a);
        if (off < 0) return null;
        var line = s.call(ref, TEXT, "GetStringAtOffset", "iu", .{ off, @as(u32, 3) }) orelse
            s.call(ref, TEXT, "GetTextAtOffset", "iu", .{ off, @as(u32, 4) }) orelse return null;
        defer line.deinit(s.conn.a);
        var lr = line.reader();
        const text = clip(a, lr.string() catch return null, 300);
        return if (text.len > 0) text else null;
    }

    const Frame = struct { ref: Ref, rect: ?model.Rect, active: bool };

    /// Top-level windows of all applications, active first.
    fn frames(s: *Atspi, a: Allocator) []Frame {
        const root = Ref{ .bus = "org.a11y.atspi.Registry", .path = "/org/a11y/atspi/accessible/root" };
        var out: std.ArrayList(Frame) = .empty;
        for (s.children(a, root)) |app| for (s.children(a, app)) |f| {
            const active = s.stateHas(f, STATE_ACTIVE);
            if (!active and !s.stateHas(f, STATE_SHOWING)) continue;
            out.append(a, .{ .ref = f, .rect = s.extents(f), .active = active }) catch {};
        };
        std.mem.sort(Frame, out.items, {}, struct {
            fn lt(_: void, x: Frame, y: Frame) bool {
                return @intFromBool(x.active) > @intFromBool(y.active);
            }
        }.lt);
        return out.items;
    }

    fn processOf(s: *Atspi, a: Allocator, ref: Ref) []const u8 {
        const pid = s.conn.connectionPid(ref.bus) orelse return "";
        return sys.processName(a, pid);
    }

    /// Title and process of the active window.
    pub fn activeWindow(s: *Atspi, a: Allocator) ?model.WindowInfo {
        for (s.frames(a)) |f| if (f.active) return .{ .title = s.stringProp(a, f.ref, "Name"), .process = s.processOf(a, f.ref) };
        return null;
    }

    /// What lies at (x, y) in screen coordinates; strings allocated in `a` (an arena).
    pub fn elementAt(s: *Atspi, a: Allocator, x: i32, y: i32) ?model.UiElement {
        const all = s.frames(a);
        var frame: ?Frame = null;
        if (s.wayland) {
            // Positions are window-relative: only the active window can be named.
            for (all) |f| if (f.active) {
                frame = f;
                break;
            };
            const f = frame orelse return null;
            return .{ .control_type = "window", .process = s.processOf(a, f.ref), .window_title = clip(a, s.stringProp(a, f.ref, "Name"), 160) };
        }
        for (all) |f| if (f.rect) |r| if (r.contains(x, y)) {
            frame = f;
            break;
        };
        const f = frame orelse return null;
        var cur = f.ref;
        var depth: u32 = 0;
        while (depth < 32) : (depth += 1) {
            cur = s.childAt(a, cur, x, y) orelse break;
        }
        var out = model.UiElement{
            .name = clip(a, s.stringProp(a, cur, "Name"), 160),
            .control_type = s.roleName(a, cur),
            .framework = "AT-SPI",
            .process = s.processOf(a, cur),
            .window_title = clip(a, s.stringProp(a, f.ref, "Name"), 160),
            .rect = s.extents(cur),
            .text_at_point = s.textLineAt(a, cur, x, y),
        };
        if (out.name.len == 0) out.name = clip(a, s.stringProp(a, cur, "Description"), 160);
        var ancestors: std.ArrayList([]const u8) = .empty;
        var p = cur;
        depth = 0;
        while (depth < 8) : (depth += 1) {
            const up = s.parent(a, p) orelse break;
            if (std.mem.eql(u8, up.path, f.ref.path) and std.mem.eql(u8, up.bus, f.ref.bus)) break;
            const name = clip(a, s.stringProp(a, up, "Name"), 80);
            if (name.len > 0 and ancestors.items.len < 5) {
                ancestors.append(a, a.print("{s} \"{s}\"", .{ s.roleName(a, up), name }) catch "") catch {};
            }
            // Text often lives on the enclosing document/editor, not the leaf.
            if (out.text_at_point == null and depth < 3) out.text_at_point = s.textLineAt(a, up, x, y);
            p = up;
        }
        out.ancestors = ancestors.items;
        return out;
    }
};

/// Collapse whitespace and cap the length (in code points).
fn clip(a: Allocator, s: []const u8, max: usize) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n");
    var count: usize = 0;
    while (it.next()) |word| {
        if (out.items.len > 0) out.append(a, ' ') catch return s;
        for (word) |ch| {
            if (ch & 0xC0 != 0x80) count += 1;
            if (count > max) {
                out.appendSlice(a, "…") catch {};
                return out.items;
            }
            out.append(a, ch) catch return s;
        }
    }
    return out.items;
}
