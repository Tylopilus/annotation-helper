//! Key names are shared with the Windows build (`config.json` stores "Ctrl+Alt+D"), so
//! X11/xkb keysyms are mapped to the same virtual-key codes.

const std = @import("std");

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

const table = [_]struct { u32, u32 }{
    .{ 0xff1b, 0x1B }, .{ 0xff0d, 0x0D }, .{ 0xff8d, 0x0D }, .{ 0x0020, 0x20 }, .{ 0xff08, 0x08 },
    .{ 0xffff, 0x2E }, .{ 0xff09, 0x09 }, .{ 0xff63, 0x2D }, .{ 0xff50, 0x24 }, .{ 0xff57, 0x23 },
    .{ 0xff55, 0x21 }, .{ 0xff56, 0x22 }, .{ 0xff51, 0x25 }, .{ 0xff52, 0x26 }, .{ 0xff53, 0x27 },
    .{ 0xff54, 0x28 }, .{ 0xff13, 0x13 }, .{ 0xff61, 0x2C }, .{ 0x003b, 0xBA }, .{ 0x003d, 0xBB },
    .{ 0x002c, 0xBC }, .{ 0x002d, 0xBD }, .{ 0x002e, 0xBE }, .{ 0x002f, 0xBF }, .{ 0x0060, 0xC0 },
    .{ 0x005b, 0xDB }, .{ 0x005c, 0xDC }, .{ 0x005d, 0xDD }, .{ 0x0027, 0xDE }, .{ 0xffaa, 0x6A },
    .{ 0xffab, 0x6B }, .{ 0xffad, 0x6D }, .{ 0xffae, 0x6E }, .{ 0xffaf, 0x6F },
};

/// Keysym → Windows virtual-key code (0 = not mappable).
pub fn vkFromKeysym(ks: u32) u32 {
    if (ks >= 'a' and ks <= 'z') return ks - 32;
    if ((ks >= 'A' and ks <= 'Z') or (ks >= '0' and ks <= '9')) return ks;
    if (ks >= 0xffbe and ks <= 0xffd5) return 0x70 + (ks - 0xffbe); // F1..F24
    if (ks >= 0xffb0 and ks <= 0xffb9) return 0x60 + (ks - 0xffb0); // KP_0..9
    for (table) |e| if (e[0] == ks) return e[1];
    return 0;
}

/// Windows virtual-key code → keysym (for grabbing keys).
pub fn keysymFromVk(vk: u32) u32 {
    if (vk >= 'A' and vk <= 'Z') return vk + 32;
    if (vk >= '0' and vk <= '9') return vk;
    if (vk >= 0x70 and vk <= 0x87) return 0xffbe + (vk - 0x70);
    if (vk >= 0x60 and vk <= 0x69) return 0xffb0 + (vk - 0x60);
    for (table) |e| if (e[1] == vk) return e[0];
    return 0;
}

/// Modifier keysyms (Shift/Control/Alt/Super/Meta/Hyper, both sides, plus Caps/Num lock).
pub fn isModifierKeysym(ks: u32) bool {
    return (ks >= 0xffe1 and ks <= 0xffee) or ks == 0xff7f or ks == 0xfe03;
}

/// Trigger string for the GlobalShortcuts portal (XDG shortcut spec), e.g. "CTRL+ALT+d".
pub fn portalTrigger(buf: []u8, mods: u32, vk: u32) []const u8 {
    const config = @import("../config.zig");
    var n: usize = 0;
    for ([_]struct { u32, []const u8 }{ .{ config.MOD_CONTROL, "CTRL+" }, .{ config.MOD_ALT, "ALT+" }, .{ config.MOD_SHIFT, "SHIFT+" }, .{ config.MOD_WIN, "LOGO+" } }) |m| {
        if (mods & m[0] != 0) {
            @memcpy(buf[n..][0..m[1].len], m[1]);
            n += m[1].len;
        }
    }
    const ks = keysymFromVk(vk);
    const name: []const u8 = switch (ks) {
        0x20 => "space",
        0xff0d => "Return",
        0xff09 => "Tab",
        0xff08 => "BackSpace",
        0xffff => "Delete",
        0xff63 => "Insert",
        0xff50 => "Home",
        0xff57 => "End",
        0xff55 => "Page_Up",
        0xff56 => "Page_Down",
        0xff51 => "Left",
        0xff52 => "Up",
        0xff53 => "Right",
        0xff54 => "Down",
        0xff61 => "Print",
        0xff13 => "Pause",
        else => blk: {
            if (ks >= 0xffbe and ks <= 0xffd5) break :blk std.fmt.bufPrint(buf[n..], "F{d}", .{ks - 0xffbe + 1}) catch "";
            if (ks >= 0x20 and ks < 0x7f) {
                buf[n] = @intCast(ks);
                break :blk buf[n .. n + 1];
            }
            break :blk "";
        },
    };
    if (name.ptr != buf[n..].ptr) @memcpy(buf[n..][0..name.len], name);
    return buf[0 .. n + name.len];
}

/// evdev key code → keysym for a US layout (used only without libxkbcommon).
pub fn keysymFromEvdevUs(code: u32) u32 {
    const letters = [_]struct { u32, u8 }{
        .{ 16, 'q' }, .{ 17, 'w' }, .{ 18, 'e' }, .{ 19, 'r' }, .{ 20, 't' }, .{ 21, 'y' }, .{ 22, 'u' }, .{ 23, 'i' }, .{ 24, 'o' }, .{ 25, 'p' },
        .{ 30, 'a' }, .{ 31, 's' }, .{ 32, 'd' }, .{ 33, 'f' }, .{ 34, 'g' }, .{ 35, 'h' }, .{ 36, 'j' }, .{ 37, 'k' }, .{ 38, 'l' },
        .{ 44, 'z' }, .{ 45, 'x' }, .{ 46, 'c' }, .{ 47, 'v' }, .{ 48, 'b' }, .{ 49, 'n' }, .{ 50, 'm' },
    };
    for (letters) |l| if (l[0] == code) return l[1];
    if (code >= 2 and code <= 10) return '1' + (code - 2);
    if (code == 11) return '0';
    if (code >= 59 and code <= 68) return 0xffbe + (code - 59); // F1..F10
    return switch (code) {
        1 => 0xff1b,
        14 => 0xff08,
        15 => 0xff09,
        28, 96 => 0xff0d,
        57 => 0x20,
        111 => 0xffff,
        29, 97 => 0xffe3,
        42, 54 => 0xffe1,
        56, 100 => 0xffe9,
        125, 126 => 0xffeb,
        87 => 0xffc8,
        88 => 0xffc9,
        else => 0,
    };
}

test "keysym mapping" {
    try std.testing.expectEqual(@as(u32, 'D'), vkFromKeysym('d'));
    try std.testing.expectEqual(@as(u32, 0x1B), vkFromKeysym(0xff1b));
    try std.testing.expectEqual(@as(u32, 'd'), keysymFromVk('D'));
    try std.testing.expectEqual(@as(u32, 0xffc1), keysymFromVk(0x73)); // F4
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("CTRL+ALT+d", portalTrigger(&buf, 0x2 | 0x1, 'D'));
    try std.testing.expectEqualStrings("LOGO+F9", portalTrigger(&buf, 0x8, 0x78));
}
