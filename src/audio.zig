//! Microphone → 16 kHz mono 16-bit WAV via miniaudio (csrc/audio_shim.c).

const std = @import("std");
const util = @import("util.zig");

extern fn ah_audio_start(path: [*:0]const u16, rate: u32) c_int;
extern fn ah_audio_stop() i64;
extern fn ah_audio_device_name() [*:0]const u8;
extern fn ah_audio_error() [*:0]const u8;
extern fn ah_audio_probe(ms: u32, frames: *u64, peak: *c_int, name: [*]u8, name_len: c_int) c_int;

/// What whisper wants; miniaudio converts and resamples to it.
pub const sample_rate: u32 = 16000;

pub const Recorder = struct {
    sample_rate: u32 = sample_rate,

    var instance: Recorder = .{};

    /// Starts recording the default microphone into `path`.
    pub fn start(path: []const u8) !*Recorder {
        var buf: [1024]u16 = undefined;
        if (ah_audio_start(util.wideInto(&buf, path), sample_rate) != 0) {
            util.log("  no audio: {s}", .{std.mem.span(ah_audio_error())});
            return error.NoMicrophone;
        }
        util.log("  microphone: {s} (recording 16 kHz mono)", .{std.mem.span(ah_audio_device_name())});
        return &instance;
    }

    /// Stops, finalizes the WAV; returns the session time of the first sample.
    pub fn stop(_: *Recorder, session_start_ms: u64) i64 {
        const first = ah_audio_stop();
        return if (first == 0) 0 else first - @as(i64, @intCast(session_start_ms));
    }
};

/// `mictest`: open the microphone for `ms`, report what arrived; nothing is stored.
pub fn probe(ms: u32) void {
    var frames: u64 = 0;
    var peak: c_int = 0;
    var name: [256]u8 = @splat(0);
    if (ah_audio_probe(ms, &frames, &peak, &name, name.len) != 0) {
        util.log("microphone: FAILED ({s})", .{std.mem.span(ah_audio_error())});
        return;
    }
    const expected = @as(u64, ms) * sample_rate / 1000;
    const dbfs = if (peak > 0) 20 * std.math.log10(@as(f64, @floatFromInt(peak)) / 32768.0) else -std.math.inf(f64);
    util.log("microphone: {s}", .{std.mem.sliceTo(&name, 0)});
    util.log("  received {d} of ~{d} expected frames ({d} ms at 16 kHz mono)", .{ frames, expected, ms });
    util.log("  peak level {d:.1} dBFS{s}", .{ dbfs, if (peak == 0) " (silence: muted or blocked by privacy settings?)" else "" });
}
