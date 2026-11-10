//! Session data: the JSON shape of `session.json` and `transcript.json`.

const std = @import("std");

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn ltrb(l: i32, t: i32, r: i32, b: i32) Rect {
        return .{ .x = l, .y = t, .w = r - l, .h = b - t };
    }
    pub fn right(s: Rect) i32 {
        return s.x + s.w;
    }
    pub fn bottom(s: Rect) i32 {
        return s.y + s.h;
    }
    pub fn isEmpty(s: Rect) bool {
        return s.w <= 0 or s.h <= 0;
    }
    pub fn unite(s: Rect, o: Rect) Rect {
        if (s.isEmpty()) return o;
        if (o.isEmpty()) return s;
        return ltrb(@min(s.x, o.x), @min(s.y, o.y), @max(s.right(), o.right()), @max(s.bottom(), o.bottom()));
    }
    pub fn intersect(s: Rect, o: Rect) ?Rect {
        const r = ltrb(@max(s.x, o.x), @max(s.y, o.y), @min(s.right(), o.right()), @min(s.bottom(), o.bottom()));
        return if (r.isEmpty()) null else r;
    }
    pub fn inflate(s: Rect, d: i32) Rect {
        return ltrb(s.x - d, s.y - d, s.right() + d, s.bottom() + d);
    }
    pub fn offset(s: Rect, dx: i32, dy: i32) Rect {
        return .{ .x = s.x + dx, .y = s.y + dy, .w = s.w, .h = s.h };
    }
    pub fn contains(s: Rect, x: i32, y: i32) bool {
        return x >= s.x and y >= s.y and x < s.right() and y < s.bottom();
    }
    pub fn center(s: Rect) [2]i32 {
        return .{ s.x + @divTrunc(s.w, 2), s.y + @divTrunc(s.h, 2) };
    }
    pub fn bounding(points: []const [2]i32) Rect {
        if (points.len == 0) return .{};
        var l: i32 = std.math.maxInt(i32);
        var t: i32 = std.math.maxInt(i32);
        var r: i32 = std.math.minInt(i32);
        var b: i32 = std.math.minInt(i32);
        for (points) |p| {
            l = @min(l, p[0]);
            t = @min(t, p[1]);
            r = @max(r, p[0]);
            b = @max(b, p[1]);
        }
        return ltrb(l, t, r + 1, b + 1);
    }
};

pub const Tool = enum {
    pen,
    highlighter,
    rectangle,
    ellipse,
    arrow,

    pub fn label(t: Tool) []const u8 {
        return switch (t) {
            .pen => "freehand",
            .highlighter => "highlight",
            .rectangle => "rectangle",
            .ellipse => "ellipse",
            .arrow => "arrow",
        };
    }
};

pub const ColorName = enum {
    red,
    green,
    blue,
    yellow,

    pub fn rgb(c: ColorName) [3]u8 {
        return switch (c) {
            .red => .{ 235, 40, 40 },
            .green => .{ 30, 190, 70 },
            .blue => .{ 40, 110, 245 },
            .yellow => .{ 255, 210, 0 },
        };
    }
};

pub const UiElement = struct {
    name: []const u8 = "",
    control_type: []const u8 = "",
    automation_id: []const u8 = "",
    class_name: []const u8 = "",
    framework: []const u8 = "",
    process: []const u8 = "",
    window_title: []const u8 = "",
    rect: ?Rect = null,
    text_at_point: ?[]const u8 = null,
    ancestors: []const []const u8 = &.{},
};

pub const Target = struct {
    role: []const u8,
    point: [2]i32,
    element: ?UiElement = null,
};

pub const Stroke = struct {
    id: u32,
    tool: Tool,
    color: ColorName,
    t_start_ms: u64,
    t_end_ms: u64,
    points: []const [2]i32,
    bbox: Rect,
    image_bbox: ?Rect = null,
    crop: ?[]const u8 = null,
    targets: []const Target = &.{},
};

pub const WindowInfo = struct {
    title: []const u8 = "",
    process: []const u8 = "",
};

pub const Frame = struct {
    index: u32,
    t_start_ms: u64,
    t_end_ms: u64,
    foreground: ?WindowInfo = null,
    capture_rect: Rect,
    image: []const u8,
    clean_image: []const u8,
    strokes: []const Stroke = &.{},
};

pub const AudioInfo = struct {
    file: []const u8,
    sample_rate: u32,
    offset_ms: i64,
};

pub const Monitor = struct {
    rect: Rect,
    primary: bool,
};

pub const Session = struct {
    version: u32 = 1,
    id: []const u8,
    started_local: []const u8,
    duration_ms: u64 = 0,
    monitors: []const Monitor = &.{},
    frames: []const Frame = &.{},
    audio: ?AudioInfo = null,
};

pub const Segment = struct {
    t_start_ms: i64,
    t_end_ms: i64,
    text: []const u8,
};

pub const Transcript = struct {
    model: []const u8,
    language: ?[]const u8 = null,
    segments: []const Segment = &.{},
};

pub fn toJson(a: std.mem.Allocator, v: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
}

/// Parses into an arena owned by the result (`parsed.deinit()` frees everything).
pub fn fromJson(comptime T: type, a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
