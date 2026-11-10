//! MCP server (stdio, newline-delimited JSON-RPC 2.0): browse recorded sessions and ask
//! the user to annotate their screen.

const std = @import("std");
const w = @import("win32").everything;
const util = @import("util.zig");
const model = @import("model.zig");
const com = @import("com.zig");
const process = @import("process.zig");
const app = @import("app.zig");
const worker = @import("worker.zig");

const Value = std.json.Value;
const MAX_EDGE: u32 = 1568;

var sessions_dir: []const u8 = "";
/// Guards stdout across tool-call threads (portable spin lock; writes are short).
var out_lock = std.atomic.Value(bool).init(false);
var client_name: [64]u8 = undefined;
var client_len: usize = 0;
var annotating_id: ?i64 = null;

const INSTRUCTIONS =
    "annotation-helper connects you to the user's screen. Sessions are recordings in which the user " ++
    "talked (transcribed offline) while drawing numbered annotations (#N boxes, ellipses, arrows, " ++
    "highlights) on screenshots of whatever apps they were using; each annotation also names the UI " ++
    "element underneath. When the user refers to \"my recording\", \"the session\", \"what I showed you\" " ++
    "or similar, use list_sessions / get_session (no id = latest). Whenever the answer to a question you " ++
    "would ask the user is a place on their screen — which button, which element, where a problem shows, " ++
    "what should go where — ask it with annotate_screen instead of in text: it shows a short, specific " ++
    "question on their screen, waits until they finish drawing (and talking) and returns the annotated " ++
    "screenshot. After changing something visible, you can also use it to let the user mark what is " ++
    "still wrong. Don't use it for questions words answer just as well.";

const TOOLS_COMMON =
    \\[{"name":"list_sessions","title":"List screen sessions","description":"List the user's recorded screen sessions (newest first): when, how long, how many annotated screenshots, which apps, and the first words they said.","inputSchema":{"type":"object","properties":{"limit":{"type":"integer","minimum":1,"maximum":100,"description":"How many sessions (default 10)."}}},"annotations":{"readOnlyHint":true}},
    \\{"name":"get_session","title":"Get a screen session","description":"Get one recorded session: a timeline of the user's narration interleaved with the screenshots they annotated, the UI element under each numbered annotation, and the images themselves (annotated screenshots, plus zoomed crops around each annotation). Omit session_id for the latest session.","inputSchema":{"type":"object","properties":{"session_id":{"type":"string","description":"Session id from list_sessions. Default: latest."},"images":{"type":"string","enum":["all","frames","crops","none"],"description":"Which images to include (default all)."},"max_images":{"type":"integer","minimum":0,"maximum":40,"description":"Upper bound on attached images (default 12); the rest can be fetched with get_image."}}},"annotations":{"readOnlyHint":true}},
    \\{"name":"get_image","title":"Get a session image","description":"Get one image file of a session, e.g. a clean screenshot (frame-NN-clean.png) or a frame at higher resolution.","inputSchema":{"type":"object","required":["file"],"properties":{"session_id":{"type":"string","description":"Default: latest session."},"file":{"type":"string","description":"File name inside the session folder, e.g. frame-01.png"},"max_edge":{"type":"integer","minimum":200,"maximum":4000,"description":"Downscale so the longest edge fits (default 1568)."}}},"annotations":{"readOnlyHint":true}},
;

/// Windows only: needs the drawing UI.
const TOOL_ANNOTATE =
    \\{"name":"annotate_screen","title":"Ask the user to annotate their screen","description":"Show a question on the user's screen and let them answer by drawing on it (boxes, arrows, circles, highlights) and, by default, talking. Blocks until they press Esc, then returns the annotated screenshot, a zoomed crop and the UI element under each annotation, plus what they said. Use it to resolve ambiguity about something visible: \"Which button do you mean?\", \"Circle the misaligned element\", \"Point from the field to where its value should come from\". The user can cancel (an error result).","inputSchema":{"type":"object","required":["prompt"],"properties":{"prompt":{"type":"string","description":"Short question shown to the user, e.g. 'Which of these buttons should be disabled?'"},"voice":{"type":"boolean","description":"Record and transcribe what the user says while drawing (default true)."},"timeout_s":{"type":"integer","minimum":10,"maximum":3600,"description":"Give up after this many seconds (default 600)."}}}}
;

const TOOLS = if (util.is_windows) TOOLS_COMMON ++ TOOL_ANNOTATE ++ "]" else TOOLS_COMMON[0 .. TOOLS_COMMON.len - 1] ++ "]";

const Content = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

const ToolResult = struct {
    content: []const Content,
    isError: ?bool = null,
};

fn send(line: []const u8) void {
    while (out_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer out_lock.store(false, .release);
    util.writeStdout(line) catch {};
    util.writeStdout("\n") catch {};
}

fn reply(a: std.mem.Allocator, id: Value, result_json: []const u8) void {
    const idj = std.json.Stringify.valueAlloc(a, id, .{}) catch return;
    const line = a.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ idj, result_json }) catch return;
    send(line);
}

fn replyError(a: std.mem.Allocator, id: Value, code: i32, msg: []const u8) void {
    const idj = std.json.Stringify.valueAlloc(a, id, .{}) catch return;
    const m = std.json.Stringify.valueAlloc(a, msg, .{}) catch return;
    send(a.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}", .{ idj, code, m }) catch return);
}

fn toolJson(a: std.mem.Allocator, r: ToolResult) []const u8 {
    return std.json.Stringify.valueAlloc(a, r, .{ .emit_null_optional_fields = false }) catch "{\"content\":[]}";
}

fn toolError(a: std.mem.Allocator, msg: []const u8) []const u8 {
    return toolJson(a, .{ .content = &.{.{ .type = "text", .text = msg }}, .isError = true });
}

/// Reads JSON-RPC lines from stdin until EOF.
pub fn serve(dir: []const u8) void {
    sessions_dir = dir;
    @memcpy(client_name[0.."Your agent".len], "Your agent");
    client_len = "Your agent".len;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(util.gpa);
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = util.readStdin(&chunk);
        if (n == 0) break;
        buf.appendSlice(util.gpa, chunk[0..n]) catch break;
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = util.gpa.dupe(u8, std.mem.trim(u8, buf.items[0..nl], " \r\t")) catch break;
            buf.replaceRange(util.gpa, 0, nl + 1, &.{}) catch break;
            if (line.len == 0) {
                util.gpa.free(line);
                continue;
            }
            handleLine(line);
        }
    }
}

/// Takes ownership of `line`.
fn handleLine(line: []u8) void {
    var arena = std.heap.ArenaAllocator.init(util.gpa);
    const a = arena.allocator();
    const msg = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch {
        replyError(a, .null, -32700, "parse error");
        arena.deinit();
        util.gpa.free(line);
        return;
    };
    const obj = if (msg == .object) msg.object else {
        arena.deinit();
        util.gpa.free(line);
        return;
    };
    const method = if (obj.get("method")) |m| (if (m == .string) m.string else "") else "";
    const id = obj.get("id");
    const params = obj.get("params") orelse Value{ .null = {} };

    if (std.mem.eql(u8, method, "tools/call") and id != null) {
        // Own thread: annotate_screen blocks until the user is done. The thread owns
        // the arena and the line.
        const ctx = util.gpa.create(Call) catch return;
        ctx.* = .{ .arena = arena, .line = line, .id = id.?, .params = params };
        if (std.Thread.spawn(util.thread_cfg, Call.run, .{ctx})) |t| t.detach() else |_| ctx.run();
        return;
    }
    defer {
        arena.deinit();
        util.gpa.free(line);
    }
    if (id == null) {
        if (std.mem.eql(u8, method, "notifications/cancelled")) {
            const target = if (params == .object) params.object.get("requestId") else null;
            if (target != null and target.? == .integer and annotating_id != null and annotating_id.? == target.?.integer) {
                if (comptime util.is_windows) app.cancelAnnotation();
            }
        }
        return;
    }
    if (std.mem.eql(u8, method, "initialize")) {
        if (params == .object) if (params.object.get("clientInfo")) |ci| if (ci == .object) if (ci.object.get("name")) |n| if (n == .string) setClient(n.string);
        const requested = if (params == .object) (if (params.object.get("protocolVersion")) |v| (if (v == .string) v.string else "") else "") else "";
        var version: []const u8 = "2025-06-18";
        for ([_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" }) |v| if (std.mem.eql(u8, v, requested)) {
            version = v;
        };
        const result = std.json.Stringify.valueAlloc(a, .{
            .protocolVersion = version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "annotation-helper", .version = "0.1.0" },
            .instructions = INSTRUCTIONS,
        }, .{}) catch return;
        reply(a, id.?, result);
    } else if (std.mem.eql(u8, method, "ping")) {
        reply(a, id.?, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        // Multi-line literals contain '\n'; JSON-RPC over stdio is one message per line.
        const tools = std.mem.replaceOwned(u8, a, TOOLS, "\n", "") catch return;
        reply(a, id.?, a.print("{{\"tools\":{s}}}", .{tools}) catch return);
    } else {
        replyError(a, id.?, -32601, a.print("method not found: {s}", .{method}) catch "method not found");
    }
}

fn setClient(name: []const u8) void {
    const lower_has = struct {
        fn f(s: []const u8, needle: []const u8) bool {
            return std.ascii.findIgnoreCase(s, needle) != null;
        }
    }.f;
    const pretty = if (lower_has(name, "claude")) "Claude" else if (lower_has(name, "codex")) "Codex" else if (lower_has(name, "cursor")) "Cursor" else name;
    client_len = @min(pretty.len, client_name.len);
    @memcpy(client_name[0..client_len], pretty[0..client_len]);
}

const Call = struct {
    arena: std.heap.ArenaAllocator,
    line: []u8,
    id: Value,
    params: Value,

    fn run(c: *Call) void {
        if (comptime util.is_windows) com.initThread();
        const a = c.arena.allocator();
        reply(a, c.id, callTool(a, c.id, c.params));
        c.arena.deinit();
        util.gpa.free(c.line);
        util.gpa.destroy(c);
    }
};

fn argStr(args: ?Value, k: []const u8) ?[]const u8 {
    const o = args orelse return null;
    if (o != .object) return null;
    const v = o.object.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn argInt(args: ?Value, k: []const u8, d: i64) i64 {
    const o = args orelse return d;
    if (o != .object) return d;
    const v = o.object.get(k) orelse return d;
    return if (v == .integer) v.integer else d;
}

fn callTool(a: std.mem.Allocator, id: Value, params: Value) []const u8 {
    if (params != .object) return toolError(a, "missing params");
    const name = if (params.object.get("name")) |n| (if (n == .string) n.string else "") else "";
    const args = params.object.get("arguments");
    if (std.mem.eql(u8, name, "list_sessions")) {
        return listSessions(a, @intCast(std.math.clamp(argInt(args, "limit", 10), 1, 100)));
    } else if (std.mem.eql(u8, name, "get_session")) {
        const dir = resolve(a, argStr(args, "session_id")) catch |e| return toolError(a, resolveErr(a, e, argStr(args, "session_id")));
        return sessionContent(a, dir, argStr(args, "images") orelse "all", @intCast(std.math.clamp(argInt(args, "max_images", 12), 0, 40)), null);
    } else if (std.mem.eql(u8, name, "get_image")) {
        const dir = resolve(a, argStr(args, "session_id")) catch |e| return toolError(a, resolveErr(a, e, argStr(args, "session_id")));
        const file = argStr(args, "file") orelse "";
        if (file.len == 0 or std.mem.indexOfAny(u8, file, "/\\") != null or std.mem.indexOf(u8, file, "..") != null) {
            return toolError(a, a.print("invalid file name '{s}'", .{file}) catch "invalid file name");
        }
        const path = util.join(a, &.{ dir, file }) catch return toolError(a, "out of memory");
        const img = imageBlock(a, path, @intCast(std.math.clamp(argInt(args, "max_edge", MAX_EDGE), 200, 4000))) orelse return toolError(a, a.print("cannot read {s}", .{file}) catch "cannot read image");
        return toolJson(a, .{ .content = &.{ .{ .type = "text", .text = file }, img } });
    } else if (std.mem.eql(u8, name, "annotate_screen")) {
        return if (comptime util.is_windows) annotateScreen(a, id, args) else toolError(a, "annotate_screen needs the Windows build (it shows the drawing UI).");
    }
    return toolError(a, a.print("unknown tool '{s}'", .{name}) catch "unknown tool");
}

/// Windows only: show the request banner, wait for the user's drawing, return it.
fn annotateScreen(a: std.mem.Allocator, id: Value, args: ?Value) []const u8 {
    const prompt = std.mem.trim(u8, argStr(args, "prompt") orelse "", " ");
    if (prompt.len == 0) return toolError(a, "prompt must not be empty");
    const voice = if (args) |o| (if (o == .object) (if (o.object.get("voice")) |v| (if (v == .bool) v.bool else true) else true) else true) else true;
    const timeout_s = std.math.clamp(argInt(args, "timeout_s", 600), 10, 3600);
    var r = worker.Reply{ .event = w.CreateEventW(null, w.TRUE, w.FALSE, null) orelse return toolError(a, "no event") };
    defer _ = w.CloseHandle(r.event);
    var req = app.Request{ .prompt = prompt, .asker = client_name[0..client_len], .voice = voice, .timeout_ms = @intCast(timeout_s * 1000), .reply = &r };
    annotating_id = if (id == .integer) id.integer else null;
    app.annotate(&req);
    annotating_id = null;
    defer util.gpa.free(r.text);
    if (!r.ok) return toolError(a, a.print("No annotation: {s}.", .{r.text}) catch "No annotation.");
    const intro = a.print("The user answered your request \"{s}\" by annotating their screen.", .{prompt}) catch "";
    return sessionContent(a, a.dupe(u8, r.text) catch return toolError(a, "out of memory"), "all", 12, intro);

}

fn resolveErr(a: std.mem.Allocator, e: anyerror, id: ?[]const u8) []const u8 {
    return switch (e) {
        error.InvalidId => a.print("invalid session id '{s}'", .{id orelse ""}) catch "invalid session id",
        error.NoSuchSession => a.print("no session '{s}' (see list_sessions)", .{id orelse ""}) catch "no such session",
        else => "no sessions recorded yet",
    };
}

/// Session dirs (with session.json), newest first.
fn sessionDirs(a: std.mem.Allocator) [][]u8 {
    const names = util.listDir(a, sessions_dir, true) catch return &.{};
    var out: std.ArrayList([]u8) = .empty;
    for (names) |n| {
        const p = util.join(a, &.{ sessions_dir, n, "session.json" }) catch continue;
        if (util.exists(p)) out.append(a, n) catch {};
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn gt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .gt;
        }
    }.gt);
    return out.items;
}

fn resolve(a: std.mem.Allocator, id: ?[]const u8) ![]const u8 {
    if (id) |s| {
        if (s.len == 0) return error.InvalidId;
        for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return error.InvalidId;
        const dir = try util.join(a, &.{ sessions_dir, s });
        if (!util.exists(try util.join(a, &.{ dir, "session.json" }))) return error.NoSuchSession;
        return dir;
    }
    const dirs = sessionDirs(a);
    if (dirs.len == 0) return error.NoSessions;
    return util.join(a, &.{ sessions_dir, dirs[0] });
}

fn readSession(a: std.mem.Allocator, dir: []const u8) ?model.Session {
    const bytes = util.readFile(a, util.join(a, &.{ dir, "session.json" }) catch return null) catch return null;
    const p = model.fromJson(model.Session, a, bytes) catch return null;
    return p.value;
}

fn readTranscript(a: std.mem.Allocator, dir: []const u8) ?model.Transcript {
    const bytes = util.readFile(a, util.join(a, &.{ dir, "transcript.json" }) catch return null) catch return null;
    const p = model.fromJson(model.Transcript, a, bytes) catch return null;
    return p.value;
}

fn status(a: std.mem.Allocator, dir: []const u8, s: model.Session) []const u8 {
    if (util.exists(util.join(a, &.{ dir, "brief.md" }) catch "")) return "ready";
    return if (s.duration_ms == 0) "recording" else "processing (transcript pending)";
}

fn location(a: std.mem.Allocator, dir: []const u8) []const u8 {
    const wsl = util.wslPath(a, dir) catch null;
    return if (wsl) |p| a.print("{s} (WSL: {s})", .{ dir, p }) catch dir else dir;
}

fn listSessions(a: std.mem.Allocator, limit: usize) []const u8 {
    const dirs = sessionDirs(a);
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{d} session(s) in {s}", .{ dirs.len, location(a, sessions_dir) }) catch {};
    if (dirs.len == 0) out.appendSlice(a, "\nNothing recorded yet. The user records with the annotation-helper app (Ctrl+Alt+D to draw, Ctrl+Alt+R to start/stop).") catch {};
    for (dirs[0..@min(limit, dirs.len)]) |n| {
        const dir = util.join(a, &.{ sessions_dir, n }) catch continue;
        const s = readSession(a, dir) orelse continue;
        var strokes: usize = 0;
        for (s.frames) |f| strokes += f.strokes.len;
        var tb: [16]u8 = undefined;
        out.print(a, "\n- {s} · {s} · {s} · {d} screenshot(s), {d} annotation(s) · {s}", .{ s.id, s.started_local, util.fmtTime(&tb, @intCast(s.duration_ms)), s.frames.len, strokes, status(a, dir, s) }) catch {};
        var apps: std.ArrayList([]const u8) = .empty;
        for (s.frames) |f| if (f.foreground) |fg| {
            if (apps.items.len == 0 or !std.mem.eql(u8, apps.items[apps.items.len - 1], fg.process)) apps.append(a, fg.process) catch {};
        };
        if (apps.items.len > 0) out.print(a, " · apps: {s}", .{std.mem.join(a, ", ", apps.items) catch ""}) catch {};
        if (readTranscript(a, dir)) |t| if (t.segments.len > 0) {
            var said: std.ArrayList(u8) = .empty;
            for (t.segments) |seg| {
                if (said.items.len > 0) said.append(a, ' ') catch {};
                said.appendSlice(a, seg.text) catch {};
            }
            var cut = said.items;
            var cps: usize = 0;
            for (said.items, 0..) |ch, i| {
                if (ch & 0xC0 != 0x80) cps += 1;
                if (cps > 120) {
                    cut = a.print("{s}…", .{said.items[0..i]}) catch said.items;
                    break;
                }
            }
            out.print(a, "\n  said: \"{s}\"", .{cut}) catch {};
        };
    }
    return toolJson(a, .{ .content = &.{.{ .type = "text", .text = out.items }} });
}

extern fn ah_png_fit(path: [*:0]const u8, max_edge: c_int, out_len: *c_int) ?[*]u8;
extern fn ah_png_free(p: ?*anyopaque) void;

/// PNG downscaled to fit `max_edge` (WIC on Windows, stb on Linux).
fn fitPng(a: std.mem.Allocator, path: []const u8, max_edge: u32) ![]u8 {
    if (comptime util.is_windows) {
        const wic = try com.Wic.init();
        defer wic.deinit();
        return wic.fitPng(a, path, max_edge);
    }
    const z = try a.dupeSentinel(u8, path, 0);
    var len: c_int = 0;
    const p = ah_png_fit(z.ptr, @intCast(max_edge), &len) orelse return error.ImageDecode;
    defer ah_png_free(p);
    return a.dupe(u8, p[0..@intCast(len)]);
}

fn imageBlock(a: std.mem.Allocator, path: []const u8, max_edge: u32) ?Content {
    const png = fitPng(a, path, max_edge) catch return null;
    const enc = std.base64.standard.Encoder;
    const b64 = a.alloc(u8, enc.calcSize(png.len)) catch return null;
    return .{ .type = "image", .data = enc.encode(b64, png), .mimeType = "image/png" };
}

fn sessionContent(a: std.mem.Allocator, dir: []const u8, images: []const u8, max_images: usize, intro: ?[]const u8) []const u8 {
    const s = readSession(a, dir) orelse return toolError(a, "cannot read session.json");
    var head: std.ArrayList(u8) = .empty;
    if (intro) |i| head.print(a, "{s}\n\n", .{i}) catch {};
    head.print(a, "Session {s} · status: {s} · folder: {s}\nImages below are labelled with their file names; get_image fetches any file in the folder.\n\n", .{ s.id, status(a, dir, s), location(a, dir) }) catch {};
    const brief = util.readFile(a, util.join(a, &.{ dir, "brief.md" }) catch "") catch
        (process.buildBrief(a, s, readTranscript(a, dir)) catch "");
    head.appendSlice(a, brief) catch {};

    var content: std.ArrayList(Content) = .empty;
    content.append(a, .{ .type = "text", .text = head.items }) catch {};
    const Wanted = struct { label: []const u8, file: []const u8 };
    var wanted: std.ArrayList(Wanted) = .empty;
    const all = std.mem.eql(u8, images, "all");
    for (s.frames) |f| {
        if (all or std.mem.eql(u8, images, "frames")) wanted.append(a, .{ .label = a.print("Screenshot {d} ({s})", .{ f.index, f.image }) catch "", .file = f.image }) catch {};
        if (all or std.mem.eql(u8, images, "crops")) for (f.strokes) |st| if (st.crop) |c| {
            wanted.append(a, .{ .label = a.print("Zoom on annotation #{d} ({s})", .{ st.id, c }) catch "", .file = c }) catch {};
        };
    }
    const take = @min(max_images, wanted.items.len);
    for (wanted.items[0..take]) |x| {
        const path = util.join(a, &.{ dir, x.file }) catch continue;
        if (imageBlock(a, path, MAX_EDGE)) |img| {
            content.append(a, .{ .type = "text", .text = x.label }) catch {};
            content.append(a, img) catch {};
        } else content.append(a, .{ .type = "text", .text = a.print("{s}: cannot read image", .{x.label}) catch "" }) catch {};
    }
    if (wanted.items.len > take) content.append(a, .{ .type = "text", .text = a.print("{d} more image(s) not attached; use get_image to fetch them.", .{wanted.items.len - take}) catch "" }) catch {};
    return toolJson(a, .{ .content = content.items });
}
