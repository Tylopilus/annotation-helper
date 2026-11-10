//! libxkbcommon, loaded at runtime (present wherever Wayland is), to turn Wayland key
//! codes into layout-aware keysyms. Without it, a US layout is assumed.

const std = @import("std");
const sys = @import("sys.zig");
const keys = @import("keys.zig");

const Fns = struct {
    context_new: *const fn (c_int) callconv(.c) ?*anyopaque,
    keymap_new_from_string: *const fn (*anyopaque, [*:0]const u8, c_int, c_int) callconv(.c) ?*anyopaque,
    keymap_unref: *const fn (*anyopaque) callconv(.c) void,
    state_new: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    state_unref: *const fn (*anyopaque) callconv(.c) void,
    state_update_mask: *const fn (*anyopaque, u32, u32, u32, u32, u32, u32) callconv(.c) c_int,
    state_key_get_layout: *const fn (*anyopaque, u32) callconv(.c) u32,
    keymap_key_get_syms_by_level: *const fn (*anyopaque, u32, u32, u32, *?[*]const u32) callconv(.c) c_int,
    state_mod_name_is_active: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_int,
};

var fns: ?Fns = null;
var tried = false;

fn load() ?Fns {
    if (tried) return fns;
    tried = true;
    const h = sys.dlopen("libxkbcommon.so.0", sys.RTLD_NOW) orelse return null;
    var f: Fns = undefined;
    inline for (@typeInfo(Fns).@"struct".field_names) |name| {
        const sym = sys.dlsym(h, "xkb_" ++ name) orelse return null;
        @field(f, name) = @ptrCast(sym);
    }
    fns = f;
    return f;
}

pub const Keyboard = struct {
    ctx: ?*anyopaque = null,
    keymap: ?*anyopaque = null,
    state: ?*anyopaque = null,
    // Fallback modifier state (bit layout of the default xkb keymap).
    depressed: u32 = 0,

    /// Takes the keymap text sent by the compositor.
    pub fn setKeymap(k: *Keyboard, text: [:0]const u8) void {
        const f = load() orelse return;
        if (k.ctx == null) k.ctx = f.context_new(0);
        const ctx = k.ctx orelse return;
        const km = f.keymap_new_from_string(ctx, text.ptr, 1, 0) orelse return;
        const st = f.state_new(km) orelse {
            f.keymap_unref(km);
            return;
        };
        if (k.state) |s| f.state_unref(s);
        if (k.keymap) |m| f.keymap_unref(m);
        k.keymap = km;
        k.state = st;
    }

    pub fn updateMods(k: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        k.depressed = depressed;
        const f = fns orelse return;
        if (k.state) |s| _ = f.state_update_mask(s, depressed, latched, locked, 0, 0, group);
    }

    /// Unshifted keysym of an evdev key code (layout-aware with xkbcommon).
    pub fn keysym(k: *Keyboard, evdev: u32) u32 {
        const f = fns orelse return keys.keysymFromEvdevUs(evdev);
        const s = k.state orelse return keys.keysymFromEvdevUs(evdev);
        const km = k.keymap.?;
        const layout = f.state_key_get_layout(s, evdev + 8);
        var syms: ?[*]const u32 = null;
        const n = f.keymap_key_get_syms_by_level(km, evdev + 8, layout, 0, &syms);
        if (n > 0) if (syms) |p| return p[0];
        return 0;
    }

    pub fn mods(k: *Keyboard) keys.Mods {
        if (fns) |f| if (k.state) |s| {
            const eff = 8; // XKB_STATE_MODS_EFFECTIVE
            return .{
                .shift = f.state_mod_name_is_active(s, "Shift", eff) > 0,
                .ctrl = f.state_mod_name_is_active(s, "Control", eff) > 0,
                .alt = f.state_mod_name_is_active(s, "Mod1", eff) > 0,
                .super = f.state_mod_name_is_active(s, "Mod4", eff) > 0,
            };
        };
        return .{ .shift = k.depressed & 1 != 0, .ctrl = k.depressed & 4 != 0, .alt = k.depressed & 8 != 0, .super = k.depressed & 64 != 0 };
    }
};
