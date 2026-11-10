//! Desktop services over D-Bus: the Screenshot and GlobalShortcuts portals,
//! notifications, and showing files in the file manager.

const std = @import("std");
const dbus = @import("dbus.zig");
const sys = @import("sys.zig");
const util = @import("../util.zig");
const raster = @import("../raster.zig");

const Allocator = std.mem.Allocator;
const Message = dbus.Message;

/// D-Bus name and application id (also the .desktop file name).
pub const APP_ID = "dev.annotationhelper.AnnotationHelper";
const PORTAL = "org.freedesktop.portal.Desktop";
const PORTAL_PATH = "/org/freedesktop/portal/desktop";

var token_counter: u32 = 0;

fn token(buf: []u8) []const u8 {
    token_counter += 1;
    return std.fmt.bufPrint(buf, "ah{d}_{d}", .{ sys.getpid(), token_counter }) catch "ah";
}

/// Tells the portal our app id (host apps; must come before other portal calls).
pub fn registerHostApp(bus: *dbus.Conn) void {
    var o = bus.call(PORTAL, PORTAL_PATH, "org.freedesktop.host.portal.Registry", "Register");
    defer o.deinit();
    o.sig = "sa{sv}";
    o.body.string(APP_ID);
    const m = o.body.beginArray(8);
    o.body.endArray(m);
    var rep = bus.callWait(&o, 2000) catch return;
    rep.deinit(bus.a);
}

const ResponseWait = struct { path: []const u8, path2: []const u8 };

fn isResponse(ctx: *ResponseWait, m: *const Message) bool {
    return m.is("org.freedesktop.portal.Request", "Response") and
        (std.mem.eql(u8, m.path, ctx.path) or std.mem.eql(u8, m.path, ctx.path2));
}

/// Calls a portal method that answers through a Request object; returns the Response
/// signal (caller deinits) after checking `response == 0`.
fn portalRequest(bus: *dbus.Conn, o: *dbus.Out, tok: []const u8, timeout_ms: u32) !Message {
    var pbuf: [256]u8 = undefined;
    const predicted = dbus.portalRequestPath(&pbuf, bus.unique_name, tok);
    var rule_buf: [400]u8 = undefined;
    const rule = std.fmt.bufPrint(&rule_buf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{predicted}) catch return error.NameTooLong;
    bus.addMatch(rule);
    var rep = try bus.callWait(o, 5000);
    defer rep.deinit(bus.a);
    var r = rep.reader();
    const handle = r.objectPath() catch predicted;
    var ctx = ResponseWait{ .path = predicted, .path2 = handle };
    var sig = try bus.waitSignal(&ctx, isResponse, timeout_ms);
    errdefer sig.deinit(bus.a);
    var sr = sig.reader();
    const code = try sr.uint32();
    if (code != 0) return if (code == 1) error.Cancelled else error.PortalFailed;
    return sig;
}

/// Finds key `want` in an a{sv} at the reader's position; leaves the reader at its value
/// (after the variant signature) and returns the value's signature.
fn findInDict(r: *dbus.Reader, want: []const u8) !?[]const u8 {
    const end = try r.beginArray(8);
    while (r.pos < end) {
        try r.beginStruct();
        const key = try r.string();
        const vs = try r.signature();
        if (std.mem.eql(u8, key, want)) return vs;
        _ = try r.skip(vs);
    }
    return null;
}

pub const Image = struct { px: []raster.Bgra, w: i32, h: i32 };

extern fn ah_png_load_bgra(path: [*:0]const u8, w: *c_int, h: *c_int) ?[*]raster.Bgra;
extern fn ah_png_free(p: ?*anyopaque) void;

/// Loads a PNG as BGRA (gpa-owned copy).
pub fn loadPng(path: []const u8) !Image {
    var zbuf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.NameTooLong;
    var w: c_int = 0;
    var h: c_int = 0;
    const p = ah_png_load_bgra(z.ptr, &w, &h) orelse return error.ImageDecode;
    defer ah_png_free(p);
    const n: usize = @intCast(w * h);
    return .{ .px = try util.gpa.dupe(raster.Bgra, p[0..n]), .w = w, .h = h };
}

/// Full-desktop screenshot through the Screenshot portal (no dialog for host apps on
/// most desktops; some ask once). The portal's file is deleted after loading.
pub fn screenshot(bus: *dbus.Conn) !Image {
    var tbuf: [32]u8 = undefined;
    const tok = token(&tbuf);
    var o = bus.call(PORTAL, PORTAL_PATH, "org.freedesktop.portal.Screenshot", "Screenshot");
    defer o.deinit();
    o.sig = "sa{sv}";
    o.body.string("");
    const m = o.body.beginArray(8);
    o.body.dictEntryStr("handle_token", tok);
    o.body.dictEntryBool("interactive", false);
    o.body.dictEntryBool("modal", false);
    o.body.endArray(m);
    var sig = try portalRequest(bus, &o, tok, 60_000);
    defer sig.deinit(bus.a);
    var r = sig.reader();
    _ = try r.uint32();
    const vs = (try findInDict(&r, "uri")) orelse return error.NoUri;
    if (!std.mem.eql(u8, vs, "s")) return error.NoUri;
    const uri = try r.string();
    var pbuf: [4096]u8 = undefined;
    const path = uriToPath(&pbuf, uri) orelse return error.NoUri;
    defer {
        var zb: [4096]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0)) |z| {
            _ = sys.unlink(z.ptr);
        } else |_| {}
    }
    return loadPng(path);
}

fn uriToPath(buf: []u8, uri: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const s = uri["file://".len..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            buf[n] = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch '%';
            i += 3;
        } else {
            buf[n] = s[i];
            i += 1;
        }
    }
    return buf[0..n];
}

// ------------------------------------------------------------------ global shortcuts

pub const Shortcut = struct { id: []const u8, description: []const u8, trigger: []const u8 };

pub const Shortcuts = struct {
    session: []u8,

    /// Creates a GlobalShortcuts session (KDE, GNOME 48+, Hyprland, …).
    pub fn create(bus: *dbus.Conn) !Shortcuts {
        var tbuf: [32]u8 = undefined;
        const tok = token(&tbuf);
        var sbuf: [32]u8 = undefined;
        const stok = token(&sbuf);
        bus.addMatch("type='signal',interface='org.freedesktop.portal.GlobalShortcuts',member='Activated'");
        var o = bus.call(PORTAL, PORTAL_PATH, "org.freedesktop.portal.GlobalShortcuts", "CreateSession");
        defer o.deinit();
        o.sig = "a{sv}";
        const m = o.body.beginArray(8);
        o.body.dictEntryStr("handle_token", tok);
        o.body.dictEntryStr("session_handle_token", stok);
        o.body.endArray(m);
        var sig = try portalRequest(bus, &o, tok, 30_000);
        defer sig.deinit(bus.a);
        var r = sig.reader();
        _ = try r.uint32();
        const vs = (try findInDict(&r, "session_handle")) orelse return error.NoSession;
        const handle = if (std.mem.eql(u8, vs, "s") or std.mem.eql(u8, vs, "o")) try r.string() else return error.NoSession;
        return .{ .session = try bus.a.dupe(u8, handle) };
    }

    /// Binds the shortcuts; the desktop may ask the user to confirm or pick keys.
    /// Returns the triggers the desktop actually assigned ("Ctrl+Alt+D"), in `a`.
    pub fn bind(s: Shortcuts, bus: *dbus.Conn, a: Allocator, list: []const Shortcut) ![]const []const u8 {
        var tbuf: [32]u8 = undefined;
        const tok = token(&tbuf);
        var o = bus.call(PORTAL, PORTAL_PATH, "org.freedesktop.portal.GlobalShortcuts", "BindShortcuts");
        defer o.deinit();
        o.sig = "oa(sa{sv})sa{sv}";
        o.body.objectPath(s.session);
        const arr = o.body.beginArray(8);
        for (list) |sc| {
            o.body.beginStruct();
            o.body.string(sc.id);
            const d = o.body.beginArray(8);
            o.body.dictEntryStr("description", sc.description);
            if (sc.trigger.len > 0) o.body.dictEntryStr("preferred_trigger", sc.trigger);
            o.body.endArray(d);
        }
        o.body.endArray(arr);
        o.body.string("");
        const opts = o.body.beginArray(8);
        o.body.dictEntryStr("handle_token", tok);
        o.body.endArray(opts);
        var sig = try portalRequest(bus, &o, tok, 120_000);
        defer sig.deinit(bus.a);
        var r = sig.reader();
        _ = try r.uint32();
        var out = try a.alloc([]const u8, list.len);
        for (out) |*x| x.* = "";
        const vs = (try findInDict(&r, "shortcuts")) orelse return out;
        if (!std.mem.eql(u8, vs, "a(sa{sv})")) return out;
        const end = try r.beginArray(8);
        while (r.pos < end) {
            try r.beginStruct();
            const id = try r.string();
            const dend = try r.beginArray(8);
            while (r.pos < dend) {
                try r.beginStruct();
                const key = try r.string();
                const ks = try r.signature();
                if (std.mem.eql(u8, key, "trigger_description") and std.mem.eql(u8, ks, "s")) {
                    const t = try r.string();
                    for (list, 0..) |sc, i| if (std.mem.eql(u8, sc.id, id)) {
                        out[i] = try a.dupe(u8, t);
                    };
                } else _ = try r.skip(ks);
            }
        }
        return out;
    }

    /// Opens the desktop's dialog for changing the shortcuts (portal version 2).
    pub fn configure(s: Shortcuts, bus: *dbus.Conn) bool {
        var o = bus.call(PORTAL, PORTAL_PATH, "org.freedesktop.portal.GlobalShortcuts", "ConfigureShortcuts");
        defer o.deinit();
        o.sig = "soa{sv}";
        o.body.string("");
        o.body.objectPath(s.session);
        const m = o.body.beginArray(8);
        o.body.endArray(m);
        var rep = bus.callWait(&o, 5000) catch return false;
        rep.deinit(bus.a);
        return true;
    }

    /// For an `Activated` signal: the shortcut id (and an activation token, if any).
    pub fn activated(s: Shortcuts, m: *const Message) ?struct { id: []const u8, token: ?[]const u8 } {
        if (!m.is("org.freedesktop.portal.GlobalShortcuts", "Activated")) return null;
        var r = m.reader();
        const session = r.objectPath() catch return null;
        if (!std.mem.eql(u8, session, s.session)) return null;
        const id = r.string() catch return null;
        _ = r.uint64() catch return null;
        var tok: ?[]const u8 = null;
        if (findInDict(&r, "activation_token") catch null) |vs| {
            if (std.mem.eql(u8, vs, "s")) tok = r.string() catch null;
        }
        return .{ .id = id, .token = tok };
    }
};

// ------------------------------------------------------------------ notifications

/// Shows a desktop notification; returns its id (0 if no notification service).
pub fn notify(bus: *dbus.Conn, title: []const u8, body: []const u8, warning: bool, clickable: bool) u32 {
    var o = bus.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify");
    defer o.deinit();
    o.sig = "susssasa{sv}i";
    o.body.string("annotation-helper");
    o.body.uint32(0);
    o.body.string(if (warning) "dialog-warning" else "");
    o.body.string(title);
    o.body.string(body);
    const acts = o.body.beginArray(4);
    if (clickable) {
        o.body.string("default");
        o.body.string("Show files");
    }
    o.body.endArray(acts);
    const hints = o.body.beginArray(8);
    o.body.dictEntryStr("desktop-entry", APP_ID);
    if (warning) {
        o.body.beginStruct();
        o.body.string("urgency");
        o.body.variant("y");
        o.body.byte(2);
    }
    o.body.endArray(hints);
    o.body.int32(-1);
    var rep = bus.callWait(&o, 2000) catch return 0;
    defer rep.deinit(bus.a);
    var r = rep.reader();
    return r.uint32() catch 0;
}

/// For an `ActionInvoked` signal: the notification id.
pub fn notificationClicked(m: *const Message) ?u32 {
    if (!m.is("org.freedesktop.Notifications", "ActionInvoked")) return null;
    var r = m.reader();
    return r.uint32() catch null;
}

pub fn watchNotifications(bus: *dbus.Conn) void {
    bus.addMatch("type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'");
}

// ------------------------------------------------------------------ files

/// Shows `path` selected in the file manager (falls back to opening its folder).
pub fn reveal(bus: ?*dbus.Conn, path: []const u8) void {
    if (bus) |b| {
        var ubuf: [4200]u8 = undefined;
        if (fileUri(&ubuf, path)) |uri| {
            var o = b.call("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems");
            defer o.deinit();
            o.sig = "ass";
            const arr = o.body.beginArray(4);
            o.body.string(uri);
            o.body.endArray(arr);
            o.body.string("");
            if (b.callWait(&o, 3000)) |rep| {
                var r = rep;
                r.deinit(b.a);
                return;
            } else |_| {}
        }
    }
    openPath(std.fs.path.dirname(path) orelse path);
}

pub fn openPath(path: []const u8) void {
    if (!sys.spawnDetached(util.gpa, &.{ "xdg-open", path })) util.log("  could not run xdg-open {s}", .{path});
}

fn fileUri(buf: []u8, path: []const u8) ?[]const u8 {
    var n: usize = 0;
    const head = "file://";
    if (path.len * 3 + head.len > buf.len) return null;
    @memcpy(buf[0..head.len], head);
    n = head.len;
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-_.~", ch) != null) {
            buf[n] = ch;
            n += 1;
        } else {
            _ = std.fmt.bufPrint(buf[n..][0..3], "%{X:0>2}", .{ch}) catch return null;
            n += 3;
        }
    }
    return buf[0..n];
}

test "uri helpers" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/home/a b/x.png", uriToPath(&b, "file:///home/a%20b/x.png").?);
    var c: [128]u8 = undefined;
    try std.testing.expectEqualStrings("file:///home/a%20b", fileUri(&c, "/home/a b").?);
}
