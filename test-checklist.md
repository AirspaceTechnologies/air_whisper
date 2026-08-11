# Manual QA checklist

Basics
- [ ] Dictate into TextEdit — text lands at cursor
- [ ] Dictate into VS Code
- [ ] Dictate into a terminal
- [ ] Dictate into a browser textarea (e.g. a GitHub comment box)
- [ ] Brief tap of fn (< 0.5 s) inserts nothing, no error
- [ ] 60-second monologue transcribes correctly
- [ ] A recording that hits the 120 s `max_duration_s` cap still transcribes

Clipboard
- [ ] Copy some text, dictate — the copied text is back on the clipboard afterwards
- [ ] Copy an **image** (screenshot), dictate — the image survives on the clipboard

Hotkey edge cases
- [ ] fn+arrow / fn+delete do NOT trigger dictation and the keystroke works normally
- [ ] Pressing fn while a transcription is still running is ignored
- [ ] Dictation with music playing in the background still transcribes speech

Mic selection
- [ ] Auto mode: focus a window on each display in turn, dictate — the pill (and
      `~/.dictate/log.txt`) names that display's own mic each time
- [ ] Pick a fixed mic in the 🎤 menu — it sticks after a Hammerspoon reload
- [ ] Connect/disconnect AirPods or an iPhone mid-session, open the menu — the
      device list is current; dictation still works
- [ ] Unplug/disable an assigned mic and dictate — one alert, falls back, still works

Pipeline edge cases
- [ ] First dictation right after a Hammerspoon reload (server warm-up) — auto-retry covers it
- [ ] `pkill whisper-server`, then dictate — server restarts, retry succeeds
- [ ] Silence-only dictation (hold, say nothing, release) inserts nothing
- [ ] `~/.dictate/tmp/` contains no `rec.wav` after any of the above

Privacy spot-checks
- [ ] `~/.dictate/log.txt` contains no transcript text
- [ ] With Little Snitch / `nettop`: no non-loopback traffic during dictation
