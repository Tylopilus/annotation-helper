//! Minimal D-Bus client (wire protocol over a unix socket, SASL EXTERNAL auth).
//! Used for the tray icon (StatusNotifierItem + dbusmenu), notifications, the desktop
//! portals (screenshot, global shortcuts), AT-SPI and single-instance control.
//! A connection belongs to one thread.

const std = @import("std");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;

pub const MsgType = enum(u8) { invalid = 0, call = 1, ret = 2, err = 3, signal = 4 };
pub const NO_REPLY = 0x1;

// ------------------------------------------------------------------ marshalling

pub const Writer = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,
    oom: bool = false,

    pub fn init(a: Allocator) Writer {
        return .{ .a = a };
    }
    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.a);
    }
    fn bytes(w: *Writer, b: []const u8) void {
        w.buf.appendSlice(w.a, b) catch {
            w.oom = true;
        };
    }
    pub fn pad(w: *Writer, n: usize) void {
        while (w.buf.items.len % n != 0) w.bytes(&.{0});
    }
    pub fn byte(w: *Writer, v: u8) void {
        w.bytes(&.{v});
    }
    pub fn boolean(w: *Writer, v: bool) void {
        w.uint32(@intFromBool(v));
    }
    pub fn int32(w: *Writer, v: i32) void {
        w.uint32(@bitCast(v));
    }
    pub fn uint32(w: *Writer, v: u32) void {
        w.pad(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        w.bytes(&b);
    }
    pub fn int64(w: *Writer, v: i64) void {
        w.uint64(@bitCast(v));
    }
    pub fn uint64(w: *Writer, v: u64) void {
        w.pad(8);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        w.bytes(&b);
    }
    pub fn string(w: *Writer, s: []const u8) void {
        w.uint32(@intCast(s.len));
        w.bytes(s);
        w.byte(0);
    }
    pub const objectPath = string;
    pub fn signature(w: *Writer, s: []const u8) void {
        w.byte(@intCast(s.len));
        w.bytes(s);
        w.byte(0);
    }
    pub const Mark = struct { len_pos: usize, start: usize };
    /// `elem_align`: 8 for structs/dict entries/64-bit, 4 for strings/ints, 1 for bytes.
    pub fn beginArray(w: *Writer, elem_align: usize) Mark {
        w.uint32(0);
        const len_pos = w.buf.items.len - 4;
        w.pad(elem_align);
        return .{ .len_pos = len_pos, .start = w.buf.items.len };
    }
    pub fn endArray(w: *Writer, m: Mark) void {
        if (w.oom) return;
        std.mem.writeInt(u32, w.buf.items[m.len_pos..][0..4], @intCast(w.buf.items.len - m.start), .little);
    }
    pub fn beginStruct(w: *Writer) void {
        w.pad(8);
    }
    /// Writes the variant's signature; the caller then writes one value of that type.
    pub fn variant(w: *Writer, sig: []const u8) void {
        w.signature(sig);
    }
    // Convenience for a{sv} dictionaries.
    pub fn dictEntryStr(w: *Writer, key: []const u8, val: []const u8) void {
        w.beginStruct();
        w.string(key);
        w.variant("s");
        w.string(val);
    }
    pub fn dictEntryBool(w: *Writer, key: []const u8, val: bool) void {
        w.beginStruct();
        w.string(key);
        w.variant("b");
        w.boolean(val);
    }
    pub fn dictEntryU32(w: *Writer, key: []const u8, val: u32) void {
        w.beginStruct();
        w.string(key);
        w.variant("u");
        w.uint32(val);
    }
    pub fn dictEntryI32(w: *Writer, key: []const u8, val: i32) void {
        w.beginStruct();
        w.string(key);
        w.variant("i");
        w.int32(val);
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn alignTo(r: *Reader, n: usize) !void {
        r.pos = std.mem.alignForward(usize, r.pos, n);
        if (r.pos > r.data.len) return error.Truncated;
    }
    fn take(r: *Reader, n: usize) ![]const u8 {
        if (r.pos + n > r.data.len) return error.Truncated;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }
    pub fn byte(r: *Reader) !u8 {
        return (try r.take(1))[0];
    }
    pub fn boolean(r: *Reader) !bool {
        return try r.uint32() != 0;
    }
    pub fn uint32(r: *Reader) !u32 {
        try r.alignTo(4);
        return std.mem.readInt(u32, (try r.take(4))[0..4], .little);
    }
    pub fn int32(r: *Reader) !i32 {
        return @bitCast(try r.uint32());
    }
    pub fn uint64(r: *Reader) !u64 {
        try r.alignTo(8);
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }
    pub fn string(r: *Reader) ![]const u8 {
        const n = try r.uint32();
        const s = try r.take(n);
        _ = try r.take(1);
        return s;
    }
    pub const objectPath = string;
    pub fn signature(r: *Reader) ![]const u8 {
        const n = try r.byte();
        const s = try r.take(n);
        _ = try r.take(1);
        return s;
    }
    /// Returns the end position of the array; read elements while `r.pos < end`.
    pub fn beginArray(r: *Reader, elem_align: usize) !usize {
        const n = try r.uint32();
        try r.alignTo(elem_align);
        if (r.pos + n > r.data.len) return error.Truncated;
        return r.pos + n;
    }
    pub fn beginStruct(r: *Reader) !void {
        try r.alignTo(8);
    }

    /// Skips one complete value of type `sig[0..]`; returns the rest of the signature.
    pub fn skip(r: *Reader, sig: []const u8) ![]const u8 {
        if (sig.len == 0) return error.BadSignature;
        switch (sig[0]) {
            'y' => _ = try r.byte(),
            'b', 'i', 'u', 'h' => _ = try r.uint32(),
            'n', 'q' => {
                try r.alignTo(2);
                _ = try r.take(2);
            },
            'x', 't', 'd' => _ = try r.uint64(),
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                const vs = try r.signature();
                _ = try r.skip(vs);
            },
            'a' => {
                const elem_end = try singleTypeEnd(sig[1..]);
                const end = try r.beginArray(alignOf(sig[1]));
                r.pos = end;
                return sig[1 + elem_end ..];
            },
            '(', '{' => {
                try r.alignTo(8);
                const close: u8 = if (sig[0] == '(') ')' else '}';
                var rest = sig[1..];
                while (rest.len > 0 and rest[0] != close) rest = try r.skip(rest);
                if (rest.len == 0) return error.BadSignature;
                return rest[1..];
            },
            else => return error.BadSignature,
        }
        return sig[1..];
    }

    /// Reads a variant holding a string (or object path); null for other types.
    pub fn variantString(r: *Reader) !?[]const u8 {
        const vs = try r.signature();
        if (std.mem.eql(u8, vs, "s") or std.mem.eql(u8, vs, "o")) return try r.string();
        _ = try r.skip(vs);
        return null;
    }
    pub fn variantU32(r: *Reader) !?u32 {
        const vs = try r.signature();
        if (std.mem.eql(u8, vs, "u") or std.mem.eql(u8, vs, "i")) return try r.uint32();
        _ = try r.skip(vs);
        return null;
    }
};

fn alignOf(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        else => 8, // x t d ( {
    };
}

/// Length of the first complete type in `sig`.
fn singleTypeEnd(sig: []const u8) !usize {
    if (sig.len == 0) return error.BadSignature;
    switch (sig[0]) {
        'a' => return 1 + try singleTypeEnd(sig[1..]),
        '(', '{' => {
            const close: u8 = if (sig[0] == '(') ')' else '}';
            var i: usize = 1;
            while (i < sig.len and sig[i] != close) i += try singleTypeEnd(sig[i..]);
            if (i >= sig.len) return error.BadSignature;
            return i + 1;
        },
        else => return 1,
    }
}

// ------------------------------------------------------------------ messages

pub const Message = struct {
    type: MsgType = .invalid,
    flags: u8 = 0,
    serial: u32 = 0,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    iface: []const u8 = "",
    member: []const u8 = "",
    err_name: []const u8 = "",
    dest: []const u8 = "",
    sender: []const u8 = "",
    sig: []const u8 = "",
    body: []const u8 = "",
    /// Owns all slices above.
    raw: []u8 = &.{},

    pub fn reader(m: *const Message) Reader {
        return .{ .data = m.body };
    }
    pub fn deinit(m: *Message, a: Allocator) void {
        a.free(m.raw);
        m.raw = &.{};
    }
    pub fn is(m: *const Message, iface: []const u8, member: []const u8) bool {
        return std.mem.eql(u8, m.iface, iface) and std.mem.eql(u8, m.member, member);
    }
    /// First string argument of an error reply (its message).
    pub fn errorText(m: *const Message) []const u8 {
        if (m.sig.len == 0 or m.sig[0] != 's') return m.err_name;
        var r = m.reader();
        return r.string() catch m.err_name;
    }
};

/// Total message length once its 16-byte fixed header is available.
fn messageLength(hdr: []const u8) !usize {
    if (hdr[0] != 'l') return error.BigEndianUnsupported;
    const body_len = std.mem.readInt(u32, hdr[4..8], .little);
    const fields_len = std.mem.readInt(u32, hdr[12..16], .little);
    return std.mem.alignForward(usize, 16 + fields_len, 8) + body_len;
}

fn parse(raw: []u8) !Message {
    var m = Message{ .raw = raw };
    m.type = std.enums.fromInt(MsgType, raw[1]) orelse .invalid;
    m.flags = raw[2];
    const body_len = std.mem.readInt(u32, raw[4..8], .little);
    m.serial = std.mem.readInt(u32, raw[8..12], .little);
    var r = Reader{ .data = raw, .pos = 12 };
    const end = try r.beginArray(8);
    while (r.pos < end) {
        try r.beginStruct();
        const code = try r.byte();
        const vs = try r.signature();
        switch (code) {
            1 => m.path = try r.string(),
            2 => m.iface = try r.string(),
            3 => m.member = try r.string(),
            4 => m.err_name = try r.string(),
            5 => m.reply_serial = try r.uint32(),
            6 => m.dest = try r.string(),
            7 => m.sender = try r.string(),
            8 => m.sig = try r.signature(),
            else => _ = try r.skip(vs),
        }
    }
    r.pos = std.mem.alignForward(usize, end, 8);
    if (r.pos + body_len > raw.len) return error.Truncated;
    m.body = raw[r.pos..][0..body_len];
    return m;
}

/// An outgoing message: fill in the header fields and write the body, then `send`.
pub const Out = struct {
    type: MsgType = .call,
    flags: u8 = 0,
    path: []const u8 = "",
    iface: []const u8 = "",
    member: []const u8 = "",
    dest: []const u8 = "",
    err_name: []const u8 = "",
    reply_serial: u32 = 0,
    sig: []const u8 = "",
    body: Writer,

    pub fn deinit(o: *Out) void {
        o.body.deinit();
    }
};

fn encode(a: Allocator, o: *const Out, serial: u32) ![]u8 {
    if (o.body.oom) return error.OutOfMemory;
    var w = Writer.init(a);
    errdefer w.deinit();
    w.byte('l');
    w.byte(@intFromEnum(o.type));
    w.byte(o.flags);
    w.byte(1);
    w.uint32(@intCast(o.body.buf.items.len));
    w.uint32(serial);
    const m = w.beginArray(8);
    const Field = struct { code: u8, sig: []const u8, val: []const u8 };
    const fields = [_]Field{
        .{ .code = 1, .sig = "o", .val = o.path },
        .{ .code = 2, .sig = "s", .val = o.iface },
        .{ .code = 3, .sig = "s", .val = o.member },
        .{ .code = 4, .sig = "s", .val = o.err_name },
        .{ .code = 6, .sig = "s", .val = o.dest },
    };
    for (fields) |f| if (f.val.len > 0) {
        w.beginStruct();
        w.byte(f.code);
        w.variant(f.sig);
        w.string(f.val);
    };
    if (o.reply_serial != 0) {
        w.beginStruct();
        w.byte(5);
        w.variant("u");
        w.uint32(o.reply_serial);
    }
    if (o.sig.len > 0) {
        w.beginStruct();
        w.byte(8);
        w.variant("g");
        w.signature(o.sig);
    }
    w.endArray(m);
    w.pad(8);
    w.bytes(o.body.buf.items);
    if (w.oom) return error.OutOfMemory;
    return w.buf.toOwnedSlice(a);
}

// ------------------------------------------------------------------ connection

pub const Conn = struct {
    a: Allocator,
    fd: sys.fd_t,
    serial: u32 = 0,
    unique_name: []u8 = &.{},
    rbuf: std.ArrayList(u8) = .empty,
    /// Messages read while waiting for something else; handed out by `next`.
    queue: std.ArrayList(Message) = .empty,

    /// The session bus ($DBUS_SESSION_BUS_ADDRESS or $XDG_RUNTIME_DIR/bus).
    pub fn session(a: Allocator) !*Conn {
        if (sys.env("DBUS_SESSION_BUS_ADDRESS")) |addr| return open(a, addr);
        const rt = sys.env("XDG_RUNTIME_DIR") orelse return error.NoSessionBus;
        var buf: [512]u8 = undefined;
        return open(a, std.fmt.bufPrint(&buf, "unix:path={s}/bus", .{rt}) catch return error.NoSessionBus);
    }

    /// Connects to a D-Bus address (`unix:path=…` or `unix:abstract=…`, `;`-separated).
    pub fn open(a: Allocator, address: []const u8) !*Conn {
        var it = std.mem.splitScalar(u8, address, ';');
        while (it.next()) |one| {
            if (!std.mem.startsWith(u8, one, "unix:")) continue;
            var kv = std.mem.splitScalar(u8, one["unix:".len..], ',');
            while (kv.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                const key = pair[0..eq];
                var pbuf: [256]u8 = undefined;
                const val = unescape(&pbuf, pair[eq + 1 ..]);
                const abstract = std.mem.eql(u8, key, "abstract");
                if (!abstract and !std.mem.eql(u8, key, "path")) continue;
                const fd = sys.connectUnix(val, abstract) catch continue;
                const c = try a.create(Conn);
                c.* = .{ .a = a, .fd = fd };
                c.handshake() catch |e| {
                    c.close();
                    return e;
                };
                return c;
            }
        }
        return error.ConnectFailed;
    }

    fn handshake(c: *Conn) !void {
        var uid_buf: [16]u8 = undefined;
        const uid = try std.fmt.bufPrint(&uid_buf, "{d}", .{sys.getuid()});
        var line: [128]u8 = undefined;
        var n: usize = 0;
        line[0] = 0;
        n = 1;
        const head = "AUTH EXTERNAL ";
        @memcpy(line[n..][0..head.len], head);
        n += head.len;
        for (uid) |ch| {
            _ = std.fmt.bufPrint(line[n..][0..2], "{x:0>2}", .{ch}) catch unreachable;
            n += 2;
        }
        @memcpy(line[n..][0..2], "\r\n");
        n += 2;
        try sys.writeAll(c.fd, line[0..n]);
        var resp: [256]u8 = undefined;
        var got: usize = 0;
        while (std.mem.indexOf(u8, resp[0..got], "\r\n") == null) {
            if (!sys.waitReadable(c.fd, 5000)) return error.AuthTimeout;
            const r = sys.recv(c.fd, resp[got..].ptr, resp.len - got, 0);
            if (r <= 0) return error.AuthFailed;
            got += @intCast(r);
        }
        if (!std.mem.startsWith(u8, resp[0..got], "OK ")) return error.AuthRejected;
        try sys.writeAll(c.fd, "BEGIN\r\n");
        var o = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello");
        defer o.deinit();
        var rep = try c.callWait(&o, 5000);
        defer rep.deinit(c.a);
        var rd = rep.reader();
        c.unique_name = try c.a.dupe(u8, try rd.string());
    }

    pub fn close(c: *Conn) void {
        _ = sys.close(c.fd);
        for (c.queue.items) |*m| m.deinit(c.a);
        c.queue.deinit(c.a);
        c.rbuf.deinit(c.a);
        c.a.free(c.unique_name);
        c.a.destroy(c);
    }

    /// A method call to fill and send.
    pub fn call(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8) Out {
        return .{ .dest = dest, .path = path, .iface = iface, .member = member, .body = Writer.init(c.a) };
    }

    pub fn signal(c: *Conn, path: []const u8, iface: []const u8, member: []const u8) Out {
        return .{ .type = .signal, .path = path, .iface = iface, .member = member, .body = Writer.init(c.a) };
    }

    pub fn methodReturn(c: *Conn, to: *const Message) Out {
        return .{ .type = .ret, .reply_serial = to.serial, .dest = to.sender, .body = Writer.init(c.a) };
    }

    /// Sends; returns the serial.
    pub fn send(c: *Conn, o: *const Out) !u32 {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        const bytes = try encode(c.a, o, c.serial);
        defer c.a.free(bytes);
        try sys.writeAll(c.fd, bytes);
        return c.serial;
    }

    pub fn replyError(c: *Conn, to: *const Message, name: []const u8, text: []const u8) void {
        if (to.flags & NO_REPLY != 0) return;
        var o = Out{ .type = .err, .reply_serial = to.serial, .dest = to.sender, .err_name = name, .sig = "s", .body = Writer.init(c.a) };
        defer o.deinit();
        o.body.string(text);
        _ = c.send(&o) catch {};
    }

    /// Sends and waits for the reply; other messages are queued. D-Bus errors become
    /// `error.DBusError` (the error message is logged by the caller via `last_error`).
    pub fn callWait(c: *Conn, o: *const Out, timeout_ms: u32) !Message {
        const serial = try c.send(o);
        const deadline = nowMs() + timeout_ms;
        while (true) {
            // Already queued?
            for (c.queue.items, 0..) |m, i| if ((m.type == .ret or m.type == .err) and m.reply_serial == serial) {
                var rep = c.queue.orderedRemove(i);
                if (rep.type == .err) {
                    setLastError(rep.err_name, rep.errorText());
                    rep.deinit(c.a);
                    return error.DBusError;
                }
                return rep;
            };
            const now = nowMs();
            if (now >= deadline) return error.Timeout;
            if (!sys.waitReadable(c.fd, @intCast(deadline - now))) return error.Timeout;
            try c.fill();
        }
    }

    /// Waits for a signal accepted by `pred` (others are queued), up to `timeout_ms`.
    pub fn waitSignal(c: *Conn, ctx: anytype, comptime pred: fn (@TypeOf(ctx), *const Message) bool, timeout_ms: u32) !Message {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            for (c.queue.items, 0..) |*m, i| if (m.type == .signal and pred(ctx, m)) return c.queue.orderedRemove(i);
            const now = nowMs();
            if (now >= deadline) return error.Timeout;
            if (!sys.waitReadable(c.fd, @intCast(@min(deadline - now, 1000)))) continue;
            try c.fill();
        }
    }

    /// Reads what the socket has (call when poll says readable) into the queue.
    pub fn fill(c: *Conn) !void {
        var chunk: [16384]u8 = undefined;
        const n = sys.recv(c.fd, &chunk, chunk.len, 0x40); // MSG_DONTWAIT
        if (n == 0) return error.Disconnected;
        if (n < 0) {
            if (sys.errno() == sys.EAGAIN or sys.errno() == sys.EINTR) return;
            return error.Disconnected;
        }
        try c.rbuf.appendSlice(c.a, chunk[0..@intCast(n)]);
        while (c.rbuf.items.len >= 16) {
            const total = try messageLength(c.rbuf.items[0..16]);
            if (c.rbuf.items.len < total) break;
            const raw = try c.a.dupe(u8, c.rbuf.items[0..total]);
            c.rbuf.replaceRange(c.a, 0, total, &.{}) catch unreachable;
            const m = parse(raw) catch {
                c.a.free(raw);
                continue;
            };
            try c.queue.append(c.a, m);
        }
    }

    /// Next queued message (caller deinits), or null.
    pub fn next(c: *Conn) ?Message {
        if (c.queue.items.len == 0) return null;
        return c.queue.orderedRemove(0);
    }

    // ---- bus helpers

    pub fn addMatch(c: *Conn, rule: []const u8) void {
        var o = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch");
        defer o.deinit();
        o.sig = "s";
        o.body.string(rule);
        var rep = c.callWait(&o, 3000) catch return;
        rep.deinit(c.a);
    }

    /// RequestName with DO_NOT_QUEUE; true if we are now the primary owner.
    pub fn requestName(c: *Conn, name: []const u8) !bool {
        var o = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName");
        defer o.deinit();
        o.sig = "su";
        o.body.string(name);
        o.body.uint32(4);
        var rep = try c.callWait(&o, 3000);
        defer rep.deinit(c.a);
        var r = rep.reader();
        return try r.uint32() == 1;
    }

    pub fn nameHasOwner(c: *Conn, name: []const u8) bool {
        var o = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner");
        defer o.deinit();
        o.sig = "s";
        o.body.string(name);
        var rep = c.callWait(&o, 3000) catch return false;
        defer rep.deinit(c.a);
        var r = rep.reader();
        return r.boolean() catch false;
    }

    pub fn connectionPid(c: *Conn, name: []const u8) ?u32 {
        var o = c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID");
        defer o.deinit();
        o.sig = "s";
        o.body.string(name);
        var rep = c.callWait(&o, 1500) catch return null;
        defer rep.deinit(c.a);
        var r = rep.reader();
        return r.uint32() catch null;
    }

    /// Get a property; the returned message's reader is positioned at the variant.
    pub fn getProperty(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8, timeout_ms: u32) !Message {
        var o = c.call(dest, path, "org.freedesktop.DBus.Properties", "Get");
        defer o.deinit();
        o.sig = "ss";
        o.body.string(iface);
        o.body.string(name);
        return c.callWait(&o, timeout_ms);
    }
};

// Last D-Bus error (for log messages), per thread.
threadlocal var last_err_buf: [256]u8 = undefined;
threadlocal var last_err_len: usize = 0;

fn setLastError(name: []const u8, text: []const u8) void {
    const s = std.fmt.bufPrint(&last_err_buf, "{s}: {s}", .{ name, text }) catch last_err_buf[0..];
    last_err_len = s.len;
}

pub fn lastError() []const u8 {
    return last_err_buf[0..last_err_len];
}

fn unescape(buf: []u8, s: []const u8) []const u8 {
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

fn nowMs() u64 {
    var ts: sys.Timespec = undefined;
    _ = sys.clock_gettime(sys.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Object path for a portal request: /org/freedesktop/portal/desktop/request/SENDER/TOKEN.
pub fn portalRequestPath(buf: []u8, unique_name: []const u8, token: []const u8) []const u8 {
    var n: usize = 0;
    const head = "/org/freedesktop/portal/desktop/request/";
    @memcpy(buf[0..head.len], head);
    n = head.len;
    const name = if (unique_name.len > 0 and unique_name[0] == ':') unique_name[1..] else unique_name;
    for (name) |ch| {
        buf[n] = if (ch == '.') '_' else ch;
        n += 1;
    }
    buf[n] = '/';
    n += 1;
    @memcpy(buf[n..][0..token.len], token);
    return buf[0 .. n + token.len];
}

test "marshal roundtrip" {
    const a = std.testing.allocator;
    var w = Writer.init(a);
    defer w.deinit();
    w.byte(7);
    w.string("hello");
    const m = w.beginArray(8);
    w.dictEntryStr("k", "v");
    w.dictEntryBool("b", true);
    w.endArray(m);
    w.uint64(42);
    var r = Reader{ .data = w.buf.items };
    try std.testing.expectEqual(@as(u8, 7), try r.byte());
    try std.testing.expectEqualStrings("hello", try r.string());
    const rest = try r.skip("a{sv}t");
    try std.testing.expectEqualStrings("t", rest);
    try std.testing.expectEqual(@as(u64, 42), try r.uint64());
}
