#!/bin/bash
# setup.sh — install everything for local push-to-talk dictation (idempotent).
# Usage: ./setup.sh [--with-medium]
set -euo pipefail

DICTATE_DIR="$HOME/.dictate"
MODELS_DIR="$DICTATE_DIR/models"
HS_DIR="$HOME/.hammerspoon"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
HF_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
SMALL_MIN_BYTES=450000000    # small.en is ~466 MB; fail loudly on truncation
MEDIUM_MIN_BYTES=1400000000  # medium.en is ~1.5 GB

WITH_MEDIUM=0
if [[ "${1:-}" == "--with-medium" ]]; then WITH_MEDIUM=1; fi

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. Homebrew
command -v brew >/dev/null 2>&1 \
  || die "Homebrew is required. Install it from https://brew.sh and re-run ./setup.sh"

# ---------------------------------------------------------------- 2. Packages
bold "Checking packages…"
command -v ffmpeg >/dev/null 2>&1 || brew install ffmpeg
command -v whisper-server >/dev/null 2>&1 || command -v whisper-cli >/dev/null 2>&1 \
  || brew install whisper-cpp
if [[ ! -d /Applications/Hammerspoon.app && ! -d "$HOME/Applications/Hammerspoon.app" ]]; then
  # --appdir avoids the sudo prompt some machines need for /Applications
  brew install --cask hammerspoon --appdir="$HOME/Applications"
fi

FFMPEG_BIN="$(command -v ffmpeg)"
WHISPER_SERVER="$(command -v whisper-server || true)"
WHISPER_CLI="$(command -v whisper-cli || command -v whisper-cpp || true)"
[[ -n "$WHISPER_SERVER" || -n "$WHISPER_CLI" ]] || die "whisper binaries missing after install"
TRANSCRIBE_MODE="server"
[[ -z "$WHISPER_SERVER" ]] && TRANSCRIBE_MODE="cli"

# ---------------------------------------------------------------- 3. Models
bold "Checking models…"
mkdir -p "$MODELS_DIR" "$DICTATE_DIR/tmp"

download_model() { # file min_bytes
  local dest="$MODELS_DIR/$1"
  if [[ -f "$dest" ]] && (( $(stat -f%z "$dest") >= $2 )); then
    echo "$1 already present"
    return
  fi
  echo "Downloading $1 …"
  curl -L --fail --progress-bar -o "$dest" "$HF_BASE/$1"
  (( $(stat -f%z "$dest") >= $2 )) || die "$1 looks truncated — delete it and re-run"
}
download_model "ggml-small.en.bin" "$SMALL_MIN_BYTES"
if (( WITH_MEDIUM )); then download_model "ggml-medium.en.bin" "$MEDIUM_MIN_BYTES"; fi

# ---------------------------------------------------------------- 4. Config
if [[ -f "$DICTATE_DIR/config.lua" ]]; then
  bold "Config exists — leaving $DICTATE_DIR/config.lua untouched."
else
  bold "Choose a fallback microphone (auto/fixed choices live in the menu later)."
  echo "Current audio input devices:"
  "$FFMPEG_BIN" -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n '/AVFoundation audio devices:/,$p' | grep -E '\[[0-9]+\]' \
    | sed -E 's/^\[[^]]*\] //' || true
  printf '\n'
  read -rp "Fallback mic NAME [MacBook Pro Microphone]: " MIC_NAME || true
  MIC_NAME="${MIC_NAME:-MacBook Pro Microphone}"
  sed -e "s|__MIC_NAME__|$MIC_NAME|" \
      -e "s|__SERVER_BIN__|$WHISPER_SERVER|" \
      -e "s|__CLI_BIN__|$WHISPER_CLI|" \
      -e "s|__FFMPEG_BIN__|$FFMPEG_BIN|" \
      -e "s|__TRANSCRIBE_MODE__|$TRANSCRIBE_MODE|" \
      "$REPO_DIR/config.template.lua" > "$DICTATE_DIR/config.lua"
  echo "Wrote $DICTATE_DIR/config.lua"
fi

# ---------------------------------------------------------------- 5. Hammerspoon module
bold "Installing Hammerspoon module…"
mkdir -p "$HS_DIR"
cp "$REPO_DIR/dictate.lua" "$HS_DIR/dictate.lua"
touch "$HS_DIR/init.lua"
grep -q 'require("hs.ipc")' "$HS_DIR/init.lua" || echo 'require("hs.ipc")' >> "$HS_DIR/init.lua"
grep -q 'require("dictate")' "$HS_DIR/init.lua" || echo 'require("dictate")' >> "$HS_DIR/init.lua"

if pgrep -x Hammerspoon >/dev/null 2>&1; then
  if command -v hs >/dev/null 2>&1; then
    # the reload tears down the IPC port mid-call, so ignore the exit code
    hs -c "hs.reload()" >/dev/null 2>&1 || true
    echo "→ Reloaded Hammerspoon config."
  else
    echo "→ Hammerspoon is running: reload its config from the menu bar (🔨 → Reload Config)"
  fi
else
  open -a Hammerspoon || true
fi

# ---------------------------------------------------------------- 6. Manual steps
bold "Done. Two permissions + one keyboard setting need YOU (macOS won't script them):"
cat <<'EOF'
  1. System Settings → Privacy & Security → Microphone     → enable Hammerspoon
  2. System Settings → Privacy & Security → Accessibility  → enable Hammerspoon
     (if macOS also prompts for Input Monitoring, grant that too)
  3. System Settings → Keyboard → "Press 🌐 key to" → Do Nothing
     (otherwise the fn key also triggers the emoji picker / Apple Dictation)

Restart Hammerspoon after granting permissions.

Then: hold fn anywhere, speak, release. Text lands at your cursor.
Mic selection lives in the 🎤 menu bar icon.
Two same-model displays with built-in mics? Run ./calibrate.sh to pair
each screen with its own microphone automatically.
EOF
