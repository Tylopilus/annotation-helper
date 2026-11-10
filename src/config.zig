//! `config.json` next to the exe and hotkey parsing.

const std = @import("std");
const util = @import("util.zig");

pub const Hotkeys = struct {
    session: []const u8 = "Ctrl+Alt+R",
    draw: []const u8 = "Ctrl+Alt+D",
};

pub const Config = struct {
    hotkeys: Hotkeys = .{},
    language: ?[]const u8 = null,
    model: ?[]const u8 = null,
    sessions_dir: ?[]const u8 = null,
};

pub fn path(a: std.mem.Allocator) ![]u8 {
    const dir = try util.exeDir(a);
    defer a.free(dir);
    return util.join(a, &.{ dir, "config.json" });
}

/// Loaded config; strings live in `arena` until the process ends.
pub fn load(arena: std.mem.Allocator) struct { config: Config, warning: ?[]const u8 } {
    const p = path(arena) catch return .{ .config = .{}, .warning = null };
    const bytes = util.readFile(arena, p) catch return .{ .config = .{}, .warning = null };
    const c = std.json.parseFromSliceLeaky(Config, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .config = .{}, .warning = "config.json is invalid; using defaults" };
    return .{ .config = c, .warning = null };
}

pub fn save(c: Config) !void {
    const a = util.gpa;
    const p = try path(a);
    defer a.free(p);
    const json = try std.json.Stringify.valueAlloc(a, c, .{ .whitespace = .indent_2 });
    defer a.free(json);
    try util.writeFile(p, json);
}

pub fn sessionsDir(a: std.mem.Allocator, c: Config) ![]u8 {
    if (c.sessions_dir) |d| return a.dupe(u8, d);
    const dir = try util.exeDir(a);
    defer a.free(dir);
    return util.join(a, &.{ dir, "sessions" });
}

// ------------------------------------------------------------------ hotkeys

pub const MOD_ALT: u32 = 0x1;
pub const MOD_CONTROL: u32 = 0x2;
pub const MOD_SHIFT: u32 = 0x4;
pub const MOD_WIN: u32 = 0x8;

pub const Hotkey = struct {
    mods: u32,
    vk: u32,

    pub fn eql(a: Hotkey, b: Hotkey) bool {
        return a.mods == b.mods and a.vk == b.vk;
    }

    pub fn parse(s: []const u8) !Hotkey {
        var mods: u32 = 0;
        var vk: ?u32 = null;
        var it = std.mem.splitScalar(u8, s, '+');
        while (it.next()) |raw| {
            const part = std.mem.trim(u8, raw, " ");
            if (part.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
                mods |= MOD_CONTROL;
            } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
                mods |= MOD_ALT;
            } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
                mods |= MOD_SHIFT;
            } else if (std.ascii.eqlIgnoreCase(part, "win") or std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "meta")) {
                mods |= MOD_WIN;
            } else if (vk == null) {
                vk = keyFromName(part) orelse return error.UnknownKey;
            } else return error.MoreThanOneKey;
        }
        const hk = Hotkey{ .mods = mods, .vk = vk orelse return error.NoKey };
        try hk.validate();
        return hk;
    }

    /// A global hotkey must not swallow normal typing.
    pub fn validate(h: Hotkey) !void {
        if (h.vk == 0x1B) return error.EscReserved;
        const fkey = h.vk >= 0x70 and h.vk <= 0x87;
        if (h.mods & (MOD_CONTROL | MOD_ALT | MOD_WIN) == 0 and !fkey) return error.NeedsModifier;
    }

    pub fn label(h: Hotkey, buf: []u8) []const u8 {
        var n: usize = 0;
        for ([_]struct { u32, []const u8 }{ .{ MOD_CONTROL, "Ctrl+" }, .{ MOD_ALT, "Alt+" }, .{ MOD_SHIFT, "Shift+" }, .{ MOD_WIN, "Win+" } }) |m| {
            if (h.mods & m[0] != 0) {
                @memcpy(buf[n..][0..m[1].len], m[1]);
                n += m[1].len;
            }
        }
        const k = keyName(h.vk, buf[n..]);
        return buf[0 .. n + k.len];
    }
};

pub fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.EscReserved => "Esc is reserved for finishing a drawing",
        error.NeedsModifier => "needs Ctrl, Alt or Win (only F-keys work alone)",
        error.UnknownKey => "unknown key",
        error.MoreThanOneKey => "more than one key",
        error.NoKey => "no key",
        else => @errorName(e),
    };
}

const named = [_]struct { u32, []const u8 }{
    .{ 0x08, "Backspace" },   .{ 0x09, "Tab" },         .{ 0x0D, "Enter" },        .{ 0x13, "Pause" },
    .{ 0x20, "Space" },       .{ 0x21, "PageUp" },      .{ 0x22, "PageDown" },     .{ 0x23, "End" },
    .{ 0x24, "Home" },        .{ 0x25, "Left" },        .{ 0x26, "Up" },           .{ 0x27, "Right" },
    .{ 0x28, "Down" },        .{ 0x2C, "PrintScreen" }, .{ 0x2D, "Insert" },       .{ 0x2E, "Delete" },
    .{ 0x6A, "NumMultiply" }, .{ 0x6B, "NumAdd" },      .{ 0x6D, "NumSubtract" },  .{ 0x6E, "NumDecimal" },
    .{ 0x6F, "NumDivide" },   .{ 0xBA, "Semicolon" },   .{ 0xBB, "Plus" },         .{ 0xBC, "Comma" },
    .{ 0xBD, "Minus" },       .{ 0xBE, "Period" },      .{ 0xBF, "Slash" },        .{ 0xC0, "Backquote" },
    .{ 0xDB, "BracketLeft" }, .{ 0xDC, "Backslash" },   .{ 0xDD, "BracketRight" }, .{ 0xDE, "Quote" },
};

fn keyName(vk: u32, buf: []u8) []const u8 {
    if ((vk >= 0x30 and vk <= 0x39) or (vk >= 0x41 and vk <= 0x5A)) {
        buf[0] = @intCast(vk);
        return buf[0..1];
    }
    if (vk >= 0x60 and vk <= 0x69) return std.fmt.bufPrint(buf, "Num{d}", .{vk - 0x60}) catch "";
    if (vk >= 0x70 and vk <= 0x87) return std.fmt.bufPrint(buf, "F{d}", .{vk - 0x6F}) catch "";
    for (named) |e| if (e[0] == vk) {
        @memcpy(buf[0..e[1].len], e[1]);
        return buf[0..e[1].len];
    };
    return std.fmt.bufPrint(buf, "0x{X:0>2}", .{vk}) catch "";
}

fn keyFromName(name: []const u8) ?u32 {
    if (name.len == 1 and std.ascii.isAlphanumeric(name[0])) return std.ascii.toUpper(name[0]);
    if (name.len >= 2 and (name[0] == 'F' or name[0] == 'f')) {
        if (std.fmt.parseInt(u32, name[1..], 10)) |n| {
            if (n >= 1 and n <= 24) return 0x6F + n;
        } else |_| {}
    }
    if (name.len == 4 and std.ascii.startsWithIgnoreCase(name, "num") and std.ascii.isDigit(name[3])) return 0x60 + @as(u32, name[3] - '0');
    if (name.len > 2 and std.ascii.startsWithIgnoreCase(name, "0x")) return std.fmt.parseInt(u32, name[2..], 16) catch null;
    for (named) |e| if (std.ascii.eqlIgnoreCase(e[1], name)) return e[0];
    return null;
}

test "parse and label roundtrip" {
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "Ctrl+Alt+R", "Ctrl+Shift+F9", "Alt+Win+Space", "F13", "Ctrl+Alt+Num5", "Ctrl+Alt+Minus" }) |s| {
        try std.testing.expectEqualStrings(s, (try Hotkey.parse(s)).label(&buf));
    }
    const hk = try Hotkey.parse(" shift + ctrl + d ");
    try std.testing.expectEqual(MOD_SHIFT | MOD_CONTROL, hk.mods);
    try std.testing.expectEqualStrings("Ctrl+Shift+D", hk.label(&buf));
}

test "rejects unusable hotkeys" {
    try std.testing.expectError(error.NeedsModifier, Hotkey.parse("Shift+A"));
    try std.testing.expectError(error.NoKey, Hotkey.parse("Ctrl+Alt"));
    try std.testing.expectError(error.MoreThanOneKey, Hotkey.parse("Ctrl+A+B"));
    try std.testing.expectError(error.UnknownKey, Hotkey.parse("Ctrl+Escape"));
    try std.testing.expectError(error.UnknownKey, Hotkey.parse("Ctrl+Bogus"));
}
