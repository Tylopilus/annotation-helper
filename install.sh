#!/usr/bin/env bash
# annotation-helper installer for Linux and WSL.
#
#   ./install.sh                 interactive
#   ./install.sh -y              accept all defaults (incl. MCP + skill for agents found)
#
# Step 1: downloads Zig 0.17.0 (unless installed), builds annotation-helper, installs it,
#         downloads the speech model and sets up autostart.
# Step 2: (asks first) registers the MCP server with the AI agents found on this machine
#         and installs the agent skill.
#
# Inside WSL it installs the Windows app by default (the screen you annotate is the Windows
# one); --target linux installs the Linux app instead.
set -euo pipefail

ZIG_VERSION=0.17.0
MODEL_NAME=ggml-small-q5_1.bin
MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME
APP_ID=dev.annotationhelper.AnnotationHelper
REPO_URL=https://github.com/Tylopilus/annotation-helper.git

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  -y, --yes             don't ask; accept the defaults
  --target linux|windows
                        what to install (default: windows inside WSL, linux elsewhere)
  --windows-dir DIR     Windows install folder, as a WSL path
                        (default: <your Windows profile>/annotation-helper)
  --bin-dir DIR         Linux: where the executable goes (default: ~/.local/bin)
  --no-model            don't download the speech model
  --no-autostart        don't start annotation-helper at login
  --no-agents           skip step 2 (MCP server and skill)
  -h, --help            this help
EOF
}

# ------------------------------------------------------------------ output helpers

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B= G= Y= R= N=; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

YES=0
# ask "Question" default(y|n) -> returns 0 for yes
ask() {
  local q=$1 def=${2:-y} ans hint
  [ "$def" = y ] && hint="[Y/n]" || hint="[y/N]"
  if [ "$YES" = 1 ]; then [ "$def" = y ]; return; fi
  if [ -r /dev/tty ]; then
    printf '%s?%s %s %s ' "$B" "$N" "$q" "$hint" >/dev/tty
    read -r ans </dev/tty || ans=
  else
    ans=
  fi
  ans=${ans:-$def}
  case $ans in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ options

TARGET= WIN_DIR= BIN_DIR="$HOME/.local/bin" DO_MODEL=1 DO_AUTOSTART=1 DO_AGENTS=1
while [ $# -gt 0 ]; do
  case $1 in
    -y | --yes) YES=1 ;;
    --target) TARGET=${2:?}; shift ;;
    --windows-dir) WIN_DIR=${2:?}; shift ;;
    --bin-dir) BIN_DIR=${2:?}; shift ;;
    --no-model) DO_MODEL=0 ;;
    --no-autostart) DO_AUTOSTART=0 ;;
    --no-agents) DO_AGENTS=0 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

# ------------------------------------------------------------------ environment

[ "$(uname -s)" = Linux ] || die "run this on Linux or in WSL (Windows: install WSL, or build with Zig and copy the .exe)"
IS_WSL=0
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi
if [ -z "$TARGET" ]; then [ "$IS_WSL" = 1 ] && TARGET=windows || TARGET=linux; fi
case $TARGET in linux | windows) ;; *) die "--target must be linux or windows" ;; esac
[ "$TARGET" = windows ] && [ "$IS_WSL" = 0 ] && [ -z "$WIN_DIR" ] && die "--target windows outside WSL needs --windows-dir"

for tool in curl tar xz; do command -v "$tool" >/dev/null || die "'$tool' is missing; install it with your package manager"; done

case $(uname -m) in
  x86_64 | amd64) HOST_ARCH=x86_64 ;;
  aarch64 | arm64) HOST_ARCH=aarch64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac
if [ "$TARGET" = linux ] && [ "$HOST_ARCH" != x86_64 ]; then
  die "annotation-helper runs on x86-64 only (whisper.cpp is built for AVX2)"
fi

# The source: this checkout, or a fresh clone when run via curl | bash.
SRC=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -z "$SRC" ] || [ ! -f "$SRC/build.zig" ]; then
  command -v git >/dev/null || die "'git' is missing"
  SRC="${XDG_CACHE_HOME:-$HOME/.cache}/annotation-helper/src"
  step "Getting the source"
  if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only -q; else git clone -q --depth 1 "$REPO_URL" "$SRC"; fi
  ok "$SRC"
fi
cd "$SRC"

win_profile() {
  # The Windows user profile as a WSL path (needs WSL interop).
  local p
  p=$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || return 1
  [ -n "$p" ] && wslpath -u "$p" 2>/dev/null
}

if [ "$TARGET" = windows ]; then
  if [ -z "$WIN_DIR" ]; then
    profile=$(win_profile || true)
    if [ -z "$profile" ]; then
      # No interop: guess the only personal user folder (not Windows' own or admin accounts
      # we can't write to), or ask for it.
      mapfile -t users < <(find /mnt/c/Users -mindepth 1 -maxdepth 1 -type d -writable \
        ! -name 'All Users' ! -name 'Default*' ! -name 'defaultuser*' ! -name Public ! -name 'adm-*' ! -name 'admin*' 2>/dev/null)
      [ "${#users[@]}" = 1 ] && profile=${users[0]}
    fi
    [ -n "$profile" ] || die "couldn't find your Windows user folder; pass --windows-dir /mnt/c/Users/<you>/annotation-helper"
    WIN_DIR="$profile/annotation-helper"
  fi
  INSTALL_DIR=$WIN_DIR
  EXE="$WIN_DIR/annotation-helper.exe"
  MODEL_DIR="$WIN_DIR/models"
else
  INSTALL_DIR=$BIN_DIR
  EXE="$BIN_DIR/annotation-helper"
  MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/annotation-helper/models"
fi

printf '%sannotation-helper installer%s\n' "$B" "$N"
info "installs:  the $TARGET app → $EXE"
[ "$DO_MODEL" = 1 ] && info "model:     $MODEL_DIR/$MODEL_NAME (181 MB, if no model is there yet)"
ask "Continue?" y || exit 0

# ------------------------------------------------------------------ step 1: Zig

step "Zig $ZIG_VERSION"
ZIG=
if command -v zig >/dev/null && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]; then
  ZIG=$(command -v zig)
  ok "using $ZIG"
else
  ZIG_DIR="$SRC/.tools/zig-$HOST_ARCH-linux-$ZIG_VERSION"
  if [ -x "$ZIG_DIR/zig" ]; then
    ok "using $ZIG_DIR (downloaded earlier)"
  else
    tarball="zig-$HOST_ARCH-linux-$ZIG_VERSION.tar.xz"
    info "downloading $tarball …"
    mkdir -p "$SRC/.tools"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fL --progress-bar -o "$tmp/$tarball" "https://ziglang.org/download/$ZIG_VERSION/$tarball"
    # Verify against the checksum ziglang.org publishes.
    want=
    if command -v python3 >/dev/null; then
      want=$(curl -fsSL https://ziglang.org/download/index.json | python3 -c \
        'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]]["shasum"])' \
        "$ZIG_VERSION" "$HOST_ARCH-linux" 2>/dev/null || true)
    fi
    if [ -n "$want" ]; then
      have=$(sha256sum "$tmp/$tarball" | cut -d' ' -f1)
      [ "$have" = "$want" ] || die "Zig download checksum mismatch (expected $want, got $have)"
      ok "checksum verified"
    else
      warn "couldn't fetch the published checksum; skipping verification"
    fi
    tar -xJf "$tmp/$tarball" -C "$SRC/.tools"
    ok "installed into $ZIG_DIR"
  fi
  ZIG="$ZIG_DIR/zig"
fi

# ------------------------------------------------------------------ step 1: build

step "Building (the first build compiles whisper.cpp and takes a few minutes)"
if [ "$TARGET" = windows ]; then
  "$ZIG" build --release=safe
  BUILT="$SRC/zig-out/bin/annotation-helper.exe"
else
  "$ZIG" build --release=safe -Dtarget=x86_64-linux-gnu
  BUILT="$SRC/zig-out/bin/annotation-helper"
fi
[ -f "$BUILT" ] || die "build produced no $BUILT"
ok "built $(basename "$BUILT") ($(du -h "$BUILT" | cut -f1))"

# ------------------------------------------------------------------ step 1: install

step "Installing"
mkdir -p "$INSTALL_DIR"
was_running=0
if [ "$TARGET" = windows ]; then
  # A running exe can't be replaced on Windows.
  if ! cp "$BUILT" "$EXE.new" 2>/dev/null; then die "can't write to $INSTALL_DIR"; fi
  if ! mv -f "$EXE.new" "$EXE" 2>/dev/null; then
    if command -v taskkill.exe >/dev/null && ask "annotation-helper is running. Quit it to replace it?" y; then
      taskkill.exe /IM annotation-helper.exe >/dev/null 2>&1 || true
      was_running=1
      sleep 2
      mv -f "$EXE.new" "$EXE" || die "couldn't replace $EXE; quit annotation-helper (tray icon → Quit) and run this again"
    else
      rm -f "$EXE.new"
      die "annotation-helper.exe is running; quit it (tray icon → Quit) and run this again"
    fi
  fi
else
  if [ -x "$EXE" ] && "$EXE" quit >/dev/null 2>&1; then was_running=1; sleep 1; fi
  install -m 755 "$BUILT" "$EXE"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on your PATH; add it to run 'annotation-helper' by name" ;; esac
fi
ok "$EXE"
# The license notices travel with the executable.
NOTICE_DIR=$INSTALL_DIR
[ "$TARGET" = linux ] && NOTICE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/annotation-helper"
mkdir -p "$NOTICE_DIR"
cp "$SRC/LICENSE" "$SRC/THIRD_PARTY_LICENSES.md" "$NOTICE_DIR/" 2>/dev/null || warn "couldn't copy the license files to $NOTICE_DIR"

# ------------------------------------------------------------------ step 1: model

step "Speech model"
if [ "$DO_MODEL" = 0 ]; then
  info "skipped (--no-model); without a model, sessions are saved without a transcript"
elif compgen -G "$MODEL_DIR/ggml-*.bin" >/dev/null; then
  ok "already there: $(cd "$MODEL_DIR" && ls ggml-*.bin | tr '\n' ' ')"
else
  mkdir -p "$MODEL_DIR"
  info "downloading $MODEL_NAME (181 MB) …"
  curl -fL --progress-bar -o "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_URL"
  size=$(stat -c %s "$MODEL_DIR/$MODEL_NAME.part")
  [ "$size" -gt 100000000 ] || { rm -f "$MODEL_DIR/$MODEL_NAME.part"; die "model download looks incomplete ($size bytes)"; }
  mv "$MODEL_DIR/$MODEL_NAME.part" "$MODEL_DIR/$MODEL_NAME"
  ok "$MODEL_DIR/$MODEL_NAME"
fi

# ------------------------------------------------------------------ step 1: autostart

step "Autostart"
if [ "$DO_AUTOSTART" = 0 ]; then
  info "skipped"
elif [ "$TARGET" = linux ]; then
  if ask "Start annotation-helper automatically when you log in?" y; then
    auto="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/$APP_ID.desktop"
    mkdir -p "$(dirname "$auto")"
    cat >"$auto" <<EOF
[Desktop Entry]
Type=Application
Name=annotation-helper
Comment=Narrate and annotate your screen for AI agents
Exec=$EXE
Icon=accessories-text-editor
X-GNOME-Autostart-enabled=true
EOF
    ok "$auto"
  fi
else
  if command -v powershell.exe >/dev/null; then
    if ask "Start annotation-helper automatically when you log in to Windows?" y; then
      win_exe=$(wslpath -w "$EXE")
      powershell.exe -NoProfile -Command "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup')+'\\annotation-helper.lnk'); \$s.TargetPath='$win_exe'; \$s.Save()" >/dev/null &&
        ok "shortcut in your Startup folder" || warn "couldn't create the Startup shortcut"
    fi
  else
    info "to start it with Windows, put a shortcut to $(wslpath -w "$EXE" 2>/dev/null || echo "$EXE") into shell:startup"
  fi
fi

# ------------------------------------------------------------------ step 1: start

if [ "$TARGET" = linux ] && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; } && [ "$IS_WSL" = 0 ]; then
  if [ "$was_running" = 1 ] || ask "Start annotation-helper now?" y; then
    setsid -f "$EXE" >/dev/null 2>&1 </dev/null && ok "started (look for the tray icon)"
  fi
elif [ "$TARGET" = windows ] && command -v cmd.exe >/dev/null; then
  if [ "$was_running" = 1 ] || ask "Start annotation-helper now?" y; then
    (cd "$INSTALL_DIR" && cmd.exe /c start "" "$(wslpath -w "$EXE")" >/dev/null 2>&1) && ok "started (look for the tray icon)"
  fi
fi

# ------------------------------------------------------------------ step 2: agents

register_agents() {
  local agents=() cmd=$EXE
  command -v claude >/dev/null && agents+=("Claude Code")
  { command -v codex >/dev/null || [ -f "$HOME/.codex/config.toml" ]; } && agents+=("Codex")
  { command -v copilot >/dev/null || [ -f "$HOME/.copilot/mcp-config.json" ]; } && agents+=("Copilot CLI")
  { command -v agy >/dev/null || [ -d "$HOME/.gemini/config" ]; } && agents+=("Antigravity")
  if [ "${#agents[@]}" = 0 ]; then
    info "no supported agent found (Claude Code, Codex, Copilot CLI, Antigravity)"
    info "register it yourself: command \"$cmd\", argument \"mcp\""
    return
  fi
  local py=python3
  command -v $py >/dev/null || py=

  if command -v claude >/dev/null; then
    claude mcp remove annotation-helper -s user >/dev/null 2>&1 || true
    if claude mcp add annotation-helper -s user -- "$cmd" mcp >/dev/null 2>&1; then ok "Claude Code"; else warn "Claude Code: 'claude mcp add' failed"; fi
  fi
  if [[ " ${agents[*]} " == *" Codex "* ]]; then
    local f="$HOME/.codex/config.toml"
    mkdir -p "$(dirname "$f")"
    touch "$f"
    # Replace our [mcp_servers.annotation-helper] table (if any) and append a fresh one.
    awk '/^\[/{skip = ($0 == "[mcp_servers.annotation-helper]" || index($0, "[mcp_servers.annotation-helper.") == 1)} !skip' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    printf '\n[mcp_servers.annotation-helper]\ncommand = "%s"\nargs = ["mcp"]\n# annotate_screen waits up to 10 min for the user to draw and talk\ntool_timeout_sec = 900\n' "$cmd" >>"$f"
    ok "Codex ($f)"
  fi
  if [[ " ${agents[*]} " == *" Copilot CLI "* ]]; then
    if [ -n "$py" ]; then
      $py - "$HOME/.copilot/mcp-config.json" "$cmd" <<'PY' && ok "Copilot CLI (~/.copilot/mcp-config.json)" || warn "Copilot CLI: couldn't update its config"
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
data.setdefault("mcpServers", {})["annotation-helper"] = {
    "type": "local", "command": cmd, "args": ["mcp"], "tools": ["*"], "timeout": 900000}
json.dump(data, open(path, "w"), indent=2)
PY
    else warn "Copilot CLI: needs python3 to edit its config"; fi
  fi
  if [[ " ${agents[*]} " == *" Antigravity "* ]]; then
    if [ -n "$py" ]; then
      $py - "$HOME/.gemini/config/mcp_config.json" "$cmd" <<'PY' && ok "Antigravity (~/.gemini/config/mcp_config.json)" || warn "Antigravity: couldn't update its config"
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
data.setdefault("mcpServers", {})["annotation-helper"] = {"command": cmd, "args": ["mcp"], "disabled": False}
json.dump(data, open(path, "w"), indent=2)
PY
    else warn "Antigravity: needs python3 to edit its config"; fi
  fi
  info "Claude Code: if long questions time out, set MCP_TOOL_TIMEOUT=900000 (ms)"
}

install_skill() {
  local dest="$HOME/.agents/skills/annotation-helper"
  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  cp -r "$SRC/skills/annotation-helper" "$dest"
  ok "$dest (Codex, Copilot CLI)"
  local link
  for link in "$HOME/.claude/skills" "$HOME/.gemini/config/skills"; do
    [ -d "$(dirname "$link")" ] || continue
    mkdir -p "$link"
    if [ -L "$link/annotation-helper" ] || [ ! -e "$link/annotation-helper" ]; then
      ln -sfn "$dest" "$link/annotation-helper"
      ok "$link/annotation-helper → $dest"
    else
      rm -rf "$link/annotation-helper" && cp -r "$dest" "$link/annotation-helper" && ok "$link/annotation-helper (updated copy)"
    fi
  done
}

if [ "$DO_AGENTS" = 1 ]; then
  step "AI agents (optional)"
  info "The MCP server lets agents read your sessions and ask you to point at things on screen."
  info "The skill tells them when to use it."
  if ask "Register the MCP server with your AI agents (replaces an existing 'annotation-helper' entry)?" y; then
    register_agents
  fi
  if ask "Install the agent skill?" y; then
    install_skill
  fi
fi

step "Done"
if [ "$TARGET" = windows ]; then
  info "Ctrl+Alt+D draws on the screen, Ctrl+Alt+R starts/stops recording."
else
  info "Ctrl+Alt+D draws on the screen, Ctrl+Alt+R starts/stops recording (on Wayland the"
  info "desktop may ask to confirm these shortcuts)."
fi
info "Sessions, settings and more: ${REPO_URL%.git}#readme"
