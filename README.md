# annotation-helper (PoC)

Narrate while you circle, box and draw arrows on your screen. The result becomes a session
folder that any AI agent can read: annotated screenshots, crops of each annotation, the UI
element under each annotation, and an offline transcript, all combined into `brief.md`.

A single portable Windows `.exe` (~3.3 MB, whisper.cpp included), written in Zig 0.17. No installer, nothing sent
over the network. It uses about 3 MB private memory while idle.

## Use

Double-click `annotation-helper.exe`. It runs in the notification area (tray). There's no
window and no console, and only one instance runs at a time. Right-click the pen icon for the
menu: start/stop recording, draw, show the last brief, open the sessions folder, change
hotkeys, edit `config.json`, quit. The icon gets a red dot while recording.

| Hotkey (default) | Action |
|---|---|
| `Ctrl+Alt+R` | start / stop a session (mic recording) |
| `Ctrl+Alt+D` | start drawing on the screen (auto-starts a session) / finish the screenshot |

While drawing: `P` pen (default) · `R` rectangle · `E` ellipse · `A` arrow · `H` highlighter ·
`1-4` red/green/blue/yellow · `Ctrl+Z` undo · `Del` clear · `Esc` / right-click finishes.
The app underneath keeps focus. Between screenshots you can work normally (switch apps,
scroll code) while you keep talking.

When a session stops, it is transcribed in the background. A notification tells you when
`brief.md` is ready; a hand-off prompt pointing at it is then on the clipboard, ready to paste
into Claude Code or any other agent. Click the notification to show the files.

### Hotkeys and settings

Change a hotkey in the tray menu → **Hotkeys**. Pick the hotkey, then press the new combination
(Ctrl, Alt or Win plus a key, or an F-key alone; Esc cancels). If another app already uses that
combination, the old hotkey is kept and you get a notification. Settings live in `config.json`
next to the exe (created on first start):

```json
{
  "hotkeys": { "session": "Ctrl+Alt+R", "draw": "Ctrl+Alt+D" },
  "language": null,
  "model": null,
  "sessions_dir": null
}
```

`language` (e.g. `"de"`) skips language detection, `model` selects a whisper model file,
`sessions_dir` moves the sessions folder. Command-line flags override the file.

Session folder (`sessions/<timestamp>/` next to the exe, or `--out DIR`):

```
brief.md            timeline: narration interleaved with screenshots + annotation list
session.json        frames, strokes (coords, timing), UI Automation targets
transcript.json     whisper segments with session timestamps
audio.wav           16-bit mono microphone recording
frame-NN.png        annotated screenshot (only the monitors that were drawn on)
frame-NN-clean.png  same, without drawings
frame-NN-aMM.png    zoomed crop around annotation #MM
```

Other commands (run from a terminal; output appears there): `process <dir> [--lang de]
[--model FILE]` re-runs transcription and the brief (its log goes to `process.log` in the
session folder when started by the app). `selftest [--audio-file WAV]` draws a scripted screenshot and processes it.
`mictest` opens the default microphone for 2 s and reports frames and peak level, storing nothing.

## MCP server (agent integration)

`annotation-helper.exe mcp` is an MCP server on stdio. Any MCP client can browse your
sessions, and an agent can ask you to point at things on your screen. Register it with
Claude Code (from WSL; Claude Code launches the Windows exe directly):

```
EXE=/mnt/c/Users/<you>/annotation-helper/annotation-helper.exe
claude  mcp add annotation-helper -s user -- $EXE mcp
codex   mcp add annotation-helper -- $EXE mcp        # then add  tool_timeout_sec = 900  to its entry in ~/.codex/config.toml
copilot mcp add annotation-helper -- $EXE mcp        # then add  "timeout": 900000  to its entry in ~/.copilot/mcp-config.json
agy     mcp add annotation-helper $EXE mcp
```

**Skill.** Registering the server only makes the tools available; agents still ask questions
in text out of habit. The skill in [`skills/annotation-helper/`](skills/annotation-helper/SKILL.md)
tells them when to use the tools: reading a session you mention, asking *on the screen*
whenever the answer is a place there, and letting you mark what is still wrong after a
visible change. Install it once per agent:

```
mkdir -p ~/.agents/skills && cp -r skills/annotation-helper ~/.agents/skills/   # Codex, Copilot CLI
ln -s ~/.agents/skills/annotation-helper ~/.claude/skills/                       # Claude Code
mkdir -p ~/.gemini/config/skills && ln -s ~/.agents/skills/annotation-helper ~/.gemini/config/skills/   # agy
```

| Tool | What it does |
|---|---|
| `list_sessions` | Recorded sessions, newest first: duration, screenshots, apps, first words said |
| `get_session` | The brief, plus annotated screenshots and per-annotation zoom crops as images (scaled to ≤1568 px). No id = latest |
| `get_image` | Any file of a session, e.g. `frame-01-clean.png`, at a chosen size |
| `annotate_screen` | Shows the agent's question in a banner on your screen. You draw (and talk); `Esc` sends, `Shift+Esc` cancels. Returns the result like `get_session` |

Requests from agents are stored as normal sessions in the same folder; cancelled ones are
deleted. The MCP mode registers no hotkeys, so it can run alongside the interactive recorder.
`annotate_screen` blocks until you answer (default timeout 10 min). If your client cuts off
long tool calls, raise its tool timeout (Claude Code: `MCP_TOOL_TIMEOUT`, in ms).

Test hook: with `ANNOTATION_HELPER_TEST_AUTODRAW=1` set, `annotate_screen` draws scripted
annotations after 1.5 s and sends them. Nobody needs to be at the screen.

## Speech model

Put any whisper.cpp `ggml-*.bin` into `models/` next to the exe. Tested with
`ggml-small-q5_1.bin` (181 MB, multilingual, transcribes ~13 s of audio in ~7 s on CPU):

```
curl -L -o models/ggml-small-q5_1.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin
```

## Build (from WSL/Linux; only Zig 0.17 needed)

```
ZIG=.tools/zig-x86_64-linux-0.17.0/zig
$ZIG build --release=safe                                  # Windows: zig-out/bin/annotation-helper.exe
$ZIG build --release=safe -Dtarget=x86_64-linux-gnu        # Linux:   zig-out/bin/annotation-helper
$ZIG build test-exe [-Dtarget=x86_64-linux-gnu]            # unit tests: zig-out/bin/tests(.exe)
cp zig-out/bin/annotation-helper.exe /mnt/c/Users/<you>/annotation-helper/
```

whisper.cpp v1.8.3, zigwin32 (pinned commit) and stb are fetched by the build by URL + hash.
`build.zig` compiles whisper.cpp from source with the same flags as its CMake build (CPU
backend, AVX2 baseline, always ReleaseFast). `csrc/whisper_shim.c` wraps the whisper call, so
Zig never has to mirror `struct whisper_full_params`.

Release builds are **ReleaseSafe**: bounds and overflow checks stay on, so a bug stops with a
message and a stack trace instead of reading stray memory. The tray app has no console; it
appends those reports to `crash.log` next to the exe. The exe ships without its `.pdb`, so
frames are raw addresses; subtract the logged image base and look the offset up in
`zig-out/bin/annotation-helper.pdb`.

The **Linux build** covers what makes sense without the Windows drawing UI: `process` and
`mcp` (`list_sessions`, `get_session`, `get_image`; `annotate_screen` needs Windows and isn't
offered). It's useful for agents running in WSL that read sessions under `/mnt/c/...`. On
Linux, MCP images are handled by stb (`csrc/image_shim.c`). In WSL, keep the whisper model on
the Linux filesystem: loading it from `/mnt/c` took 37.7 s instead of 8.6 s.

### Zig 0.17 pitfalls hit so far

- **`-mcpu baseline` silently overrides `-mavx2`:** ggml would quietly compile its scalar
  fallback (12x slower), so whisper is always built for `x86_64_v3`, whatever the target.
- **GitHub tarballs as dependencies** keep their top-level folder (except stb's), so files are
  addressed through it (`win32_root`, `whisper_root` in `build.zig`).
- **`std.Thread.spawn` stacks** default to 16 MiB, *committed* on Windows (18.7 MB idle);
  `util.thread_cfg` uses 512 KiB.
- **Multi-line string literals contain `\n`:** the embedded tools JSON must be stripped of
  newlines for newline-delimited JSON-RPC.
- **zigwin32 quirks:** `COINIT` has no `MULTITHREADED` field (it is 0), `VIRTUAL_KEY` is an
  exhaustive enum, some CLSIDs are pointers and others values, some enum tags are mangled
  (`WICBitmapDitherType.itmapDitherTypeNone`). COM is manual: raw `HRESULT`s, out-pointers,
  `Release()`/`SysFreeString` by hand.

## How it works

- **Overlay:** a layered, topmost, non-activating window over the whole virtual screen. It
  exists only while drawing (the DIB is freed afterwards). Strokes are rendered by a small
  anti-aliased rasterizer (`src/raster.zig`) into dirty rects. A low-level keyboard hook is installed only while drawing, so
  tool keys don't reach the app below.
- **Capture:** the overlay is hidden and `DwmFlush` waits for the screen to update, then
  `BitBlt` captures the affected monitors. PNGs are encoded, decoded and scaled with WIC. The status pill is excluded via
  `WDA_EXCLUDEFROMCAPTURE`.
- **UI targets:** UI Automation `ElementFromPoint` at each annotation's center (arrows: tail
  and head). It records the name, type, ancestors, process, window title, and the text line
  under the point when the control exposes TextPattern. A warm-up query when drawing starts
  makes Chromium/Electron apps build their accessibility tree.
- **Tray:** `Shell_NotifyIcon`, with icons drawn at runtime. The exe uses the Windows GUI
  subsystem, and CLI modes attach to the parent console.
- **Audio:** miniaudio (bundled with whisper.cpp, `csrc/audio_shim.c`) records straight to a
  16 kHz mono WAV on disk; its decoder also reads and resamples any WAV for whisper. After the session, the exe re-launches
  itself as `process` so whisper's memory is released when it finishes. Segments that fall
  in silence are dropped (this filters whisper hallucinations).
- **Threads:** plain Win32 (`CreateFileW`, `CreateProcessW`, SRW locks, a thread message
  queue via `PostThreadMessageW` for the worker), not `std.Io`.
