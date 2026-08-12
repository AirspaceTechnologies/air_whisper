#!/bin/bash
# diagnose.sh — capture evidence when dictation misbehaves, BEFORE killing anything.
# Collects: a thread sample of Hammerspoon (shows where a frozen event loop is
# stuck), the unified system log for Hammerspoon, and the dictation log.
set -uo pipefail

OUT="$HOME/Desktop/hs-diagnostics-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "Collecting into $OUT …"

if pgrep -x Hammerspoon >/dev/null 2>&1; then
  echo "- sampling Hammerspoon main thread (5s)…"
  sample Hammerspoon 5 -file "$OUT/hammerspoon-sample.txt" >/dev/null 2>&1 \
    || echo "  (sample failed — continuing)"
else
  echo "- Hammerspoon is not running (no sample possible)"
fi

echo "- unified log, last 30 min…"
log show --predicate 'process == "Hammerspoon"' --last 30m \
  > "$OUT/hammerspoon-system-log.txt" 2>&1 || true

echo "- dictation log…"
cp "$HOME/.dictate/log.txt" "$OUT/dictate-log.txt" 2>/dev/null || true

echo "- process states…"
{ pgrep -fl "ffmpeg|whisper-server|Hammerspoon" || echo "(none running)"; } \
  > "$OUT/processes.txt" 2>&1
ls -la "$HOME/.dictate/tmp/" >> "$OUT/processes.txt" 2>&1 || true

echo
echo "Done: $OUT"
echo "Now it's safe to restart: open -a Hammerspoon (or 🎤 menu → Restart dictation)"
