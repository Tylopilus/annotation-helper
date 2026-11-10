//! annotation-helper, Zig 0.17 port: narrate + annotate your screen, hand it to an AI agent.
//! Windows: a GUI-subsystem tray app; CLI modes attach to the parent console.
//! Linux: `process` and `mcp` only (recording needs the Windows UI).

const std = @import("std");
const w = @import("win32").everything;
const util = @import("util.zig");
const config = @import("config.zig");
const app = @import("app.zig");
const process = @import("process.zig");
const mcp = @import("mcp.zig");
const audio = @import("audio.zig");
const crash = @import("crash.zig");

// Release builds are ReleaseSafe: bugs stop with a report (crash.log for the tray app)
// instead of running on with undefined behaviour.
pub const panic = std.debug.FullPanic(crash.panic);
pub const debug = struct {
    pub const handleSegfault = crash.handleSegfault;
};

const USAGE =
    \\annotation-helper — narrate + annotate your screen, hand the result to an AI agent
    \\
    \\USAGE
    \\  annotation-helper [record] [--out DIR] [--lang CODE] [--model FILE] [--no-audio] [--no-process]
    \\  annotation-helper process <SESSION_DIR> [--lang CODE] [--model FILE] [--no-clipboard]
    \\  annotation-helper selftest [--audio-file WAV] [--out DIR] [--lang CODE] [--model FILE]
    \\  annotation-helper mcp [--out DIR] [--lang CODE] [--model FILE]   MCP server on stdio
    \\  annotation-helper mictest                                         check the microphone (records nothing)
    \\
    \\  --out DIR       where sessions are stored (default: 'sessions' next to the exe)
    \\  --lang CODE     speech language, e.g. de, en (default: auto-detect)
    \\  --model FILE    whisper ggml model (default: first ggml-*.bin in 'models' next to the exe)
    \\
;

/// GUI-subsystem exes start without stdio when run from a terminal; borrow the
/// terminal's console so output is visible. Pipes (MCP) are kept as they are.
fn attachConsole() void {
    if (comptime !util.is_windows) return;
    if (util.stdHandle(w.STD_ERROR_HANDLE) != null) return;
    if (w.AttachConsole(w.ATTACH_PARENT_PROCESS) == 0) return;
    const h = w.CreateFileW(L("CONOUT$"), .{ .FILE_WRITE_DATA = 1, .FILE_APPEND_DATA = 1, .SYNCHRONIZE = 1 }, .{ .WRITE = 1 }, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return;
    _ = w.SetStdHandle(w.STD_OUTPUT_HANDLE, h);
    _ = w.SetStdHandle(w.STD_ERROR_HANDLE, h);
}
const L = util.L;

fn quoteArg(a: std.mem.Allocator, list: *std.ArrayList(u8), flag: []const u8, value: []const u8) !void {
    try list.print(a, " {s} \"{s}\"", .{ flag, value });
}

pub fn main(init: std.process.Init.Minimal) void {
    attachConsole();
    util.initLog();
    realMain(init) catch |e| {
        util.log("error: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
}

fn realMain(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(util.gpa);
    const a = arena_state.allocator();
    const argv = try init.args.toSlice(a);
    var cmd: []const u8 = "record";
    var i: usize = 1;
    if (argv.len > 1) for ([_][]const u8{ "record", "process", "selftest", "mcp", "mictest", "help" }) |c| {
        if (std.mem.eql(u8, argv[1], c)) {
            cmd = c;
            i = 2;
        }
    };
    var out: ?[]const u8 = null;
    var lang: ?[]const u8 = null;
    var model_path: ?[]const u8 = null;
    var audio_file: ?[]const u8 = null;
    var no_audio = false;
    var no_process = false;
    var no_clipboard = false;
    var positional: std.ArrayList([]const u8) = .empty;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        const needs_value = std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--lang") or std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "--audio-file");
        if (needs_value) {
            if (i + 1 >= argv.len) {
                util.log("{s} needs a value", .{arg});
                return error.BadArgs;
            }
            i += 1;
            const v = argv[i];
            if (std.mem.eql(u8, arg, "--out")) out = v else if (std.mem.eql(u8, arg, "--lang")) lang = v else if (std.mem.eql(u8, arg, "--model")) model_path = v else audio_file = v;
        } else if (std.mem.eql(u8, arg, "--no-audio")) {
            no_audio = true;
        } else if (std.mem.eql(u8, arg, "--no-process")) {
            no_process = true;
        } else if (std.mem.eql(u8, arg, "--no-clipboard")) {
            no_clipboard = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            cmd = "help";
        } else if (std.mem.startsWith(u8, arg, "--")) {
            util.log("unknown option {s}\n\n{s}", .{ arg, USAGE });
            return error.BadArgs;
        } else try positional.append(a, arg);
    }

    const loaded = config.load(a);
    if (loaded.warning) |warn| util.log("warning: {s}", .{warn});
    const cfg = loaded.config;

    if (std.mem.eql(u8, cmd, "mictest")) {
        if (comptime util.is_windows) return audio.probe(2000);
        util.log("mictest needs the Windows build", .{});
        return error.WindowsOnly;
    }
    if (std.mem.eql(u8, cmd, "help")) {
        util.log("{s}", .{USAGE});
        return;
    }
    if (std.mem.eql(u8, cmd, "process")) {
        if (positional.items.len == 0) {
            util.log("process needs a session dir\n\n{s}", .{USAGE});
            return error.BadArgs;
        }
        return process.run(a, .{ .dir = positional.items[0], .lang = lang orelse cfg.language, .model = model_path orelse cfg.model, .clipboard = !no_clipboard });
    }

    const sessions = out orelse try config.sessionsDir(a, cfg);
    if (comptime !util.is_windows) {
        if (std.mem.eql(u8, cmd, "mcp")) return mcp.serve(sessions);
        util.log("'{s}' needs the Windows build; on Linux only `process`, `mcp` and `help` are available.", .{cmd});
        return error.WindowsOnly;
    }
    return runWindows(a, cmd, sessions, cfg, lang, model_path, audio_file, no_audio, no_process);
}

fn runWindows(
    a: std.mem.Allocator,
    cmd: []const u8,
    sessions: []const u8,
    cfg: config.Config,
    lang: ?[]const u8,
    model_path: ?[]const u8,
    audio_file: ?[]const u8,
    no_audio: bool,
    no_process: bool,
) !void {
    // The processor reads config.json itself; only forward explicit overrides.
    var pargs: std.ArrayList(u8) = .empty;
    if (lang) |l| try quoteArg(a, &pargs, "--lang", l);
    if (model_path) |m| try quoteArg(a, &pargs, "--model", m);
    const selftest = std.mem.eql(u8, cmd, "selftest");
    if (selftest) try pargs.appendSlice(a, " --no-clipboard");
    const opts = app.Options{
        .out_dir = sessions,
        .no_audio = no_audio or selftest,
        .audio_file = audio_file,
        .process_args = if (no_process) null else pargs.items,
        .config = if (std.mem.eql(u8, cmd, "record")) cfg else null,
    };
    util.log("annotation-helper 0.1.0", .{});
    if (selftest) return app.selftest(opts);
    if (std.mem.eql(u8, cmd, "mcp")) {
        mcp_dir = sessions;
        return app.runMcp(opts, serveMcp);
    }
    return app.run(opts);
}

var mcp_dir: []const u8 = "";
fn serveMcp() void {
    mcp.serve(mcp_dir);
}

test {
    _ = config;
    _ = @import("raster.zig");
}
