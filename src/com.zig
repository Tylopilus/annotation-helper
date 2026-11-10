//! COM clients: WIC (PNG encode/decode/scale) and UI Automation.
//! Raw zigwin32 COM: every call returns an HRESULT, every object is Release()d by hand.

const std = @import("std");
const w = @import("win32").everything;
const util = @import("util.zig");
const model = @import("model.zig");
const raster = @import("raster.zig");

pub fn check(hr: w.HRESULT) !void {
    if (hr.failed) return error.ComCall;
}

/// COM must be initialized per thread (MTA here; we never host COM objects).
pub fn initThread() void {
    _ = w.CoInitializeEx(null, .{}); // COINIT_MULTITHREADED is 0
}

fn release(p: anytype) void {
    if (p) |o| _ = o.IUnknown.Release();
}

// ------------------------------------------------------------------ WIC

pub const Wic = struct {
    f: *w.IWICImagingFactory,

    pub fn init() !Wic {
        var f: *w.IWICImagingFactory = undefined;
        try check(w.CoCreateInstance(&w.CLSID_WICImagingFactory, null, w.CLSCTX_INPROC_SERVER, w.IID_IWICImagingFactory, @ptrCast(&f)));
        return .{ .f = f };
    }

    pub fn deinit(s: Wic) void {
        _ = s.f.IUnknown.Release();
    }

    /// Write opaque BGRA pixels as an RGB PNG file.
    pub fn savePng(s: Wic, path: []const u8, px: []const raster.Bgra, width: i32, height: i32) !void {
        var buf: [1024]u16 = undefined;
        var stream: ?*w.IWICStream = null;
        try check(s.f.CreateStream(&stream));
        defer release(stream);
        try check(stream.?.InitializeFromFilename(util.wideInto(&buf, path), w.GENERIC_WRITE));
        try s.encode(@ptrCast(stream.?), px, width, height);
    }

    fn encode(s: Wic, stream: *w.IStream, px: []const raster.Bgra, width: i32, height: i32) !void {
        var encoder: ?*w.IWICBitmapEncoder = null;
        try check(s.f.CreateEncoder(&w.GUID_ContainerFormatPng, null, &encoder));
        defer release(encoder);
        try check(encoder.?.Initialize(stream, w.WICBitmapEncoderNoCache));
        var frame: ?*w.IWICBitmapFrameEncode = null;
        try check(encoder.?.CreateNewFrame(&frame, null));
        defer release(frame);
        try check(frame.?.Initialize(null));
        try check(frame.?.SetSize(@intCast(width), @intCast(height)));
        // 32bppBGR = ignore alpha; WIC writes a 24-bit PNG.
        var format = w.GUID_WICPixelFormat24bppBGR;
        try check(frame.?.SetPixelFormat(&format));
        if (std.mem.eql(u8, std.mem.asBytes(&format), std.mem.asBytes(&w.GUID_WICPixelFormat24bppBGR))) {
            // Convert rows to 24-bit on the fly.
            const row = try util.gpa.alloc(u8, @intCast(width * 3));
            defer util.gpa.free(row);
            var y: i32 = 0;
            while (y < height) : (y += 1) {
                const src = px[@intCast(y * width)..@intCast((y + 1) * width)];
                for (src, 0..) |p, i| {
                    row[i * 3] = p.b;
                    row[i * 3 + 1] = p.g;
                    row[i * 3 + 2] = p.r;
                }
                try check(frame.?.WritePixels(1, @intCast(width * 3), @intCast(row.len), @ptrCast(row.ptr)));
            }
        } else return error.PixelFormat;
        try check(frame.?.Commit());
        try check(encoder.?.Commit());
    }

    /// Load a PNG, downscale to fit `max_edge` (Fant filter), re-encode; returns PNG bytes.
    pub fn fitPng(s: Wic, a: std.mem.Allocator, path: []const u8, max_edge: u32) ![]u8 {
        var buf: [1024]u16 = undefined;
        var decoder: ?*w.IWICBitmapDecoder = null;
        try check(s.f.CreateDecoderFromFilename(util.wideInto(&buf, path), null, w.GENERIC_READ, w.WICDecodeMetadataCacheOnDemand, &decoder));
        defer release(decoder);
        var frame: ?*w.IWICBitmapFrameDecode = null;
        try check(decoder.?.GetFrame(0, &frame));
        defer release(frame);
        var fw: u32 = 0;
        var fh: u32 = 0;
        try check(frame.?.IWICBitmapSource.GetSize(&fw, &fh));
        const long = @max(fw, fh);
        var nw = fw;
        var nh = fh;
        if (long > max_edge) {
            nw = @max(1, @as(u32, @intCast(@as(u64, fw) * max_edge / long)));
            nh = @max(1, @as(u32, @intCast(@as(u64, fh) * max_edge / long)));
        }
        var scaler: ?*w.IWICBitmapScaler = null;
        try check(s.f.CreateBitmapScaler(&scaler));
        defer release(scaler);
        try check(scaler.?.Initialize(@ptrCast(frame.?), nw, nh, w.WICBitmapInterpolationModeFant));
        var conv: ?*w.IWICFormatConverter = null;
        try check(s.f.CreateFormatConverter(&conv));
        defer release(conv);
        var bgra = w.GUID_WICPixelFormat32bppBGRA;
        try check(conv.?.Initialize(@ptrCast(scaler.?), &bgra, w.WICBitmapDitherTypeNone, null, 0, w.WICBitmapPaletteTypeCustom));
        const px = try a.alloc(raster.Bgra, nw * nh);
        defer a.free(px);
        try check(conv.?.IWICBitmapSource.CopyPixels(null, nw * 4, nw * nh * 4, @ptrCast(px.ptr)));

        var mem: ?*w.IStream = null;
        try check(w.CreateStreamOnHGlobal(0, w.TRUE, &mem));
        defer release(mem);
        try s.encode(mem.?, px, @intCast(nw), @intCast(nh));
        var pos: w.ULARGE_INTEGER = undefined;
        try check(mem.?.Seek(.{ .QuadPart = 0 }, w.STREAM_SEEK_CUR, &pos));
        var hg: isize = 0;
        try check(w.GetHGlobalFromStream(mem.?, &hg));
        const ptr: [*]const u8 = @ptrCast(w.GlobalLock(hg) orelse return error.GlobalLock);
        defer _ = w.GlobalUnlock(hg);
        return a.dupe(u8, ptr[0..@intCast(pos.QuadPart)]);
    }
};

// ------------------------------------------------------------------ UI Automation

pub const Uia = struct {
    auto: *w.IUIAutomation,
    walker: ?*w.IUIAutomationTreeWalker,

    pub fn init() !Uia {
        var auto: *w.IUIAutomation = undefined;
        try check(w.CoCreateInstance(w.CLSID_CUIAutomation8, null, w.CLSCTX_INPROC_SERVER, w.IID_IUIAutomation, @ptrCast(&auto)));
        // Don't let a hung app stall us for the default 20 s.
        var a2: ?*w.IUIAutomation2 = null;
        if (!auto.IUnknown.QueryInterface(w.IID_IUIAutomation2, @ptrCast(&a2)).failed) {
            _ = a2.?.put_ConnectionTimeout(1500);
            _ = a2.?.put_TransactionTimeout(1500);
            _ = a2.?.IUnknown.Release();
        }
        var walker: ?*w.IUIAutomationTreeWalker = null;
        _ = auto.get_ControlViewWalker(&walker);
        return .{ .auto = auto, .walker = walker };
    }

    /// What lies at (x, y); strings allocated in `a` (an arena).
    pub fn elementAt(s: Uia, a: std.mem.Allocator, x: i32, y: i32) ?model.UiElement {
        const pt = w.POINT{ .x = x, .y = y };
        var el: ?*w.IUIAutomationElement = null;
        if (s.auto.ElementFromPoint(pt, &el).failed or el == null) return null;
        defer release(el);
        const e = el.?;
        var out = model.UiElement{
            .name = clip(a, bstrProp(a, e, .name), 160),
            .control_type = bstrProp(a, e, .control_type),
            .automation_id = clip(a, bstrProp(a, e, .automation_id), 80),
            .class_name = clip(a, bstrProp(a, e, .class_name), 80),
            .framework = bstrProp(a, e, .framework),
        };
        var pid: i32 = 0;
        _ = e.get_CurrentProcessId(&pid);
        out.process = util.processName(a, @intCast(pid));
        if (util.windowInfo(a, w.WindowFromPoint(pt))) |wi| out.window_title = wi.title;
        var r: w.RECT = undefined;
        if (!e.get_CurrentBoundingRectangle(&r).failed) out.rect = model.Rect.ltrb(r.left, r.top, r.right, r.bottom);

        out.text_at_point = textLineAt(a, e, pt);
        var ancestors: std.ArrayList([]const u8) = .empty;
        if (s.walker) |walker| {
            var cur: *w.IUIAutomationElement = e;
            _ = cur.IUnknown.AddRef();
            defer _ = cur.IUnknown.Release();
            var depth: u32 = 0;
            while (depth < 8) : (depth += 1) {
                var parent: ?*w.IUIAutomationElement = null;
                if (walker.GetParentElement(cur, &parent).failed or parent == null) break;
                const p = parent.?;
                if (std.mem.eql(u8, bstrProp(a, p, .class_name), "#32769")) {
                    _ = p.IUnknown.Release();
                    break; // desktop
                }
                const name = clip(a, bstrProp(a, p, .name), 80);
                if (name.len > 0 and ancestors.items.len < 5) {
                    const line = a.print("{s} \"{s}\"", .{ bstrProp(a, p, .control_type), name }) catch "";
                    ancestors.append(a, line) catch {};
                }
                // Text often lives on the enclosing document/editor, not the leaf.
                if (out.text_at_point == null and depth < 3) out.text_at_point = textLineAt(a, p, pt);
                _ = cur.IUnknown.Release();
                cur = p;
            }
        }
        out.ancestors = ancestors.items;
        return out;
    }
};

const Prop = enum { name, control_type, automation_id, class_name, framework };

fn bstrProp(a: std.mem.Allocator, e: *w.IUIAutomationElement, which: Prop) []const u8 {
    var b: ?w.BSTR = null;
    const hr = switch (which) {
        .name => e.get_CurrentName(&b),
        .control_type => e.get_CurrentLocalizedControlType(&b),
        .automation_id => e.get_CurrentAutomationId(&b),
        .class_name => e.get_CurrentClassName(&b),
        .framework => e.get_CurrentFrameworkId(&b),
    };
    if (hr.failed) return "";
    return takeBstr(a, b);
}

/// Copies a BSTR to UTF-8 and frees it.
fn takeBstr(a: std.mem.Allocator, b: ?w.BSTR) []const u8 {
    const s = b orelse return "";
    defer w.SysFreeString(s);
    const ptr: [*:0]const u16 = @ptrCast(s);
    return util.narrow(a, std.mem.span(ptr)) catch "";
}

/// Collapse whitespace and cap the length (in code points).
fn clip(a: std.mem.Allocator, s: []const u8, max: usize) []const u8 {
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

fn textLineAt(a: std.mem.Allocator, e: *w.IUIAutomationElement, pt: w.POINT) ?[]const u8 {
    var pattern: ?*w.IUIAutomationTextPattern = null;
    if (e.GetCurrentPatternAs(w.UIA_TextPatternId, w.IID_IUIAutomationTextPattern, @ptrCast(&pattern)).failed or pattern == null) return null;
    defer release(pattern);
    var range: ?*w.IUIAutomationTextRange = null;
    if (pattern.?.RangeFromPoint(pt, &range).failed or range == null) return null;
    defer release(range);
    if (range.?.ExpandToEnclosingUnit(w.TextUnit_Line).failed) return null;
    var b: ?w.BSTR = null;
    if (range.?.GetText(400, &b).failed) return null;
    const text = clip(a, takeBstr(a, b), 300);
    return if (text.len > 0) text else null;
}
