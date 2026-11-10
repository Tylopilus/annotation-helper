//! Post-processing of a session: offline transcription (whisper.cpp via csrc/whisper_shim.c)
//! and `brief.md`, which interleaves narration with annotated screenshots for an AI agent.

const std = @import("std");
const util = @import("util.zig");
const model = @import("model.zig");

extern fn ah_transcribe(
    model_path: [*:0]const u8,
    pcm: [*]const f32,
    n_samples: c_int,
    language: ?[*:0]const u8,
    n_threads: c_int,
    cb: *const fn (?*anyopaque, i64, i64, [*:0]const u8) callconv(.c) void,
    user: ?*anyopaque,
    lang_out: [*]u8,
    lang_out_len: c_int,
) c_int;

pub const Options = struct {
    dir: []const u8,
    lang: ?[]const u8 = null,
    model: ?[]const u8 = null,
    clipboard: bool = true,
};

pub fn run(a: std.mem.Allocator, o: Options) !void {
    const sess_path = try util.join(a, &.{ o.dir, "session.json" });
    const bytes = util.readFile(a, sess_path) catch return error.NoSessionJson;
    const parsed = try model.fromJson(model.Session, a, bytes);
    const session = parsed.value;
    util.log("⧗ Processing {s}", .{o.dir});

    var transcript: ?model.Transcript = null;
    if (session.audio) |au| {
        if (findModel(a, o.model)) |model_path| {
            transcript = try transcribe(a, try util.join(a, &.{ o.dir, au.file }), au.offset_ms, model_path, o.lang);
            try util.writeFile(try util.join(a, &.{ o.dir, "transcript.json" }), try model.toJson(a, transcript.?));
        } else util.log("  no whisper model found — put a ggml-*.bin into a 'models' folder next to the exe", .{});
    }

    const brief = try buildBrief(a, session, transcript);
    const brief_path = try util.join(a, &.{ o.dir, "brief.md" });
    try util.writeFile(brief_path, brief);
    const wsl = try util.wslPath(a, brief_path);
    util.log("✔ Brief ready: {s}", .{brief_path});
    if (wsl) |p| util.log("  (WSL: {s})", .{p});
    if (o.clipboard and util.is_windows) {
        const where = if (wsl) |p| try a.print("{s} (Windows path: {s})", .{ p, brief_path }) else brief_path;
        const prompt = try a.print("I recorded a narrated screen session with annotations. Read the brief at {s} and look at the screenshots it references (same folder). Then summarize what I'm asking for, list open questions, and propose next steps before changing anything.", .{where});
        if (util.setClipboard(prompt)) util.log("  Hand-off prompt copied to clipboard — paste it into your agent.", .{}) else |_| {}
    }
}

fn findModel(a: std.mem.Allocator, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |p| return if (util.exists(p)) p else null;
    const dir = util.exeDir(a) catch return null;
    const models = util.join(a, &.{ dir, "models" }) catch return null;
    const names = util.listDir(a, models, false) catch return null;
    // Prefer bigger (better) models if several are present.
    const ranks = [_][]const u8{ "large", "turbo", "medium", "small", "base", "tiny" };
    var best: ?[]const u8 = null;
    var best_rank: usize = 99;
    for (names) |n| {
        if (!std.mem.endsWith(u8, n, ".bin") or std.mem.indexOf(u8, n, "ggml") == null) continue;
        var rank: usize = 9;
        for (ranks, 0..) |k, i| if (std.mem.indexOf(u8, n, k) != null) {
            rank = i;
            break;
        };
        if (rank < best_rank) {
            best_rank = rank;
            best = n;
        }
    }
    return util.join(a, &.{ models, best orelse return null }) catch null;
}

extern fn ah_decode_wav(path: [*:0]const u16, rate: u32, pcm: *?[*]f32, frames: *u64) c_int;
extern fn ah_decode_wav_utf8(path: [*:0]const u8, rate: u32, pcm: *?[*]f32, frames: *u64) c_int;
extern fn ah_free(p: ?*anyopaque) void;
extern fn ah_decode_error() [*:0]const u8;

/// Any WAV → 16 kHz mono float, decoded and resampled by miniaudio. Caller frees with ah_free.
fn loadPcm16k(path: []const u8) ![]f32 {
    var pcm: ?[*]f32 = null;
    var frames: u64 = 0;
    const rc = if (comptime util.is_windows) blk: {
        var buf: [1024]u16 = undefined;
        break :blk ah_decode_wav(util.wideInto(&buf, path), 16000, &pcm, &frames);
    } else blk: {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.NameTooLong;
        break :blk ah_decode_wav_utf8(z.ptr, 16000, &pcm, &frames);
    };
    if (rc != 0) {
        util.log("  cannot read audio: {s}", .{std.mem.span(ah_decode_error())});
        return error.AudioDecode;
    }
    return pcm.?[0..@intCast(frames)];
}

const Collect = struct {
    a: std.mem.Allocator,
    raw: std.ArrayList(struct { t0: i64, t1: i64, text: []const u8 }) = .empty,

    fn cb(user: ?*anyopaque, t0: i64, t1: i64, text: [*:0]const u8) callconv(.c) void {
        const self: *Collect = @ptrCast(@alignCast(user.?));
        const t = self.a.dupe(u8, std.mem.trim(u8, std.mem.span(text), " \t\r\n")) catch return;
        self.raw.append(self.a, .{ .t0 = t0 * 10, .t1 = t1 * 10, .text = t }) catch {};
    }
};

fn transcribe(a: std.mem.Allocator, wav_path: []const u8, offset_ms: i64, model_path: []const u8, lang: ?[]const u8) !model.Transcript {
    const pcm = try loadPcm16k(wav_path);
    defer ah_free(pcm.ptr);
    const model_name = std.fs.path.basenameWindows(model_path);
    util.log("  transcribing {d}s of audio with {s} …", .{ pcm.len / 16000, model_name });
    const started = util.nowMs();

    var col = Collect{ .a = a };
    var lang_buf: [16]u8 = @splat(0);
    const threads: c_int = @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
    const mz = try a.dupeSentinel(u8, model_path, 0);
    const lz: ?[:0]u8 = if (lang) |l| try a.dupeSentinel(u8, l, 0) else null;
    const rc = ah_transcribe(mz.ptr, pcm.ptr, @intCast(pcm.len), if (lz) |l| l.ptr else null, threads, Collect.cb, &col, &lang_buf, lang_buf.len);
    if (rc == 1) return error.ModelLoadFailed;
    if (rc != 0) return error.TranscriptionFailed;

    // RMS per 100 ms; drop "hallucinated" segments that fall into silence.
    const nwin = (pcm.len + 1599) / 1600;
    const rms = try a.alloc(f32, nwin);
    for (rms, 0..) |*r, i| {
        const win = pcm[i * 1600 .. @min(pcm.len, (i + 1) * 1600)];
        var s: f32 = 0;
        for (win) |v| s += v * v;
        r.* = @sqrt(s / @as(f32, @floatFromInt(win.len)));
    }
    const sorted = try a.dupe(f32, rms);
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
    const pct = struct {
        fn f(v: []const f32, q: f32) f32 {
            if (v.len == 0) return 0;
            return v[@intFromFloat(@as(f32, @floatFromInt(v.len - 1)) * q)];
        }
    }.f;
    const noise = pct(sorted, 0.2);
    const speech = pct(sorted, 0.95);
    const gate = noise + 0.12 * (speech - noise);

    var segs: std.ArrayList(model.Segment) = .empty;
    for (col.raw.items) |s| {
        const t = s.text;
        const bracketed = t.len >= 2 and ((t[0] == '[' and t[t.len - 1] == ']') or (t[0] == '(' and t[t.len - 1] == ')') or (t[0] == '*' and t[t.len - 1] == '*'));
        const w0: usize = @intCast(@divTrunc(@max(s.t0, 0), 100));
        const w1: usize = @min(@as(usize, @intCast(@divTrunc(@max(s.t1, 0), 100))) + 1, rms.len);
        var loudest: f32 = 0;
        if (w0 < w1) for (rms[w0..w1]) |v| {
            loudest = @max(loudest, v);
        };
        if (t.len == 0 or bracketed or loudest < gate) continue;
        try segs.append(a, .{ .t_start_ms = s.t0 + offset_ms, .t_end_ms = s.t1 + offset_ms, .text = t });
    }
    const language = std.mem.sliceTo(&lang_buf, 0);
    util.log("  {d} segment(s), language {s}, took {d:.1}s", .{ segs.items.len, if (language.len > 0) language else "?", @as(f64, @floatFromInt(util.nowMs() - started)) / 1000 });
    return .{ .model = model_name, .language = if (language.len > 0) try a.dupe(u8, language) else null, .segments = segs.items };
}

// ------------------------------------------------------------------ brief

fn describeElement(out: *std.ArrayList(u8), a: std.mem.Allocator, e: model.UiElement) !void {
    const ty = if (e.control_type.len == 0) "element" else e.control_type;
    if (e.name.len == 0) try out.print(a, "{s}", .{ty}) else try out.print(a, "{s} \"{s}\"", .{ ty, e.name });
    if (e.text_at_point) |t| if (!std.mem.eql(u8, t, e.name)) try out.print(a, ", text line: \"{s}\"", .{t});
    if (e.ancestors.len > 0) try out.print(a, ", inside {s}", .{e.ancestors[0]});
    if (e.process.len > 0 and e.window_title.len > 0) {
        try out.print(a, " · in {s} — \"{s}\"", .{ e.process, e.window_title });
    } else if (e.process.len > 0) {
        try out.print(a, " · in {s}", .{e.process});
    } else if (e.window_title.len > 0) try out.print(a, " · in \"{s}\"", .{e.window_title});
}

fn describeStroke(out: *std.ArrayList(u8), a: std.mem.Allocator, s: model.Stroke) !void {
    var tb: [16]u8 = undefined;
    try out.print(a, "- **#{d} {s}** ({s}) at {s}", .{ s.id, s.tool.label(), @tagName(s.color), util.fmtTime(&tb, @intCast(s.t_start_ms)) });
    for (s.targets) |t| {
        const role = if (std.mem.eql(u8, t.role, "from")) "from" else if (std.mem.eql(u8, t.role, "to")) "to" else "on";
        try out.print(a, " · {s}: ", .{role});
        if (t.element) |e| try describeElement(out, a, e) else try out.appendSlice(a, "unknown");
    }
    if (s.crop) |c| try out.print(a, " · zoom: `{s}`", .{c});
    try out.append(a, '\n');
}

pub fn buildBrief(a: std.mem.Allocator, session: model.Session, transcript: ?model.Transcript) ![]u8 {
    var n_strokes: usize = 0;
    for (session.frames) |f| n_strokes += f.strokes.len;
    var md: std.ArrayList(u8) = .empty;
    var tb: [16]u8 = undefined;
    try md.print(a, "# Screen session {s}\n\n", .{session.started_local});
    try md.print(a, "Narrated screen session: {s} long, {d} screenshot(s), {d} annotation(s)", .{ util.fmtTime(&tb, @intCast(session.duration_ms)), session.frames.len, n_strokes });
    if (transcript) |t| {
        try md.print(a, ", speech transcribed offline ({s}, language: {s}).\n\n", .{ t.model, t.language orelse "?" });
    } else try md.appendSlice(a, if (session.audio != null) ", audio recorded but not transcribed.\n\n" else ", no audio.\n\n");
    try md.appendSlice(a,
        \\**How to read this:** the timeline interleaves what the user *said* (quoted, `[mm:ss]`) with screenshots they annotated while talking. Every annotation carries a numbered badge `#N` in the image. Words like "this", "here" or "that one" usually refer to the annotation drawn at about the same time. Open the referenced PNG files (same folder as this brief) — `frame-NN.png` is the annotated screenshot, `frame-NN-aMM.png` a zoomed crop around annotation #MM, `frame-NN-clean.png` the same screen without drawings. "on/from/to" names the UI element under the annotation as reported by Windows UI Automation; for code editors and canvases it can be generic, so trust the image. Arrows point *from* → *to*, often expressing a relation between two places. Machine-readable details: `session.json`, `transcript.json`. The speech transcript may contain recognition errors — interpret it in context.
        \\
        \\## Timeline
        \\
        \\
    );

    const Ev = struct { t: i64, order: u8, seg: ?model.Segment = null, frame: ?model.Frame = null };
    var events: std.ArrayList(Ev) = .empty;
    if (transcript) |t| for (t.segments) |s| try events.append(a, .{ .t = s.t_start_ms, .order = 1, .seg = s });
    for (session.frames) |f| try events.append(a, .{ .t = @intCast(f.t_start_ms), .order = 0, .frame = f });
    std.mem.sort(Ev, events.items, {}, struct {
        fn lt(_: void, x: Ev, y: Ev) bool {
            return x.t < y.t or (x.t == y.t and x.order < y.order);
        }
    }.lt);

    var in_quote = false;
    for (events.items) |ev| {
        if (ev.seg) |s| {
            if (!in_quote) try md.append(a, '\n');
            try md.print(a, "> `[{s}]` {s}\n", .{ util.fmtTime(&tb, s.t_start_ms), s.text });
            in_quote = true;
        } else if (ev.frame) |f| {
            in_quote = false;
            var tb2: [16]u8 = undefined;
            try md.print(a, "\n### Screenshot {d} · `[{s}–{s}]`", .{ f.index, util.fmtTime(&tb, @intCast(f.t_start_ms)), util.fmtTime(&tb2, @intCast(f.t_end_ms)) });
            if (f.foreground) |fg| try md.print(a, " · active window: {s} — \"{s}\"", .{ fg.process, fg.title });
            try md.print(a, "\n\n![Screenshot {d}]({s})\n\n", .{ f.index, f.image });
            if (f.strokes.len == 0) try md.appendSlice(a, "_No annotations — plain screenshot._\n");
            for (f.strokes) |s| try describeStroke(&md, a, s);
        }
    }
    const no_speech = if (transcript) |t| t.segments.len == 0 else true;
    if (session.frames.len == 0 and no_speech) try md.appendSlice(a, "_Nothing was captured in this session._\n");
    return md.items;
}
