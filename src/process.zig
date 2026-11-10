//! Post-processing of a session: offline transcription (whisper.cpp via csrc/whisper_shim.c)
//! and `brief.md`, which interleaves narration with annotated screenshots for an AI agent.
//!
//! Two modes: `process <dir>` transcribes a finished recording in one go; `process <dir>
//! --live` is started with the recording, follows audio.wav while it grows, transcribes
//! at each pause, and finishes when its stdin closes (the session ended), so only the last
//! few seconds are left to do then.

const std = @import("std");
const util = @import("util.zig");
const model = @import("model.zig");
const config = @import("config.zig");
const w = @import("win32").everything;
const lsys = @import("linux/sys.zig");

const SegmentCb = *const fn (?*anyopaque, i64, i64, [*:0]const u8) callconv(.c) void;
extern fn ah_transcribe(model_path: [*:0]const u8, pcm: [*]const f32, n_samples: c_int, language: ?[*:0]const u8, n_threads: c_int, cb: SegmentCb, user: ?*anyopaque, lang_out: [*]u8, lang_out_len: c_int) c_int;
extern fn ah_whisper_open(model_path: [*:0]const u8) ?*anyopaque;
extern fn ah_whisper_close(ctx: ?*anyopaque) void;
extern fn ah_whisper_run(ctx: *anyopaque, pcm: [*]const f32, n_samples: c_int, language: ?[*:0]const u8, n_threads: c_int, keep_context: c_int, cb: SegmentCb, user: ?*anyopaque, lang_out: [*]u8, lang_out_len: c_int) c_int;

pub const Options = struct {
    dir: []const u8,
    lang: ?[]const u8 = null,
    model: ?[]const u8 = null,
    clipboard: bool = true,
    live: bool = false,
};

const RATE = 16000;
/// 100 ms windows for loudness (pause detection and the silence filter).
const WIN = RATE / 10;

pub fn run(a: std.mem.Allocator, o: Options) !void {
    if (o.live) return runLive(a, o);
    const session = try readSession(a, o.dir);
    util.log("⧗ Processing {s}", .{o.dir});

    var transcript: ?model.Transcript = null;
    if (session.audio) |au| {
        if (findModel(a, o.model)) |model_path| {
            transcript = try transcribe(a, try util.join(a, &.{ o.dir, au.file }), au.offset_ms, model_path, o.lang);
            try util.writeFile(try util.join(a, &.{ o.dir, "transcript.json" }), try model.toJson(a, transcript.?));
        } else logNoModel();
    }
    try finish(a, o, session, transcript);
}

fn readSession(a: std.mem.Allocator, dir: []const u8) !model.Session {
    const bytes = util.readFile(a, try util.join(a, &.{ dir, "session.json" })) catch return error.NoSessionJson;
    return (try model.fromJson(model.Session, a, bytes)).value;
}

fn logNoModel() void {
    util.log("  no whisper model found — put a ggml-*.bin into a 'models' folder next to the exe{s}", .{if (util.is_windows) "" else " or in ~/.local/share/annotation-helper/models"});
}

/// Writes brief.md and puts the hand-off prompt on the clipboard.
fn finish(a: std.mem.Allocator, o: Options, session: model.Session, transcript: ?model.Transcript) !void {
    const brief = try buildBrief(a, session, transcript);
    const brief_path = try util.join(a, &.{ o.dir, "brief.md" });
    try util.writeFile(brief_path, brief);
    const wsl = try util.wslPath(a, brief_path);
    util.log("✔ Brief ready: {s}", .{brief_path});
    if (wsl) |p| util.log("  (WSL: {s})", .{p});
    if (o.clipboard) {
        const where = if (wsl) |p| try a.print("{s} (Windows path: {s})", .{ p, brief_path }) else brief_path;
        const prompt = try a.print("I recorded a narrated screen session with annotations. Read the brief at {s} and look at the screenshots it references (same folder). Then summarize what I'm asking for, list open questions, and propose next steps before changing anything.", .{where});
        if (util.setClipboard(prompt)) util.log("  Hand-off prompt copied to clipboard — paste it into your agent.", .{}) else |e| if (!util.is_windows) {
            util.log("  clipboard: {s} (install wl-clipboard on Wayland or xclip on X11)", .{@errorName(e)});
        }
    }
}

fn findModel(a: std.mem.Allocator, explicit: ?[]const u8) ?[]const u8 {
    if (explicit) |p| return if (util.exists(p)) p else null;
    // `models` next to the exe, then (Linux) in the data folder.
    const exe_dir = util.exeDir(a) catch return null;
    const data_dir = config.dataDir(a) catch exe_dir;
    for ([_][]const u8{ exe_dir, data_dir }) |dir| {
        const models = util.join(a, &.{ dir, "models" }) catch continue;
        if (findModelIn(a, models)) |m| return m;
    }
    return null;
}

fn findModelIn(a: std.mem.Allocator, models: []const u8) ?[]const u8 {
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
        break :blk ah_decode_wav(util.wideInto(&buf, path), RATE, &pcm, &frames);
    } else blk: {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.NameTooLong;
        break :blk ah_decode_wav_utf8(z.ptr, RATE, &pcm, &frames);
    };
    if (rc != 0) {
        util.log("  cannot read audio: {s}", .{std.mem.span(ah_decode_error())});
        return error.AudioDecode;
    }
    return pcm.?[0..@intCast(frames)];
}

const Raw = struct { t0: i64, t1: i64, text: []const u8 };

const Collect = struct {
    a: std.mem.Allocator,
    raw: std.ArrayList(Raw) = .empty,
    /// Added to whisper's chunk-relative times (live mode), in ms.
    base_ms: i64 = 0,

    fn cb(user: ?*anyopaque, t0: i64, t1: i64, text: [*:0]const u8) callconv(.c) void {
        const self: *Collect = @ptrCast(@alignCast(user.?));
        const t = self.a.dupe(u8, std.mem.trim(u8, std.mem.span(text), " \t\r\n")) catch return;
        self.raw.append(self.a, .{ .t0 = t0 * 10 + self.base_ms, .t1 = t1 * 10 + self.base_ms, .text = t }) catch {};
    }
};

fn rmsOf(pcm: []const f32) f32 {
    if (pcm.len == 0) return 0;
    var s: f32 = 0;
    for (pcm) |v| s += v * v;
    return @sqrt(s / @as(f32, @floatFromInt(pcm.len)));
}

/// Loudness above which a 100 ms window counts as speech, from the recording so far.
fn speechGate(a: std.mem.Allocator, rms: []const f32) f32 {
    const sorted = a.dupe(f32, rms) catch return 0;
    defer a.free(sorted);
    std.mem.sort(f32, sorted, {}, std.sort.asc(f32));
    const pct = struct {
        fn f(v: []const f32, q: f32) f32 {
            if (v.len == 0) return 0;
            return v[@intFromFloat(@as(f32, @floatFromInt(v.len - 1)) * q)];
        }
    }.f;
    const noise = pct(sorted, 0.2);
    const speech = pct(sorted, 0.95);
    return noise + 0.12 * (speech - noise);
}

/// Drops empty, bracketed ("[music]") and "hallucinated" segments that fall into silence,
/// and shifts the rest by `offset_ms` (session time of the first sample).
fn filterSegments(a: std.mem.Allocator, raw: []const Raw, rms: []const f32, offset_ms: i64) ![]model.Segment {
    const gate = speechGate(a, rms);
    var segs: std.ArrayList(model.Segment) = .empty;
    for (raw) |s| {
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
    return segs.items;
}

fn threadsFull() c_int {
    return @intCast(@min(std.Thread.getCpuCount() catch 4, 8));
}

fn transcribe(a: std.mem.Allocator, wav_path: []const u8, offset_ms: i64, model_path: []const u8, lang: ?[]const u8) !model.Transcript {
    const pcm = try loadPcm16k(wav_path);
    defer ah_free(pcm.ptr);
    const model_name = std.fs.path.basenameWindows(model_path);
    util.log("  transcribing {d}s of audio with {s} …", .{ pcm.len / RATE, model_name });
    const started = util.nowMs();

    var col = Collect{ .a = a };
    var lang_buf: [16]u8 = @splat(0);
    const mz = try a.dupeSentinel(u8, model_path, 0);
    const lz: ?[:0]u8 = if (lang) |l| try a.dupeSentinel(u8, l, 0) else null;
    const rc = ah_transcribe(mz.ptr, pcm.ptr, @intCast(pcm.len), if (lz) |l| l.ptr else null, threadsFull(), Collect.cb, &col, &lang_buf, lang_buf.len);
    if (rc == 1) return error.ModelLoadFailed;
    if (rc != 0) return error.TranscriptionFailed;

    const rms = try a.alloc(f32, (pcm.len + WIN - 1) / WIN);
    for (rms, 0..) |*r, i| r.* = rmsOf(pcm[i * WIN .. @min(pcm.len, (i + 1) * WIN)]);
    const segs = try filterSegments(a, col.raw.items, rms, offset_ms);
    const language = std.mem.sliceTo(&lang_buf, 0);
    util.log("  {d} segment(s), language {s}, took {d:.1}s", .{ segs.len, if (language.len > 0) language else "?", @as(f64, @floatFromInt(util.nowMs() - started)) / 1000 });
    return .{ .model = model_name, .language = if (language.len > 0) try a.dupe(u8, language) else null, .segments = segs };
}

// ------------------------------------------------------------------ live mode

/// audio.wav while the recorder is still writing it (16 kHz mono 16-bit PCM).
const GrowingWav = struct {
    handle: if (util.is_windows) w.HANDLE else c_int,
    carry: ?u8 = null,

    fn open(path: []const u8) !GrowingWav {
        // The recorder created the file before we were started; allow a moment anyway.
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            if (openRaw(path)) |g| {
                var r = g;
                try r.skipHeader();
                return r;
            } else |e| if (tries > 50) return e;
            sleepMs(100);
        }
    }

    fn openRaw(path: []const u8) !GrowingWav {
        if (comptime util.is_windows) {
            var buf: [1024]u16 = undefined;
            const h = w.CreateFileW(util.wideInto(&buf, path), w.FILE_GENERIC_READ, .{ .READ = 1, .WRITE = 1, .DELETE = 1 }, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
            if (h == w.INVALID_HANDLE_VALUE) return error.FileNotFound;
            return .{ .handle = h };
        }
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.NameTooLong;
        const fd = lsys.open(z.ptr, lsys.O_RDONLY | lsys.O_CLOEXEC);
        if (fd < 0) return error.FileNotFound;
        return .{ .handle = fd };
    }

    fn close(g: *GrowingWav) void {
        if (comptime util.is_windows) _ = w.CloseHandle(g.handle) else _ = lsys.close(g.handle);
    }

    /// Bytes available right now (0 = nothing new yet).
    fn read(g: *GrowingWav, buf: []u8) usize {
        if (comptime util.is_windows) {
            var n: u32 = 0;
            if (w.ReadFile(g.handle, buf.ptr, @intCast(buf.len), &n, null) == 0) return 0;
            return n;
        }
        const n = lsys.read(g.handle, buf.ptr, buf.len);
        return if (n > 0) @intCast(n) else 0;
    }

    fn readExact(g: *GrowingWav, buf: []u8) !void {
        var off: usize = 0;
        var waited: u32 = 0;
        while (off < buf.len) {
            const n = g.read(buf[off..]);
            if (n == 0) {
                waited += 1;
                if (waited > 100) return error.Truncated;
                sleepMs(50);
            }
            off += n;
        }
    }

    /// Checks the format and positions at the first sample.
    fn skipHeader(g: *GrowingWav) !void {
        var riff: [12]u8 = undefined;
        try g.readExact(&riff);
        if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) return error.NotWav;
        while (true) {
            var ch: [8]u8 = undefined;
            try g.readExact(&ch);
            const size = std.mem.readInt(u32, ch[4..8], .little);
            if (std.mem.eql(u8, ch[0..4], "data")) return;
            if (size > 4096) return error.NotWav;
            var body: [4096]u8 = undefined;
            const padded = size + (size & 1);
            try g.readExact(body[0..padded]);
            if (std.mem.eql(u8, ch[0..4], "fmt ")) {
                const fmt = std.mem.readInt(u16, body[0..2], .little);
                const channels = std.mem.readInt(u16, body[2..4], .little);
                const rate = std.mem.readInt(u32, body[4..8], .little);
                const bits = std.mem.readInt(u16, body[14..16], .little);
                if (fmt != 1 or channels != 1 or rate != RATE or bits != 16) return error.UnsupportedWav;
            }
        }
    }

    /// Appends the newly written samples (as floats) to `out`; returns how many.
    fn poll(g: *GrowingWav, a: std.mem.Allocator, out: *std.ArrayList(f32)) !usize {
        var buf: [32768]u8 = undefined;
        var total: usize = 0;
        while (true) {
            var off: usize = 0;
            if (g.carry) |c| {
                buf[0] = c;
                off = 1;
                g.carry = null;
            }
            const n = g.read(buf[off..]) + off;
            if (n == off and off == 0) break;
            const whole = n / 2 * 2;
            if (whole < n) g.carry = buf[n - 1];
            try out.ensureUnusedCapacity(a, whole / 2);
            var i: usize = 0;
            while (i < whole) : (i += 2) {
                const v = std.mem.readInt(i16, buf[i..][0..2], .little);
                out.appendAssumeCapacity(@as(f32, @floatFromInt(v)) / 32768.0);
            }
            total += whole / 2;
            if (n < buf.len) break;
        }
        return total;
    }
};

fn sleepMs(ms: u32) void {
    if (comptime util.is_windows) w.Sleep(ms) else lsys.sleepMs(ms);
}

const Signal = enum { none, finish, cancel };

/// What the app says on our stdin: closed = the session ended, "cancel" = discard it.
fn checkStdin() Signal {
    var buf: [64]u8 = undefined;
    if (comptime util.is_windows) {
        const h = util.stdHandle(w.STD_INPUT_HANDLE) orelse return .finish;
        var avail: u32 = 0;
        if (w.PeekNamedPipe(h, null, 0, null, &avail, null) == 0) return .finish; // broken pipe: closed
        if (avail == 0) return .none;
        var n: u32 = 0;
        if (w.ReadFile(h, &buf, @intCast(@min(avail, buf.len)), &n, null) == 0) return .finish;
        return if (std.mem.indexOf(u8, buf[0..n], "cancel") != null) .cancel else .none;
    }
    var p = [1]lsys.PollFd{.{ .fd = 0, .events = lsys.POLLIN }};
    if (lsys.poll(&p, 1, 0) <= 0) return .none;
    const n = lsys.read(0, &buf, buf.len);
    if (n <= 0) return .finish;
    return if (std.mem.indexOf(u8, buf[0..@intCast(n)], "cancel") != null) .cancel else .none;
}

const MIN_CHUNK = 10 * RATE;

const Live = struct {
    a: std.mem.Allocator,
    ctx: *anyopaque,
    col: Collect,
    /// Samples not transcribed yet; `base` is the index of pending[0] in the recording.
    pending: std.ArrayList(f32) = .empty,
    base: u64 = 0,
    /// Loudness of every complete 100 ms window of the recording.
    rms: std.ArrayList(f32) = .empty,
    lang: ?[:0]const u8,
    lang_buf: [16]u8 = @splat(0),
    chunks: u32 = 0,

    fn updateRms(l: *Live) void {
        const done_samples = l.rms.items.len * WIN;
        const have = l.base + l.pending.items.len;
        var start = done_samples;
        while (start + WIN <= have) : (start += WIN) {
            const off: usize = @intCast(start - l.base);
            l.rms.append(l.a, rmsOf(l.pending.items[off..][0..WIN])) catch return;
        }
    }

    /// Where to cut `pending`: in the middle of the first pause of ≥ 0.6 s after at least
    /// 10 s of audio, or (no pause) at the quietest moment once 28 s have piled up.
    /// whisper always encodes a 30 s window, so every call costs about the same; few,
    /// long chunks keep up best, and the tail left at the end costs one call either way.
    fn findCut(l: *Live) ?usize {
        const len = l.pending.items.len;
        if (len < MIN_CHUNK) return null;
        const gate = speechGate(l.a, l.rms.items);
        const first_win: usize = @intCast((l.base + WIN - 1) / WIN);
        const last_win = l.rms.items.len;
        var quiet: usize = 0;
        var win = first_win + MIN_CHUNK / WIN - 6;
        while (win < last_win) : (win += 1) {
            if (l.rms.items[win] < gate) {
                quiet += 1;
                if (quiet >= 6) {
                    const mid = win + 1 - quiet / 2;
                    const cut = mid * WIN - l.base;
                    if (cut >= MIN_CHUNK) return @intCast(cut);
                }
            } else quiet = 0;
        }
        if (len < 28 * RATE) return null;
        var best = last_win - 1;
        var w0 = if (last_win > 40) last_win - 40 else first_win;
        while (w0 < last_win) : (w0 += 1) if (l.rms.items[w0] < l.rms.items[best]) {
            best = w0;
        };
        const cut = @max(best * WIN, l.base + RATE) - l.base;
        return @intCast(@min(cut, len));
    }

    /// Transcribes pending[0..n] and drops it.
    fn transcribe(l: *Live, n: usize, threads: c_int) !void {
        const chunk = l.pending.items[0..n];
        // Skip chunks without any speech (saves time, avoids invented text).
        const w0: usize = @intCast(l.base / WIN);
        const w1 = @min(l.rms.items.len, @as(usize, @intCast((l.base + n) / WIN)));
        const gate = speechGate(l.a, l.rms.items);
        var speech = w1 <= w0; // too short to judge: transcribe
        if (w0 < w1) for (l.rms.items[w0..w1]) |v| {
            if (v >= gate) speech = true;
        };
        if (speech and n >= RATE / 2) {
            l.col.base_ms = @intCast(l.base * 1000 / RATE);
            const t = util.nowMs();
            const rc = ah_whisper_run(l.ctx, chunk.ptr, @intCast(n), if (l.lang) |x| x.ptr else null, threads, 1, Collect.cb, &l.col, &l.lang_buf, l.lang_buf.len);
            if (rc != 0) return error.TranscriptionFailed;
            // Keep the language whisper detected for the rest of the recording.
            if (l.lang == null and l.lang_buf[0] != 0) l.lang = l.lang_buf[0..std.mem.indexOfScalar(u8, &l.lang_buf, 0).? :0];
            l.chunks += 1;
            util.log("  [{d}:{d:0>2}] transcribed {d:.1}s in {d:.1}s", .{ l.base / RATE / 60, l.base / RATE % 60, @as(f64, @floatFromInt(n)) / RATE, @as(f64, @floatFromInt(util.nowMs() - t)) / 1000 });
        }
        l.pending.replaceRange(l.a, 0, n, &.{}) catch unreachable;
        l.base += n;
    }
};

fn runLive(a: std.mem.Allocator, o: Options) !void {
    const model_path = findModel(a, o.model) orelse {
        logNoModel();
        return error.NoModel;
    };
    util.log("⧗ Live transcription for {s} with {s}", .{ o.dir, std.fs.path.basenameWindows(model_path) });
    const ctx = ah_whisper_open((try a.dupeSentinel(u8, model_path, 0)).ptr) orelse return error.ModelLoadFailed;
    defer ah_whisper_close(ctx);
    var wav = try GrowingWav.open(try util.join(a, &.{ o.dir, "audio.wav" }));
    defer wav.close();

    var l = Live{ .a = a, .ctx = ctx, .col = .{ .a = a }, .lang = if (o.lang) |x| try a.dupeSentinel(u8, x, 0) else null };
    // While recording, leave CPU for the user's work.
    const live_threads: c_int = @intCast(std.math.clamp((std.Thread.getCpuCount() catch 4) / 2, 2, 8));
    var signal: Signal = .none;
    while (signal == .none) {
        _ = try wav.poll(a, &l.pending);
        l.updateRms();
        signal = checkStdin();
        if (signal != .none) break;
        if (l.findCut()) |cut| try l.transcribe(cut, live_threads) else sleepMs(200);
    }
    if (signal == .cancel) {
        util.log("  cancelled", .{});
        return;
    }
    // The session ended: the recorder has finalized the file. Transcribe the rest.
    const stopped = util.nowMs();
    _ = try wav.poll(a, &l.pending);
    l.updateRms();
    while (l.findCut()) |cut| try l.transcribe(cut, threadsFull());
    if (l.pending.items.len > 0) try l.transcribe(l.pending.items.len, threadsFull());
    util.log("  {d} chunk(s); {d:.1}s of work left after the recording ended", .{ l.chunks, @as(f64, @floatFromInt(util.nowMs() - stopped)) / 1000 });

    const session = try readSession(a, o.dir);
    const offset = if (session.audio) |au| au.offset_ms else 0;
    const segs = try filterSegments(a, l.col.raw.items, l.rms.items, offset);
    const language = std.mem.sliceTo(&l.lang_buf, 0);
    const transcript = model.Transcript{ .model = std.fs.path.basenameWindows(model_path), .language = if (language.len > 0) language else if (o.lang) |x| x else null, .segments = segs };
    try util.writeFile(try util.join(a, &.{ o.dir, "transcript.json" }), try model.toJson(a, transcript));
    try finish(a, o, session, transcript);
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
        \\**How to read this:** the timeline interleaves what the user *said* (quoted, `[mm:ss]`) with screenshots they annotated while talking. Every annotation carries a numbered badge `#N` in the image. Words like "this", "here" or "that one" usually refer to the annotation drawn at about the same time. Open the referenced PNG files (same folder as this brief) — `frame-NN.png` is the annotated screenshot, `frame-NN-aMM.png` a zoomed crop around annotation #MM, `frame-NN-clean.png` the same screen without drawings. "on/from/to" names the UI element under the annotation as reported by the system's accessibility interface (UI Automation on Windows, AT-SPI on Linux); for code editors and canvases it can be generic, so trust the image. Arrows point *from* → *to*, often expressing a relation between two places. Machine-readable details: `session.json`, `transcript.json`. The speech transcript may contain recognition errors — interpret it in context.
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
