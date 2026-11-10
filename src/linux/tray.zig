//! Tray icon: a StatusNotifierItem with a com.canonical.dbusmenu menu (KDE, GNOME with
//! the AppIndicator extension, XFCE, Cinnamon, waybar, …). The app builds the menu as a
//! flat list; clicks come back through `handle`.

const std = @import("std");
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");
const raster = @import("../raster.zig");
const util = @import("../util.zig");

const Message = dbus.Message;
const Writer = dbus.Writer;

const ITEM_PATH = "/StatusNotifierItem";
const MENU_PATH = "/MenuBar";
const SNI = "org.kde.StatusNotifierItem";
const MENU = "com.canonical.dbusmenu";

pub const Item = struct {
    id: i32,
    label: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
    /// id of the parent submenu (0 = top level).
    parent: i32 = 0,
    submenu: bool = false,
};

pub const Tray = struct {
    bus: *dbus.Conn,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    items: std.ArrayList(Item) = .empty,
    labels: std.heap.ArenaAllocator,
    revision: u32 = 1,
    recording: bool = false,
    tooltip: [160]u8 = undefined,
    tooltip_len: usize = 0,
    icons: [2][3][]u8 = undefined, // [idle, recording][22, 32, 48] ARGB big-endian
    registered: bool = false,

    pub fn init(bus: *dbus.Conn) !*Tray {
        const t = try util.gpa.create(Tray);
        t.* = .{ .bus = bus, .labels = .init(util.gpa) };
        const n = (std.fmt.bufPrint(&t.name, "org.kde.StatusNotifierItem-{d}-1", .{sys.getpid()}) catch unreachable).len;
        t.name_len = n;
        _ = bus.requestName(t.name[0..n]) catch false;
        for ([_]bool{ false, true }, 0..) |rec, i| for ([_]i32{ 22, 32, 48 }, 0..) |size, j| {
            t.icons[i][j] = try makeIcon(size, rec);
        };
        bus.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.kde.StatusNotifierWatcher'");
        t.register();
        return t;
    }

    /// Registers with the StatusNotifierWatcher (again after it restarts).
    pub fn register(t: *Tray) void {
        var o = t.bus.call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem");
        defer o.deinit();
        o.sig = "s";
        o.body.string(t.name[0..t.name_len]);
        if (t.bus.callWait(&o, 3000)) |rep| {
            var r = rep;
            r.deinit(t.bus.a);
            t.registered = true;
        } else |_| {
            t.registered = false;
        }
    }

    /// Replaces the menu (labels are copied).
    pub fn setMenu(t: *Tray, items: []const Item) void {
        _ = t.labels.reset(.retain_capacity);
        t.items.clearRetainingCapacity();
        const a = t.labels.allocator();
        for (items) |it| {
            var c = it;
            c.label = a.dupe(u8, it.label) catch "";
            t.items.append(util.gpa, c) catch {};
        }
        t.revision += 1;
        var o = t.bus.signal(MENU_PATH, MENU, "LayoutUpdated");
        defer o.deinit();
        o.sig = "ui";
        o.body.uint32(t.revision);
        o.body.int32(0);
        _ = t.bus.send(&o) catch {};
    }

    pub fn setState(t: *Tray, recording: bool, tooltip: []const u8) void {
        const n = @min(tooltip.len, t.tooltip.len);
        const changed_tip = !std.mem.eql(u8, t.tooltip[0..t.tooltip_len], tooltip[0..n]);
        @memcpy(t.tooltip[0..n], tooltip[0..n]);
        t.tooltip_len = n;
        if (recording != t.recording) {
            t.recording = recording;
            t.emit("NewIcon");
        }
        if (changed_tip) t.emit("NewToolTip");
    }

    fn emit(t: *Tray, member: []const u8) void {
        var o = t.bus.signal(ITEM_PATH, SNI, member);
        defer o.deinit();
        _ = t.bus.send(&o) catch {};
    }

    /// Handles a message addressed to the tray; returns the clicked item id (if any).
    /// `handled` tells whether the message was ours.
    pub fn handle(t: *Tray, m: *const Message, handled: *bool) ?i32 {
        handled.* = false;
        if (m.type == .signal) {
            if (m.is("org.freedesktop.DBus", "NameOwnerChanged")) {
                var r = m.reader();
                const name = r.string() catch return null;
                _ = r.string() catch return null;
                const new_owner = r.string() catch return null;
                if (std.mem.eql(u8, name, "org.kde.StatusNotifierWatcher") and new_owner.len > 0) t.register();
            }
            return null;
        }
        if (m.type != .call) return null;
        const is_item = std.mem.eql(u8, m.path, ITEM_PATH);
        const is_menu = std.mem.eql(u8, m.path, MENU_PATH);
        if (!is_item and !is_menu) return null;
        handled.* = true;
        if (m.is("org.freedesktop.DBus.Introspectable", "Introspect")) {
            t.replyString(m, if (is_item) ITEM_XML else MENU_XML);
            return null;
        }
        if (std.mem.eql(u8, m.iface, "org.freedesktop.DBus.Properties")) {
            t.properties(m, is_item);
            return null;
        }
        if (is_item) {
            // Activate / SecondaryActivate / ContextMenu / Scroll: the host shows our menu.
            t.replyEmpty(m);
            return null;
        }
        if (std.mem.eql(u8, m.member, "GetLayout")) {
            var r = m.reader();
            const parent = r.int32() catch 0;
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "u(ia{sv}av)";
            o.body.uint32(t.revision);
            t.writeNode(&o.body, parent);
            _ = t.bus.send(&o) catch {};
        } else if (std.mem.eql(u8, m.member, "GetGroupProperties")) {
            var r = m.reader();
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "a(ia{sv})";
            const arr = o.body.beginArray(8);
            if (r.beginArray(4)) |end| {
                while (r.pos < end) {
                    const id = r.int32() catch break;
                    o.body.beginStruct();
                    o.body.int32(id);
                    t.writeProps(&o.body, id);
                }
            } else |_| {}
            o.body.endArray(arr);
            _ = t.bus.send(&o) catch {};
        } else if (std.mem.eql(u8, m.member, "GetProperty")) {
            var r = m.reader();
            const id = r.int32() catch 0;
            const name = r.string() catch "";
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "v";
            const it = t.find(id);
            if (std.mem.eql(u8, name, "label")) {
                o.body.variant("s");
                o.body.string(if (it) |x| x.label else "");
            } else if (std.mem.eql(u8, name, "enabled")) {
                o.body.variant("b");
                o.body.boolean(if (it) |x| x.enabled else true);
            } else {
                o.body.variant("s");
                o.body.string("");
            }
            _ = t.bus.send(&o) catch {};
        } else if (std.mem.eql(u8, m.member, "Event")) {
            var r = m.reader();
            const id = r.int32() catch 0;
            const ev = r.string() catch "";
            t.replyEmpty(m);
            if (std.mem.eql(u8, ev, "clicked")) return id;
        } else if (std.mem.eql(u8, m.member, "EventGroup")) {
            var r = m.reader();
            var clicked: ?i32 = null;
            if (r.beginArray(8)) |end| {
                while (r.pos < end) {
                    r.beginStruct() catch break;
                    const id = r.int32() catch break;
                    const ev = r.string() catch break;
                    _ = r.skip("v") catch break;
                    _ = r.uint32() catch break;
                    if (std.mem.eql(u8, ev, "clicked")) clicked = id;
                }
            } else |_| {}
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "ai";
            const arr = o.body.beginArray(4);
            o.body.endArray(arr);
            _ = t.bus.send(&o) catch {};
            return clicked;
        } else if (std.mem.eql(u8, m.member, "AboutToShow")) {
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "b";
            o.body.boolean(false);
            _ = t.bus.send(&o) catch {};
        } else if (std.mem.eql(u8, m.member, "AboutToShowGroup")) {
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "aiai";
            const a1 = o.body.beginArray(4);
            o.body.endArray(a1);
            const a2 = o.body.beginArray(4);
            o.body.endArray(a2);
            _ = t.bus.send(&o) catch {};
        } else t.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
        return null;
    }

    fn find(t: *Tray, id: i32) ?Item {
        for (t.items.items) |it| if (it.id == id) return it;
        return null;
    }

    fn writeProps(t: *Tray, w: *Writer, id: i32) void {
        const d = w.beginArray(8);
        if (id == 0) {
            w.dictEntryStr("children-display", "submenu");
        } else if (t.find(id)) |it| {
            if (it.separator) {
                w.dictEntryStr("type", "separator");
            } else {
                w.dictEntryStr("label", it.label);
                w.dictEntryBool("enabled", it.enabled);
                if (it.submenu) w.dictEntryStr("children-display", "submenu");
            }
        }
        w.endArray(d);
    }

    fn writeNode(t: *Tray, w: *Writer, id: i32) void {
        w.beginStruct();
        w.int32(id);
        t.writeProps(w, id);
        const kids = w.beginArray(1);
        for (t.items.items) |it| if (it.parent == id) {
            w.variant("(ia{sv}av)");
            t.writeNode(w, it.id);
        };
        w.endArray(kids);
    }

    fn properties(t: *Tray, m: *const Message, is_item: bool) void {
        var r = m.reader();
        _ = r.string() catch {}; // interface
        if (std.mem.eql(u8, m.member, "GetAll")) {
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "a{sv}";
            const arr = o.body.beginArray(8);
            const names: []const []const u8 = if (is_item) &item_props else &menu_props;
            for (names) |n| {
                o.body.beginStruct();
                o.body.string(n);
                t.writeProp(&o.body, n, is_item);
            }
            o.body.endArray(arr);
            _ = t.bus.send(&o) catch {};
        } else if (std.mem.eql(u8, m.member, "Get")) {
            const name = r.string() catch "";
            var o = t.bus.methodReturn(m);
            defer o.deinit();
            o.sig = "v";
            t.writeProp(&o.body, name, is_item);
            _ = t.bus.send(&o) catch {};
        } else if (std.mem.eql(u8, m.member, "Set")) {
            t.replyEmpty(m);
        } else t.bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "unknown method");
    }

    const item_props = [_][]const u8{ "Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap", "AttentionIconName", "OverlayIconName", "ToolTip", "ItemIsMenu", "Menu", "IconThemePath" };
    const menu_props = [_][]const u8{ "Version", "TextDirection", "Status", "IconThemePath" };

    fn writeProp(t: *Tray, w: *Writer, name: []const u8, is_item: bool) void {
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        if (!is_item) {
            if (eq(name, "Version")) {
                w.variant("u");
                w.uint32(3);
            } else if (eq(name, "IconThemePath")) {
                w.variant("as");
                const arr = w.beginArray(4);
                w.endArray(arr);
            } else {
                w.variant("s");
                w.string(if (eq(name, "TextDirection")) "ltr" else "normal");
            }
            return;
        }
        if (eq(name, "Category")) {
            w.variant("s");
            w.string("ApplicationStatus");
        } else if (eq(name, "Id")) {
            w.variant("s");
            w.string("annotation-helper");
        } else if (eq(name, "Title")) {
            w.variant("s");
            w.string("annotation-helper");
        } else if (eq(name, "Status")) {
            w.variant("s");
            w.string("Active");
        } else if (eq(name, "WindowId")) {
            w.variant("i");
            w.int32(0);
        } else if (eq(name, "IconPixmap")) {
            w.variant("a(iiay)");
            t.writePixmaps(w);
        } else if (eq(name, "ToolTip")) {
            w.variant("(sa(iiay)ss)");
            w.beginStruct();
            w.string("");
            t.writePixmaps(w);
            w.string("annotation-helper");
            w.string(t.tooltip[0..t.tooltip_len]);
        } else if (eq(name, "ItemIsMenu")) {
            w.variant("b");
            w.boolean(true);
        } else if (eq(name, "Menu")) {
            w.variant("o");
            w.objectPath(MENU_PATH);
        } else {
            w.variant("s");
            w.string("");
        }
    }

    fn writePixmaps(t: *Tray, w: *Writer) void {
        const arr = w.beginArray(8);
        const set = t.icons[@intFromBool(t.recording)];
        for (set, [_]i32{ 22, 32, 48 }) |px, size| {
            w.beginStruct();
            w.int32(size);
            w.int32(size);
            w.uint32(@intCast(px.len));
            w.buf.appendSlice(w.a, px) catch {
                w.oom = true;
            };
        }
        w.endArray(arr);
    }

    fn replyEmpty(t: *Tray, m: *const Message) void {
        if (m.flags & dbus.NO_REPLY != 0) return;
        var o = t.bus.methodReturn(m);
        defer o.deinit();
        _ = t.bus.send(&o) catch {};
    }

    fn replyString(t: *Tray, m: *const Message, s: []const u8) void {
        var o = t.bus.methodReturn(m);
        defer o.deinit();
        o.sig = "s";
        o.body.string(s);
        _ = t.bus.send(&o) catch {};
    }
};

/// Same icon as on Windows: a blue round badge with a pen stroke; recording adds a red
/// dot. Returned as ARGB32 in network byte order (what StatusNotifierItem wants).
fn makeIcon(size: i32, rec: bool) ![]u8 {
    const n: usize = @intCast(size * size);
    const px = try util.gpa.alloc(raster.Bgra, n);
    defer util.gpa.free(px);
    @memset(px, .{ .b = 0, .g = 0, .r = 0, .a = 0 });
    const k = @as(f32, @floatFromInt(size)) / 32;
    const c = raster.Canvas{ .px = px, .w = size, .h = size };
    raster.disc(util.gpa, c, 16 * k, 16 * k, 15 * k, .{ 0x1e, 0x5a, 0xb0 }, 255);
    raster.line(util.gpa, c, .{ 9 * k, 23 * k }, .{ 22 * k, 10 * k }, 2.5 * k, .{ 255, 255, 255 }, 255);
    if (rec) {
        raster.disc(util.gpa, c, 24 * k, 24 * k, 7.5 * k, .{ 255, 255, 255 }, 255);
        raster.disc(util.gpa, c, 24 * k, 24 * k, 5.8 * k, .{ 230, 34, 34 }, 255);
    }
    const out = try util.gpa.alloc(u8, n * 4);
    for (px, 0..) |p, i| {
        // Un-premultiply.
        const a: u32 = p.a;
        const un = struct {
            fn f(v: u8, al: u32) u8 {
                return if (al == 0) 0 else @intCast(@min(255, (@as(u32, v) * 255 + al / 2) / al));
            }
        }.f;
        out[i * 4 + 0] = p.a;
        out[i * 4 + 1] = un(p.r, a);
        out[i * 4 + 2] = un(p.g, a);
        out[i * 4 + 3] = un(p.b, a);
    }
    return out;
}

const ITEM_XML =
    \\<node><interface name="org.kde.StatusNotifierItem">
    \\<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
    \\<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
    \\<property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
    \\<property name="IconPixmap" type="a(iiay)" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
    \\<method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\<method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\<method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\<method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    \\<signal name="NewIcon"/><signal name="NewToolTip"/><signal name="NewStatus"><arg name="status" type="s"/></signal>
    \\</interface></node>
;

const MENU_XML =
    \\<node><interface name="com.canonical.dbusmenu">
    \\<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
    \\<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
    \\<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
    \\<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
    \\<method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
    \\<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
    \\<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
    \\<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
    \\<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
    \\<signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
    \\<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
    \\</interface></node>
;
