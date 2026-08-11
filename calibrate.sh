#!/bin/bash
# calibrate.sh — pair two identically-named display microphones with their screens.
#
# macOS does not expose which "Studio Display Microphone" belongs to which
# physical display, so we measure it: record from BOTH mics at once while you
# scratch near the LEFT display, and the louder recording identifies it.
# Writes the screen→mic map into Hammerspoon settings and reloads.
#
# Requires: setup.sh done, Hammerspoon running with permissions granted,
# and exactly two screens connected (otherwise assign via the 🎤 menu).
set -euo pipefail

FF="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"
HS="$(command -v hs || echo /opt/homebrew/bin/hs)"
T="$HOME/.dictate/tmp"
mkdir -p "$T"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

"$HS" -c 'print("ok")' >/dev/null 2>&1 \
  || die "Can't reach Hammerspoon. Is it running with permissions granted? (run ./setup.sh first)"

# ---- find the mic name that appears exactly twice --------------------------
DEVLIST="$("$FF" -f avfoundation -list_devices true -i "" 2>&1 \
  | sed -n '/AVFoundation audio devices:/,$p' | grep -E '\[[0-9]+\]' \
  | sed -E 's/^\[[^]]*\] \[([0-9]+)\] (.*)$/\1\t\2/')"
DUP_NAME="$(printf '%s\n' "$DEVLIST" | cut -f2 | sort | uniq -c | awk '$1 == 2 {sub(/^ *2 /,""); print; exit}')"
[[ -n "$DUP_NAME" ]] || die "No microphone name appears exactly twice — nothing to calibrate."
I1="$(printf '%s\n' "$DEVLIST" | awk -F'\t' -v n="$DUP_NAME" '$2 == n {print $1; exit}')"
I2="$(printf '%s\n' "$DEVLIST" | awk -F'\t' -v n="$DUP_NAME" '$2 == n {c++; if (c == 2) {print $1; exit}}')"
echo "Calibrating: \"$DUP_NAME\" (1) = device $I1, (2) = device $I2"

# ---- screens, left to right ------------------------------------------------
SCREENS="$("$HS" -c 'local ss = hs.screen.allScreens()
table.sort(ss, function(a,b) return a:frame().x < b:frame().x end)
for _, s in ipairs(ss) do print(s:getUUID() .. "\t" .. (s:name() or "Display")) end')"
[[ "$(printf '%s\n' "$SCREENS" | wc -l | tr -d ' ')" == "2" ]] \
  || die "Calibration supports exactly two screens; use 🎤 menu → Assign screen mics instead."
LEFT_UUID="$(printf '%s\n' "$SCREENS" | sed -n 1p | cut -f1)"
LEFT_NAME="$(printf '%s\n' "$SCREENS" | sed -n 1p | cut -f2)"
RIGHT_UUID="$(printf '%s\n' "$SCREENS" | sed -n 2p | cut -f1)"
RIGHT_NAME="$(printf '%s\n' "$SCREENS" | sed -n 2p | cut -f2)"

# ---- record both mics while the user scratches near the LEFT display -------
echo "When the on-screen alert appears, SCRATCH near the LEFT display's camera for ~7s."
"$FF" -y -f avfoundation -audio_device_index "$I1" -i ":" -ar 16000 -ac 1 \
  -acodec pcm_s16le -t 8 "$T/cal_1.wav" >/dev/null 2>&1 &
P1=$!
"$FF" -y -f avfoundation -audio_device_index "$I2" -i ":" -ar 16000 -ac 1 \
  -acodec pcm_s16le -t 8 "$T/cal_2.wav" >/dev/null 2>&1 &
P2=$!
"$HS" -c 'for _, s in ipairs(hs.screen.allScreens()) do
  hs.alert.show("👈 SCRATCH near the LEFT display mic NOW!", {textSize=32}, s, 7)
end' >/dev/null 2>&1 || true
wait "$P1" "$P2"

vol() { "$FF" -i "$1" -af volumedetect -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2+0}'; }
V1="$(vol "$T/cal_1.wav")"
V2="$(vol "$T/cal_2.wav")"
rm -f "$T/cal_1.wav" "$T/cal_2.wav"
echo "mic (1): ${V1} dB   mic (2): ${V2} dB"
awk "BEGIN{exit !((($V1)-($V2))^2 >= 9)}" \
  || die "Inconclusive (< 3 dB apart). Re-run and scratch louder, directly on the display."

if awk "BEGIN{exit !($V1 > $V2)}"; then LEFT_MIC="$DUP_NAME (1)"; RIGHT_MIC="$DUP_NAME (2)"
else                                    LEFT_MIC="$DUP_NAME (2)"; RIGHT_MIC="$DUP_NAME (1)"
fi

# ---- write the map and reload ----------------------------------------------
"$HS" -c "hs.settings.set('dictate.screen_map', {
  [\"$LEFT_UUID\"]  = \"$LEFT_MIC\",
  [\"$RIGHT_UUID\"] = \"$RIGHT_MIC\",
}); hs.settings.set('dictate.mic_mode', 'auto'); hs.reload()" >/dev/null 2>&1 || true

echo
echo "Calibrated:"
echo "  $LEFT_NAME (left)   → $LEFT_MIC"
echo "  $RIGHT_NAME (right) → $RIGHT_MIC"
echo "Auto mic mode is ON. The pill names its mic on every dictation — verify on each screen."
