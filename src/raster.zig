//! Small anti-aliased rasterizer for annotations.
//! Shapes are rendered into a coverage mask (max-combined, so overlapping parts of one
//! stroke don't double-blend), then composited once in premultiplied BGRA.

const std = @import("std");
const model = @import("model.zig");
const Rect = model.Rect;
const Stroke = model.Stroke;

pub const Bgra = extern struct { b: u8, g: u8, r: u8, a: u8 };

/// A premultiplied BGRA buffer; `origin` is the absolute screen position of px[0].
pub const Canvas = struct {
    px: []Bgra,
    w: i32,
    h: i32,
    ox: i32 = 0,
    oy: i32 = 0,

    pub fn bounds(c: Canvas) Rect {
        return .{ .x = c.ox, .y = c.oy, .w = c.w, .h = c.h };
    }
};

/// Extra margin a stroke may paint beyond its points (width, arrow head, badge).
pub const MARGIN: i32 = 48;
const BADGE_R: f32 = 13.0;

pub fn width(tool: model.Tool) f32 {
    return switch (tool) {
        .pen => 4.0,
        .highlighter => 22.0,
        .rectangle, .ellipse => 4.0,
        .arrow => 5.0,
    };
}

pub fn isMeaningful(s: *const Stroke) bool {
    if (s.points.len == 0) return false;
    const a = s.points[0];
    const b = s.points[s.points.len - 1];
    const dx: i32 = @intCast(@abs(b[0] - a[0]));
    const dy: i32 = @intCast(@abs(b[1] - a[1]));
    return switch (s.tool) {
        .pen, .highlighter => true,
        .rectangle, .ellipse => dx >= 6 and dy >= 6,
        .arrow => @max(dx, dy) >= 12,
    };
}

pub fn bounds(s: *const Stroke) Rect {
    return Rect.bounding(s.points).inflate(MARGIN);
}

// ------------------------------------------------------------------ mask

const V = [2]f32;

/// Coverage mask over an absolute-coordinate rectangle.
const Mask = struct {
    cov: []u8,
    area: Rect,

    fn init(a: std.mem.Allocator, area: Rect) !Mask {
        const cov = try a.alloc(u8, @intCast(area.w * area.h));
        @memset(cov, 0);
        return .{ .cov = cov, .area = area };
    }

    fn put(m: *Mask, x: i32, y: i32, c: f32) void {
        const i: usize = @intCast((y - m.area.y) * m.area.w + (x - m.area.x));
        const v: u8 = @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255));
        if (v > m.cov[i]) m.cov[i] = v;
    }

    /// Round-capped thick segment (a "capsule").
    fn capsule(m: *Mask, a: V, b: V, r: f32) void {
        const box = Rect.ltrb(
            @intFromFloat(@floor(@min(a[0], b[0]) - r - 1)),
            @intFromFloat(@floor(@min(a[1], b[1]) - r - 1)),
            @intFromFloat(@ceil(@max(a[0], b[0]) + r + 1)),
            @intFromFloat(@ceil(@max(a[1], b[1]) + r + 1)),
        );
        const area = box.intersect(m.area) orelse return;
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len2 = dx * dx + dy * dy;
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            var x = area.x;
            while (x < area.right()) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5 - a[0];
                const py = @as(f32, @floatFromInt(y)) + 0.5 - a[1];
                const t = if (len2 > 0) std.math.clamp((px * dx + py * dy) / len2, 0, 1) else 0;
                const ex = px - t * dx;
                const ey = py - t * dy;
                const c = r + 0.5 - @sqrt(ex * ex + ey * ey);
                if (c > 0) m.put(x, y, c);
            }
        }
    }

    fn polyline(m: *Mask, pts: []const V, r: f32, closed: bool) void {
        if (pts.len == 0) return; // e.g. an arrow that hasn't left its start point yet
        if (pts.len == 1) return m.capsule(pts[0], pts[0], r);
        for (pts[0 .. pts.len - 1], pts[1..]) |p0, p1| m.capsule(p0, p1, r);
        if (closed and pts.len > 2) m.capsule(pts[pts.len - 1], pts[0], r);
    }

    /// Filled triangle with anti-aliased edges.
    fn triangle(m: *Mask, p: [3]V) void {
        const area0 = Rect.ltrb(
            @intFromFloat(@floor(@min(p[0][0], @min(p[1][0], p[2][0])) - 1)),
            @intFromFloat(@floor(@min(p[0][1], @min(p[1][1], p[2][1])) - 1)),
            @intFromFloat(@ceil(@max(p[0][0], @max(p[1][0], p[2][0])) + 1)),
            @intFromFloat(@ceil(@max(p[0][1], @max(p[1][1], p[2][1])) + 1)),
        );
        const area = area0.intersect(m.area) orelse return;
        const cross = (p[1][0] - p[0][0]) * (p[2][1] - p[0][1]) - (p[1][1] - p[0][1]) * (p[2][0] - p[0][0]);
        const sign: f32 = if (cross >= 0) 1 else -1;
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            var x = area.x;
            while (x < area.right()) : (x += 1) {
                const q = V{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                var d: f32 = std.math.inf(f32);
                for (0..3) |i| {
                    const a = p[i];
                    const b = p[(i + 1) % 3];
                    const ex = b[0] - a[0];
                    const ey = b[1] - a[1];
                    const len = @sqrt(ex * ex + ey * ey);
                    if (len == 0) continue;
                    d = @min(d, sign * (ex * (q[1] - a[1]) - ey * (q[0] - a[0])) / len);
                }
                if (d + 0.5 > 0) m.put(x, y, d + 0.5);
            }
        }
    }

    /// Composite `color` (straight RGBA) through the mask onto the canvas.
    fn paint(m: *const Mask, c: Canvas, rgb: [3]u8, alpha: u8) void {
        const area = m.area.intersect(c.bounds()) orelse return;
        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            var x = area.x;
            while (x < area.right()) : (x += 1) {
                const cov = m.cov[@intCast((y - m.area.y) * m.area.w + (x - m.area.x))];
                if (cov == 0) continue;
                const sa: u32 = @as(u32, cov) * alpha / 255;
                const inv = 255 - sa;
                const d = &c.px[@intCast((y - c.oy) * c.w + (x - c.ox))];
                d.b = @intCast((@as(u32, rgb[2]) * sa + @as(u32, d.b) * inv + 127) / 255);
                d.g = @intCast((@as(u32, rgb[1]) * sa + @as(u32, d.g) * inv + 127) / 255);
                d.r = @intCast((@as(u32, rgb[0]) * sa + @as(u32, d.r) * inv + 127) / 255);
                d.a = @intCast((255 * sa + @as(u32, d.a) * inv + 127) / 255);
            }
        }
    }
};

fn pt(p: [2]i32) V {
    return .{ @as(f32, @floatFromInt(p[0])) + 0.5, @as(f32, @floatFromInt(p[1])) + 0.5 };
}

const Shape = struct {
    lines: std.ArrayList(V) = .empty,
    closed: bool = false,
    head: ?[3]V = null,
};

/// Geometry of a stroke as a polyline (+ optional arrow head), absolute coords.
fn geometry(a: std.mem.Allocator, s: *const Stroke) !Shape {
    var g = Shape{};
    const first = pt(s.points[0]);
    const last = pt(s.points[s.points.len - 1]);
    switch (s.tool) {
        .pen, .highlighter => for (s.points) |p| try g.lines.append(a, pt(p)),
        .rectangle => {
            const l = @min(first[0], last[0]);
            const t = @min(first[1], last[1]);
            const r = @max(first[0], last[0]);
            const b = @max(first[1], last[1]);
            try g.lines.appendSlice(a, &.{ .{ l, t }, .{ r, t }, .{ r, b }, .{ l, b } });
            g.closed = true;
        },
        .ellipse => {
            const cx = (first[0] + last[0]) / 2;
            const cy = (first[1] + last[1]) / 2;
            const rx = @abs(last[0] - first[0]) / 2;
            const ry = @abs(last[1] - first[1]) / 2;
            const n: usize = @intFromFloat(std.math.clamp((rx + ry) / 3, 24, 180));
            for (0..n) |i| {
                const ang = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau;
                try g.lines.append(a, .{ cx + rx * @cos(ang), cy + ry * @sin(ang) });
            }
            g.closed = true;
        },
        .arrow => {
            const dx = last[0] - first[0];
            const dy = last[1] - first[1];
            const len = @sqrt(dx * dx + dy * dy);
            if (len < 1) return g;
            const ux = dx / len;
            const uy = dy / len;
            const head_len = @min(width(.arrow) * 5, len * 0.6);
            const half = head_len * 0.55;
            const base = V{ last[0] - ux * head_len, last[1] - uy * head_len };
            try g.lines.appendSlice(a, &.{ first, .{ base[0] + ux, base[1] + uy } });
            g.head = .{ last, .{ base[0] - uy * half, base[1] + ux * half }, .{ base[0] + uy * half, base[1] - ux * half } };
        },
    }
    return g;
}

/// Render one stroke onto `c`, limited to `clip` (absolute coords).
pub fn render(a: std.mem.Allocator, c: Canvas, s: *const Stroke, clip: Rect, with_badge: bool) void {
    if (s.points.len == 0) return;
    const area = bounds(s).intersect(clip) orelse return;
    const area_c = area.intersect(c.bounds()) orelse return;
    var g = geometry(a, s) catch return;
    defer g.lines.deinit(a);
    const r = width(s.tool) / 2;
    const rgb = s.color.rgb();

    var mask = Mask.init(a, area_c) catch return;
    defer a.free(mask.cov);
    if (s.tool != .pen and s.tool != .highlighter) {
        // Thin dark halo so shapes stay visible on any background.
        mask.polyline(g.lines.items, r + 1.25, g.closed);
        if (g.head) |h| mask.triangle(h);
        mask.paint(c, .{ 0, 0, 0 }, 90);
        @memset(mask.cov, 0);
    }
    mask.polyline(g.lines.items, r, g.closed);
    if (g.head) |h| mask.triangle(h);
    mask.paint(c, rgb, if (s.tool == .highlighter) 100 else 255);

    if (with_badge) {
        const ctr = badgeCenter(s);
        @memset(mask.cov, 0);
        badge(&mask, c, s.id, ctr, s.color);
    }
}

fn badgeCenter(s: *const Stroke) V {
    const first = s.points[0];
    const last = s.points[s.points.len - 1];
    return switch (s.tool) {
        .arrow => blk: {
            const dx: f32 = @floatFromInt(last[0] - first[0]);
            const dy: f32 = @floatFromInt(last[1] - first[1]);
            const len = @max(@sqrt(dx * dx + dy * dy), 1);
            const d = BADGE_R + 6;
            break :blk .{ @as(f32, @floatFromInt(first[0])) - dx / len * d, @as(f32, @floatFromInt(first[1])) - dy / len * d };
        },
        .rectangle, .ellipse => .{ @as(f32, @floatFromInt(@min(first[0], last[0]))) - 4, @as(f32, @floatFromInt(@min(first[1], last[1]))) - 4 },
        .pen, .highlighter => blk: {
            const b = Rect.bounding(s.points);
            break :blk .{ @as(f32, @floatFromInt(b.x)) - 6, @as(f32, @floatFromInt(b.y)) - 6 };
        },
    };
}

/// `#N` badge: pill in the stroke color with a white ring and seven-segment digits.
fn badge(m: *Mask, c: Canvas, n: u32, ctr: V, color: model.ColorName) void {
    var digits_buf: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{n}) catch return;
    const dw: f32 = 7;
    const gap: f32 = 3.5;
    const nd: f32 = @floatFromInt(digits.len);
    const text_w = nd * dw + (nd - 1) * gap;
    const half_w = @max(text_w / 2 + 7, BADGE_R);
    const a = V{ ctr[0] - half_w + BADGE_R, ctr[1] };
    const b = V{ ctr[0] + half_w - BADGE_R + 0.01, ctr[1] };
    m.capsule(a, b, BADGE_R + 1.5);
    m.paint(c, .{ 255, 255, 255 }, 255);
    @memset(m.cov, 0);
    m.capsule(a, b, BADGE_R);
    m.paint(c, color.rgb(), 255);
    @memset(m.cov, 0);
    const dh: f32 = 13;
    var x = ctr[0] - text_w / 2;
    for (digits) |ch| {
        sevenSegment(m, ch - '0', x, ctr[1] - dh / 2, dw, dh);
        x += dw + gap;
    }
    const tc: [3]u8 = if (color == .yellow) .{ 0, 0, 0 } else .{ 255, 255, 255 };
    m.paint(c, tc, 255);
}

fn sevenSegment(m: *Mask, d: u8, x: f32, y: f32, dw: f32, dh: f32) void {
    const mid = y + dh / 2;
    const segs: []const u8 = switch (d) {
        0 => "abcdef",
        1 => "bc",
        2 => "abged",
        3 => "abgcd",
        4 => "fgbc",
        5 => "afgcd",
        6 => "afgedc",
        7 => "abc",
        8 => "abcdefg",
        else => "abcdfg",
    };
    for (segs) |s| {
        const seg: [2]V = switch (s) {
            'a' => .{ .{ x, y }, .{ x + dw, y } },
            'b' => .{ .{ x + dw, y }, .{ x + dw, mid } },
            'c' => .{ .{ x + dw, mid }, .{ x + dw, y + dh } },
            'd' => .{ .{ x, y + dh }, .{ x + dw, y + dh } },
            'e' => .{ .{ x, mid }, .{ x, y + dh } },
            'f' => .{ .{ x, y }, .{ x, mid } },
            else => .{ .{ x, mid }, .{ x + dw, mid } },
        };
        m.capsule(seg[0], seg[1], 1.2);
    }
}

/// Fill a disc (indicator dot, icon background).
pub fn disc(a: std.mem.Allocator, c: Canvas, cx: f32, cy: f32, r: f32, rgb: [3]u8, alpha: u8) void {
    var m = Mask.init(a, Rect.ltrb(@intFromFloat(cx - r - 2), @intFromFloat(cy - r - 2), @intFromFloat(cx + r + 3), @intFromFloat(cy + r + 3)).intersect(c.bounds()) orelse return) catch return;
    defer a.free(m.cov);
    m.capsule(.{ cx, cy }, .{ cx, cy }, r);
    m.paint(c, rgb, alpha);
}

/// Thick round-capped line (pills, icon strokes).
pub fn line(a: std.mem.Allocator, c: Canvas, p0: V, p1: V, r: f32, rgb: [3]u8, alpha: u8) void {
    var m = Mask.init(a, c.bounds()) catch return;
    defer a.free(m.cov);
    m.capsule(p0, p1, r);
    m.paint(c, rgb, alpha);
}

/// Current tool in the indicator pill.
pub fn toolGlyph(a: std.mem.Allocator, c: Canvas, tool: model.Tool, color: model.ColorName, cx: f32, cy: f32) void {
    var m = Mask.init(a, c.bounds()) catch return;
    defer a.free(m.cov);
    switch (tool) {
        .pen => m.polyline(&.{ .{ cx - 7, cy + 5 }, .{ cx - 3, cy - 3 }, .{ cx + 2, cy + 3 }, .{ cx + 7, cy - 5 } }, 1.25, false),
        .highlighter => m.capsule(.{ cx - 7, cy + 2 }, .{ cx + 7, cy + 2 }, 3.5),
        .rectangle => m.polyline(&.{ .{ cx - 7, cy - 5 }, .{ cx + 7, cy - 5 }, .{ cx + 7, cy + 5 }, .{ cx - 7, cy + 5 } }, 1.25, true),
        .ellipse => {
            var pts: [24]V = undefined;
            for (&pts, 0..) |*p, i| {
                const ang = @as(f32, @floatFromInt(i)) / 24 * std.math.tau;
                p.* = .{ cx + 8 * @cos(ang), cy + 6 * @sin(ang) };
            }
            m.polyline(&pts, 1.25, true);
        },
        .arrow => {
            m.capsule(.{ cx - 7, cy + 6 }, .{ cx + 6, cy - 5 }, 1.25);
            m.polyline(&.{ .{ cx, cy - 6 }, .{ cx + 6, cy - 5 }, .{ cx + 5, cy + 1 } }, 1.25, false);
        },
    }
    m.paint(c, color.rgb(), 255);
}

test "a stroke that is still a single point renders for every tool" {
    // Mouse-down with no movement yet: the overlay previews this stroke.
    var px: [200 * 200]Bgra = @splat(.{ .b = 0, .g = 0, .r = 0, .a = 0 });
    const c = Canvas{ .px = &px, .w = 200, .h = 200 };
    for ([_]model.Tool{ .pen, .highlighter, .rectangle, .ellipse, .arrow }) |tool| {
        const s = Stroke{ .id = 1, .tool = tool, .color = .red, .t_start_ms = 0, .t_end_ms = 0, .points = &.{.{ 100, 100 }}, .bbox = .{} };
        render(std.testing.allocator, c, &s, c.bounds(), true);
    }
}
