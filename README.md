# annotation-helper

Show your AI agent what you mean. Talk while you circle, box and draw arrows on your screen;
annotation-helper turns it into a session folder any agent can read: annotated screenshots,
zoomed crops of every annotation, the UI element under each one, and an offline transcript of
what you said, tied together in `brief.md`. Agents can also ask you to point at things on your
screen through its MCP server.

- **One executable, nothing to install.** Windows (`.exe`, 3.8 MB) and Linux (X11 and
  Wayland, 3.3 MB), with speech recognition (whisper.cpp) built in.
- **Private by design.** Recording, transcription and everything else run locally; nothing is
  sent over the network.
- **Light.** It waits in the tray using 3–5 MB of memory and only does work while you
  record.
- **Written in Zig**, built from source with a single `zig build` for both platforms.

## Contents

- [Install](#install)
- [Using it](#using-it)
- [Settings](#settings)
- [Agent integration (MCP)](#agent-integration-mcp)
- [Command line](#command-line)
- [Building from source](#building-from-source)
- [How it works](#how-it-works)

## Install

### Windows

1. Put `annotation-helper.exe` in a folder of its own, e.g. `C:\Users\<you>\annotation-helper\`.
2. Download a speech model into a `models` folder next to it (see [Speech model](#speech-model)).
3. Double-click the exe. To start it with Windows, put a shortcut to it into
   `shell:startup`.

`config.json` and the `sessions` folder are created next to the exe.

### Linux

```sh
install -Dm755 annotation-helper ~/.local/bin/annotation-helper
mkdir -p ~/.local/share/annotation-helper/models
curl -L -o ~/.local/share/annotation-helper/models/ggml-small-q5_1.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin

# Start it with every login:
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/dev.annotationhelper.AnnotationHelper.desktop <<EOF
[Desktop Entry]
Type=Application
Name=annotation-helper
Exec=$HOME/.local/bin/annotation-helper
X-GNOME-Autostart-enabled=true
EOF
```

Requirements: an X11 or Wayland desktop session with D-Bus, and glibc 2.29 or newer (any
distribution from 2019 on). No other libraries are needed at build or install time.
Recommended extras:

| What | Why |
|---|---|
| `wl-clipboard` (Wayland) or `xclip` / `xsel` (X11) | copies the hand-off prompt to the clipboard |
| `xdg-desktop-portal` with your desktop's backend | screenshots and global shortcuts on Wayland (installed by default on GNOME and KDE) |
| GNOME: the AppIndicator extension | shows the tray icon (Ubuntu ships it; KDE, XFCE, Cinnamon, MATE and waybar need nothing) |

Settings live in `~/.config/annotation-helper/config.json`, sessions and models in
`~/.local/share/annotation-helper/`. To keep everything next to the executable instead (for
example on a USB stick), put a `config.json` beside it.

### Speech model

Any whisper.cpp model (`ggml-*.bin`) works. If there are several, the most capable one is
used (large, then turbo, medium, small, base, tiny). A good
default is `ggml-small-q5_1.bin`: 181 MB, multilingual, and faster than real time on a
laptop CPU (13 s of speech in about 7 s):

```sh
curl -L -o models/ggml-small-q5_1.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin
```

Models are looked up in `models/` next to the executable and, on Linux, in
`~/.local/share/annotation-helper/models/`. `config.json` (`"model"`) or `--model FILE` picks
a specific file. Without a model, sessions are still saved, just without a transcript.

## Using it

annotation-helper runs in the tray (notification area). There is no main window; only one
instance runs at a time. The tray menu starts and stops recording, starts drawing, opens the
last brief and the sessions folder, changes hotkeys, opens `config.json` and quits. The icon
gets a red dot while recording.

| Hotkey (default) | Action |
|---|---|
| `Ctrl+Alt+R` | start / stop a session (records the microphone) |
| `Ctrl+Alt+D` | draw on the screen (starts a session if needed) / finish the screenshot |

While drawing:

| Key | Action |
|---|---|
| `P` · `R` · `E` · `A` · `H` | pen (default) · rectangle · ellipse · arrow · highlighter |
| `1` – `4` | red · green · blue · yellow |
| `Ctrl+Z` / `Backspace` · `Del` | undo · clear all |
| `Esc`, `Enter`, `Space` or right-click | finish the screenshot |

Every annotation gets a numbered badge (`#1`, `#2`, …) so you and the agent can refer to it.
A session can hold many screenshots: draw, finish, carry on working while you keep talking,
draw again. When you stop the session, it is transcribed in the background. A notification
tells you when `brief.md` is ready, and a hand-off prompt pointing at it is on the clipboard,
ready to paste into Claude Code or any other agent. Click the notification to show the files.

### What a session contains

Each session is a folder named after its start time (`sessions/2026-11-10_14-03-12/`):

```
brief.md            timeline: what you said, interleaved with the screenshots and their annotations
session.json        frames, strokes (coordinates, timing) and the UI element under each annotation
transcript.json     speech segments with session timestamps
audio.wav           microphone recording (16 kHz mono)
frame-NN.png        annotated screenshot (only the monitors you drew on)
frame-NN-clean.png  the same screenshot without drawings
frame-NN-aMM.png    zoomed crop around annotation #MM
process.log         output of the transcription step
```

In `brief.md`, each annotation is listed with its badge, shape, color and time, and with the
UI element under it, e.g. *#2 arrow (blue) · from: button "Save" · in Code — "app.ts" · to:
text box "Name"*. Arrows record both ends.

### Windows and Linux

Drawing works a little differently on the two systems:

- **Windows** draws on a transparent layer over your live screen. The app underneath keeps
  focus, and the screenshot is taken when you finish.
- **Linux** takes the screenshot first and shows it full-screen, slightly dimmed; you draw on
  that still image. This works the same on X11 and on every Wayland desktop, because Wayland
  doesn't let apps draw over other windows or read the screen at will.

On Wayland, the desktop provides two things through `xdg-desktop-portal`:

- **Screenshots.** Some desktops ask for permission the first time.
- **Global hotkeys** (KDE, GNOME 48+, Hyprland). The desktop asks you to confirm them once;
  change them later via tray menu → **Change shortcuts…**. On desktops without this portal
  (e.g. Sway), bind the commands `annotation-helper draw` and `annotation-helper toggle` to keys
  in your desktop's keyboard settings; the app tells you when that's needed.

UI elements come from the system's accessibility interface: UI Automation on Windows, AT-SPI
on Linux (GTK, Qt, LibreOffice, Firefox, and Chromium/Electron apps with accessibility
enabled). On Wayland, apps don't report where their elements are on screen, so there the app
and window under each annotation are named, not the element itself.

## Settings

`config.json` is created on first start:

```json
{
  "hotkeys": { "session": "Ctrl+Alt+R", "draw": "Ctrl+Alt+D" },
  "language": null,
  "model": null,
  "sessions_dir": null
}
```

| Key | Meaning |
|---|---|
| `hotkeys` | `Ctrl`, `Alt`, `Shift` and `Win` (or `Super`) plus a key, e.g. `"Ctrl+Shift+F9"`; F-keys also work alone |
| `language` | speech language such as `"de"` or `"en"`; `null` detects it |
| `model` | path of a whisper model file; `null` picks one from `models/` |
| `sessions_dir` | where sessions are stored |

To change a hotkey from the tray menu (Windows and X11), open **Hotkeys**, pick one and press
the new combination; `Esc` cancels. If another app already owns the combination, the old
hotkey stays and a notification says why. Command-line flags override `config.json`.

## Agent integration (MCP)

`annotation-helper mcp` is an MCP server on stdio. Agents can browse your sessions and ask
you to point at things on your screen.

| Tool | What it does |
|---|---|
| `list_sessions` | recorded sessions, newest first: duration, screenshots, apps, first words said |
| `get_session` | the brief plus annotated screenshots and per-annotation zoom crops as images (≤ 1568 px); no id = latest |
| `get_image` | any image of a session, e.g. `frame-01-clean.png`, at a chosen size |
| `annotate_screen` | shows the agent's question in a banner on your screen; you draw (and talk), `Esc` sends, `Shift+Esc` cancels; returns the result like `get_session` |

Register it with your agents (on Linux, use the path of the Linux executable; from WSL, point
at the Windows `.exe` so questions appear on your Windows desktop):

```sh
EXE=/mnt/c/Users/<you>/annotation-helper/annotation-helper.exe   # or ~/.local/bin/annotation-helper
claude  mcp add annotation-helper -s user -- $EXE mcp
codex   mcp add annotation-helper -- $EXE mcp     # then set  tool_timeout_sec = 900  in ~/.codex/config.toml
copilot mcp add annotation-helper -- $EXE mcp     # then set  "timeout": 900000  in ~/.copilot/mcp-config.json
agy     mcp add annotation-helper $EXE mcp
```

`annotate_screen` waits until you answer (10 minutes by default), so give your client a long
tool timeout (Claude Code: `MCP_TOOL_TIMEOUT`, in ms). Requests are stored as normal sessions;
cancelled ones are deleted. The MCP server registers no hotkeys and runs alongside the tray
app.

**Skill.** A registered server only makes the tools available; agents still ask questions in
text out of habit. The skill in [`skills/annotation-helper/`](skills/annotation-helper/SKILL.md)
tells them when to use the tools: reading a session you mention, asking *on the screen*
whenever the answer is a place there, and letting you mark what is still wrong after a visible
change. Install it once per agent:

```sh
mkdir -p ~/.agents/skills && cp -r skills/annotation-helper ~/.agents/skills/   # Codex, Copilot CLI
ln -s ~/.agents/skills/annotation-helper ~/.claude/skills/                       # Claude Code
mkdir -p ~/.gemini/config/skills && ln -s ~/.agents/skills/annotation-helper ~/.gemini/config/skills/   # agy
```

## Command line

```
annotation-helper [record] [--out DIR] [--lang CODE] [--model FILE] [--no-audio] [--no-process]
annotation-helper process <SESSION_DIR> [--lang CODE] [--model FILE] [--no-clipboard]
annotation-helper mcp [--out DIR] [--lang CODE] [--model FILE]
annotation-helper selftest [--audio-file WAV] [--out DIR]
annotation-helper mictest
annotation-helper draw | toggle | quit        (Linux)
```

| Command | What it does |
|---|---|
| `record` (default) | the tray app |
| `process` | transcribes a session again and rewrites its brief |
| `mcp` | the MCP server (see above) |
| `selftest` | draws a scripted screenshot, saves it and processes it: an end-to-end check |
| `mictest` | opens the default microphone for 2 s and reports what arrived; stores nothing |
| `draw`, `toggle`, `quit` | control the running app, e.g. from keyboard shortcuts on desktops without global shortcuts |

On Windows the exe has no console of its own; run from a terminal, its output appears there.

When the Linux build runs inside WSL, its MCP server offers only the read tools, since the
screen to annotate is the Windows one. `ANNOTATION_HELPER_LINUX_UI=1` turns `annotate_screen`
on anyway.

## Building from source

The whole build is one `zig build`: Zig compiles the app, whisper.cpp and the C helpers, and
cross-compiles, so both targets build on one Linux (or WSL) machine. No CMake, MinGW or
system libraries are involved.

1. Install [Zig 0.17.0](https://ziglang.org/download/), for example into `.tools/` (ignored by git):

   ```sh
   mkdir -p .tools && curl -L https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz | tar -xJ -C .tools
   export PATH="$PWD/.tools/zig-x86_64-linux-0.17.0:$PATH"
   ```

2. Build:

   ```sh
   zig build --release=safe                                 # Windows: zig-out/bin/annotation-helper.exe
   zig build --release=safe -Dtarget=x86_64-linux-gnu       # Linux:   zig-out/bin/annotation-helper
   zig build test-exe [-Dtarget=x86_64-linux-gnu]           # unit tests: zig-out/bin/tests(.exe)
   ```

The dependencies (whisper.cpp 1.8.3, zigwin32 and stb, each pinned by hash) are fetched on the
first build. whisper.cpp is compiled with the same flags as its CMake build, for x86-64 CPUs
with AVX2 (Intel and AMD since about 2013).

Release builds are **ReleaseSafe**: bounds and overflow checks stay on, so a bug stops with a
clear message instead of corrupting memory. Transcription speed is unaffected, since
whisper.cpp is always optimized fully. On Windows, crash reports go to `crash.log` next to the
exe, with the image base needed to resolve the addresses against
`zig-out/bin/annotation-helper.pdb`.

For automated checks without anyone at the screen: `ANNOTATION_HELPER_TEST_AUTODRAW=1` makes
`annotate_screen` draw scripted annotations after 1.5 s and send them, and on Linux
`ANNOTATION_HELPER_TEST_SCREENSHOT=file.png` replaces the screenshot.

### Project layout

```
build.zig            build for both targets, including whisper.cpp
src/main.zig         command line
src/app.zig          Windows: tray, hotkeys, drawing overlay, requests
src/worker.zig       Windows: UI Automation lookups, PNGs, session.json, transcription
src/com.zig          Windows: UI Automation and WIC (COM)
src/linux/           Linux: app, worker, and clients for X11, Wayland, D-Bus, AT-SPI, portals, tray
src/raster.zig       anti-aliased rendering of annotations (shared)
src/process.zig      transcription and brief.md (shared)
src/mcp.zig          MCP server (shared)
src/model.zig        session.json / transcript.json types (shared)
csrc/                C helpers: whisper call, miniaudio, stb (PNG, text)
skills/              the agent skill
```

## How it works

**Shared by both platforms**

- **Annotations** are rendered by a small anti-aliased rasterizer (`src/raster.zig`) into
  dirty rectangles, so drawing stays smooth at any screen size.
- **Audio:** miniaudio (part of whisper.cpp) records straight to a 16 kHz mono WAV, the format
  whisper wants.
- **Transcription:** after a session, the app starts itself again as `process`, so whisper's
  memory is returned to the system as soon as it finishes. Speech segments that fall into
  silence are dropped, which filters out whisper's occasional invented text.
- **MCP:** newline-delimited JSON-RPC over stdio; each tool call runs on its own thread, so
  `annotate_screen` can wait for you without blocking other requests.

**Windows**

- **Overlay:** a layered, topmost window that never takes focus, over the whole virtual
  screen. It exists only while you draw. A low-level keyboard hook, also installed only while
  drawing, keeps tool keys away from the app below.
- **Capture:** when you finish, the overlay is hidden, `DwmFlush` waits for the screen to
  update, and `BitBlt` captures the monitors you drew on. The status pill and request banner
  are excluded from capture. PNGs are written with WIC.
- **UI elements:** UI Automation `ElementFromPoint` at each annotation's center (arrows: both
  ends), with the element's name, type, ancestors, process, window and the text line under
  the point. A warm-up query when drawing starts makes Chromium/Electron apps build their
  accessibility tree in time.
- **Tray:** `Shell_NotifyIcon` with icons drawn at runtime; the menu follows the system's dark
  mode.

**Linux** (`src/linux/`)

- **Display:** X11 and Wayland are spoken directly over their wire protocols, so no libX11 or
  libwayland is needed. X11: the screen is read with `GetImage`, drawing happens in an
  override-redirect window with keyboard and pointer grabs, hotkeys use `GrabKey`, monitors
  come from RandR and the active window from EWMH. Wayland: the screenshot comes from the
  portal, then one full-screen window per monitor shows it (double-buffered shared memory,
  HiDPI-scaled with `wp_viewporter`), and keyboard layouts come from libxkbcommon, loaded at
  runtime.
- **D-Bus** (own client, `dbus.zig`): tray icon (StatusNotifierItem with a dbusmenu menu),
  notifications, the Screenshot and GlobalShortcuts portals, the single-instance check and the
  `draw` / `toggle` / `quit` commands (bus name `dev.annotationhelper.AnnotationHelper`).
- **UI elements:** AT-SPI point lookups, verified against each element's bounds with a search
  by bounds as fallback (some toolkits answer point queries wrongly), plus the text line under
  the point.
- **Microphone:** PulseAudio (also PipeWire's PulseAudio server) or ALSA, loaded at runtime.
