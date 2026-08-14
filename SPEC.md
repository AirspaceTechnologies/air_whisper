# Local Push-to-Talk Dictation PoC (Tier 1)

Build a local, privacy-first push-to-talk dictation tool for macOS on Apple Silicon, in this repo. Everything runs 100% on-device: the only network activity at runtime is HTTP over the loopback interface to a local whisper-server; nothing leaves the machine. No cloud APIs, no accounts, no telemetry. This is an internal proof of concept — favor simplicity and auditability over features. A reviewer should be able to read the entire codebase in ten minutes.

Machine facts (verified 2026-08-11): Homebrew and ffmpeg are installed; whisper-cpp and Hammerspoon are not. This machine has **two Studio Displays**, each with its own microphone — avfoundation lists "Studio Display Microphone" twice, plus the MacBook Pro mic, a Continuity iPhone mic that comes and goes, and ZoomAudioDevice. Device indices reshuffle as devices appear/disappear, and duplicate names cannot be distinguished by name alone — the mic-selection design below exists because of this.

## User experience

1. Hold the **fn (Globe) key** alone as push-to-talk: key-down starts recording, key-up stops. Remappable via config to one of: `fn`, `rightalt`, `rightcmd`, `rightctrl`.
   - Requires System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** — otherwise pressing fn alone also triggers the emoji picker / input-source switch / Apple Dictation. `setup.sh` prints this step; README documents it.
2. While held: record from the active microphone (see Microphone selection) and show the recording indicator.
3. On release: transcribe via the local whisper-server, clean up the text, and insert it at the current cursor position in whatever app is frontmost (VS Code, Slack, Chrome, Terminal — anywhere).
4. Latency target after release: **under ~1.5 s** for a 10-second utterance with small.en on an M-series Mac (the persistent server keeps the model loaded, so this is decode time plus overhead only).

## Microphone selection

Mic devices are dynamic on this machine, so selection is a runtime feature, not a setup-time constant.

- **Device identity** in the UI is `(name, occurrence)` — duplicates render as "Name (1)"/"(2)". At recording time the label resolves to the device's **global** AVFoundation index from the cached enumeration, passed as `-audio_device_index <global>` with a placeholder `-i ":"` (verified: the index is global and overrides any name; the help text's "for devices with same name" describes the use case, not the semantics).
- **Cached device list**: the module keeps an in-memory device list, refreshed by a cheap 2-second device-signature poll (`hs.audiodevice.allInputDevices()` UIDs, ~0.04 ms per check; the ffmpeg enumeration runs only when the signature changes) and whenever the menu opens. No Hammerspoon singleton is owned — an existing config's `hs.audiodevice.watcher` handler is untouched. Enumeration parses the stderr of `ffmpeg -f avfoundation -list_devices true -i ""`. Never enumerate at key-down — a subprocess there would delay capture start and clip the first words; key-down resolves the device from the cache instantly.
- **Menu bar dropdown** (the menu bar icon doubles as the menu):
  - **Auto — follow focused screen** (mode toggle, see below)
  - Radio list of currently-present input devices; duplicates rendered as "Studio Display Microphone (1)" / "(2)"
  - **Assign screen mics…** submenu: for each connected screen — identified by its persistent UUID, labeled with name and arrangement position, e.g. "Studio Display (left)" — pick which mic belongs to it
  - Menu selections persist via `hs.settings` and survive reloads; `~/.dictate/config.lua` holds the hand-edited defaults, `hs.settings` holds the runtime overrides.
- **Auto mode (the Wispr Flow behavior)**: at key-down, take the screen of the focused window (fallback: the screen containing the mouse pointer), look up its UUID in the screen→mic map, and record from that mic. Unmapped screen → fall back to the fixed selection → else avfoundation's `:default` device.
- **Why assignment is manual**: macOS does not expose which "Studio Display Microphone" belongs to which physical display, so pairing is a one-time manual step in the menu. Screen UUIDs are stable across reboots, so it sticks. Log which device each recording used (name + index), so a wrong pairing is diagnosable from the log.
- **Identity limitation (accepted)**: duplicate-name ordinals "(1)/(2)" are enumeration-order, not physical identity, and no UID↔avfoundation-index linkage exists in this stack (CoreAudio and AVFoundation order devices differently — verified). Calibration stores the twin group's CoreAudio UID **set** (sorted); the module alerts "re-run calibrate.sh" when a twin is replaced. A same-twins order flip is undetectable — order comparison across the two APIs carries no meaning, so it is deliberately not attempted — and recalibration is the documented ground truth. whisper-cpp ≥ 1.8.5 is required (setup.sh verifies via Homebrew's version records; non-brew builds need an explicit `DICTATE_SKIP_VERSION_CHECK=1` override).

## Visual indicator

- **Menu bar item** (`hs.menubar`), always visible, three states: idle `🎤`, recording `🔴`, transcribing `…`. Clicking it opens the mic-selection menu above. This is the ambient "the tool is loaded and armed" signal.
- **Floating pill** (`hs.canvas`): a small rounded pill at bottom-center of the current screen, visible on all spaces, never steals focus. Shows "🎤 Listening…" while the key is held and "✍️ Transcribing…" until insertion completes. Hidden when idle.

## Stack — use exactly this, don't substitute

| Component | Choice | Install |
|---|---|---|
| Hotkey (event tap), indicator, menu, text insertion, orchestration | Hammerspoon (Lua) | `brew install --cask hammerspoon` |
| Audio recording + device enumeration | ffmpeg with avfoundation | already installed |
| Transcription | whisper.cpp `whisper-server` (persistent, loopback HTTP); `whisper-cli` as fallback | `brew install whisper-cpp` |
| HTTP client for transcription requests | system `curl` | ships with macOS |
| Cleanup | Pure Lua post-processing inside Hammerspoon | none |

No Python, no Node, no LLMs, no other dependencies.

## Models — exact files

Download GGML models from the official whisper.cpp repo on Hugging Face (`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/<file>` — use `curl -L`, these URLs redirect):

- **Default: `ggml-small.en.bin`** (~466 MB) — best speed/accuracy trade-off for English dictation on Apple Silicon.
- **Optional upgrade: `ggml-medium.en.bin`** (~1.5 GB) — noticeably better on technical vocabulary, slower. `setup.sh` downloads small.en always and offers medium.en behind a `--with-medium` flag.
- Store models in `~/.dictate/models/`. Verify a minimum file size after download (fail loudly on a truncated file).
- README: one sentence on when to switch to medium.en (heavy jargon, accents) and how (one config line), plus a note that the server holds the model resident in RAM (~600 MB for small.en, ~2 GB for medium.en) — that is the price of the latency win.

## Hotkey implementation

`hs.hotkey` cannot see modifier-alone presses. Use an `hs.eventtap` on `flagsChanged` events and match by keycode: `fn` = 63, `rightalt` = 61, `rightcmd` = 54, `rightctrl` = 62. One small table maps the config string to a keycode; that table is the full set of supported hotkeys.

If any regular key goes down while the PTT key is held (fn+arrows, fn+delete are common combos): **cancel the recording**, discard the audio, and let the keystroke pass through untouched.

## Recording

Device resolved at key-down from the cached list (see Microphone selection):

```
ffmpeg -y -f avfoundation -audio_device_index <k> -i ":<AUDIO_DEVICE_NAME>" -ar 16000 -ac 1 -acodec pcm_s16le -t <max_duration_s> ~/.dictate/tmp/rec.wav
```

Start as a background `hs.task` on key-down; stop on key-up with SIGINT (`hs.task:interrupt()`, not SIGKILL) so the WAV header is finalized. The `-t` cap is a safety net: if a key-up is ever missed (secure input, display sleep, Hammerspoon reload mid-hold), the mic does not stay open forever.

## Transcription — persistent server

Started by the Hammerspoon module on load, on a per-launch port (`server_port` base + random 1..99 — makes accidentally sharing a port with another whisper-server improbable; whisper-server sets SO_REUSEPORT, so two servers CAN silently share one):

```
whisper-server -m ~/.dictate/models/ggml-small.en.bin --host 127.0.0.1 --port <port> -t 4 -sns
```

Request on key-up (transcript is the response body; `--fail-with-body` keeps HTTP error bodies out of the paste path, `token_timestamps=false` avoids the 60-char token-boundary wrapping regression, whisper.cpp #3968):

```
curl -q -s --noproxy "*" --fail-with-body --max-time 30 http://127.0.0.1:<port>/inference -F file=@$HOME/.dictate/tmp/rec.wav -F response_format=text -F token_timestamps=false -F language=en -F temperature=0.0
```

Lifecycle rules:

- Server is spawned as an `hs.task` **with a streaming drain callback** — hs.task only reads a long-lived task's pipes when one is set; without it the 64 KiB stderr pipe fills after ~170 requests and the server write-blocks permanently. SIGKILLed on Hammerspoon reload/exit (a hung server ignores SIGTERM).
- **Readiness is proven, not assumed**: an identity-guarded HTTP probe (wall-clock deadline; the "listening at" stdout line is fully buffered into pipes and unusable) plus an `lsof` check that OUR pid is the port's only listener. Fail closed: audio is never uploaded unless both hold. Ownership failure re-rolls to a new random port (bounded).
- On curl exit 7 (refused) or 28 (timeout — a hung server keeps LISTENing, so refused can never fire): force-REPLACE the server (kill + fresh task + fresh port) and wait bounded for readiness before the single retry.
- A dictation arriving before readiness waits (bounded ~15 s, covering cold Metal-compile starts) instead of failing.
- Bind 127.0.0.1 only, never 0.0.0.0.

Fallback (`transcribe_mode = "cli"`, used if the server binary is absent):

```
whisper-cli -m ~/.dictate/models/ggml-small.en.bin -f ~/.dictate/tmp/rec.wav --no-timestamps -l en -t 4
```

Note: whisper.cpp flags are boolean switches that take no value (`--flag`, never `--flag false`); text output to file and progress printing are already off by default. The transcript arrives on **stdout**; model/system info goes to stderr — capture stdout only.

## Config

Single Lua config file at `~/.dictate/config.lua`, created by `setup.sh` from a template, `dofile`'d by the Hammerspoon module. These are defaults; mic mode, mic choice, and screen→mic assignments made in the menu persist separately via `hs.settings` and take precedence.

```lua
return {
  hotkey            = "fn",           -- one of: "fn", "rightalt", "rightcmd", "rightctrl"
  model_path        = os.getenv("HOME") .. "/.dictate/models/ggml-small.en.bin",
  transcribe_mode   = "server",       -- "server" (persistent, fast) or "cli" (fallback)
  server_bin        = "/opt/homebrew/bin/whisper-server",
  cli_bin           = "/opt/homebrew/bin/whisper-cli",
  server_port       = 12800,
  ffmpeg_bin        = "/opt/homebrew/bin/ffmpeg",
  mic_mode          = "auto",         -- "auto" (follow focused screen) or "fixed"
  audio_device      = { name = "MacBook Pro Microphone", index = 0 },  -- fixed/fallback mic; index is among same-named devices
  min_duration_s    = 0.5,            -- discard shorter recordings
  max_duration_s    = 120,            -- hard cap; passed to ffmpeg -t
  language          = "en",
  paste_mode        = "pasteboard",   -- "pasteboard" (fast) or "keystrokes" (fallback)
  restore_delay_ms  = 300,            -- delay before pasteboard restore
  log_file          = os.getenv("HOME") .. "/.dictate/log.txt",
}
```

`setup.sh` resolves the actual binary paths (`whisper-server` / `whisper-cli` names or locations may vary by formula version) and writes them into the config.

## Text insertion

Default: save the **full pasteboard contents including non-text types** (`hs.pasteboard.readAllData`), write the transcript, simulate ⌘V with `hs.eventtap`, then restore the saved contents (`hs.pasteboard.writeAllData`) after `restore_delay_ms` — including on error (wrap in pcall). An image or rich text on the clipboard must survive a dictation. Fallback mode `keystrokes` uses `hs.eventtap.keyStrokes` (works in apps that block paste, slower).

## Cleanup rules (pure Lua, conservative)

- Strip Whisper artifacts: `[BLANK_AUDIO]`, `[Music]`, `(silence)`, any leading/trailing `[...]` or `(...)` annotation lines.
- Remove filler words only as standalone tokens (word-boundary matches, case-insensitive): um, uh, uhm, er, ah, hmm. Do **not** touch words merely containing these substrings.
- Collapse repeated whitespace, trim, capitalize first character if needed.
- Hallucination blocklist: if the final cleaned text is empty or exactly one of {"Thank you.", "Thanks for watching.", "you", "Thank you for watching."} — known Whisper hallucinations on silence — insert nothing.

## Edge cases

- Recording shorter than `min_duration_s`: delete and do nothing, silently.
- Key-down while a transcription is already running: ignore it.
- Another key pressed while the PTT key is held: cancel recording, discard audio, pass the keystroke through.
- Auto mode, focused screen has no mic assigned: fall back to the fixed mic, then `:default`; no error.
- Selected/mapped mic is no longer present (unplugged): `hs.alert` once, fall back to `:default`, log it.
- ffmpeg / curl / whisper non-zero exit: show `hs.alert` with a one-line error; append full stderr to the log file.
- whisper-server died: next dictation restarts it and retries once.
- Delete `~/.dictate/tmp/rec.wav` after every run, success or failure, and delete any leftover WAV on module load — this is a privacy tool; never leave audio on disk.

## Deliverables

1. **`setup.sh`** — idempotent. Checks for Homebrew (exit with instructions if missing); installs hammerspoon, ffmpeg, whisper-cpp if absent; creates `~/.dictate/{models,tmp}`; downloads the model(s) with `curl -L` and minimum-size verification; enumerates avfoundation audio devices and writes the chosen fallback device (name + same-name index) into a fresh `~/.dictate/config.lua`; resolves and writes the whisper-server / whisper-cli paths; installs the Lua module into `~/.hammerspoon/dictate.lua` and appends `require("dictate")` to `~/.hammerspoon/init.lua` if not already present; finishes by printing the manual steps the user must do: grant Microphone and Accessibility permissions to Hammerspoon, and set the Globe key to "Do Nothing". Day-to-day mic changes happen in the menu, not by re-running setup.
2. **`dictate.lua`** — the Hammerspoon module, commented, reading all settings from the config file.
3. **`README.md`** — must include, precisely:
   - One-line install: `git clone … && ./setup.sh`
   - **Permissions walkthrough:** System Settings → Privacy & Security → **Microphone** → enable Hammerspoon; System Settings → Privacy & Security → **Accessibility** → enable Hammerspoon; note that recent macOS may additionally prompt for **Input Monitoring** — grant it if asked. Hammerspoon must be restarted after granting.
   - **Globe key setup:** System Settings → Keyboard → "Press 🌐 key to" → Do Nothing, and why.
   - **Mic selection:** the menu, auto-follow-focus mode, and the one-time "Assign screen mics…" pairing (including why macOS makes the pairing manual).
   - How to change the hotkey and model (with the medium.en upgrade path and its RAM cost).
   - Troubleshooting table: nothing is inserted → Accessibility permission; hotkey does nothing → Input Monitoring or Globe key still bound to a system action; no audio/garbage → wrong mic selected, check the menu and the log line showing which device recorded; wrong Studio Display mic picked in auto mode → swap the assignment in "Assign screen mics…"; slow → switch back to small.en; first dictation after reload fails → server warm-up, just retry.
   - A privacy statement: what touches disk (temp WAV, deleted after use; log file contains error text and device names only, never transcripts), that the only runtime network activity is HTTP to 127.0.0.1 (loopback — never leaves the machine), and that whisper-server keeps the model resident in RAM while Hammerspoon runs.
4. **`calibrate.sh`** — optional: when two identically-named display mics exist, records from both simultaneously while the user scratches near the LEFT display (on-screen alert cues them), compares levels, and writes the screen→mic map into Hammerspoon settings. Requires exactly two screens; otherwise the menu's manual assignment is the path.
5. **`test-checklist.md`** — manual QA: dictate into TextEdit, VS Code, a terminal, and a browser textarea; brief tap inserts nothing; dictation with background music; a 60-second monologue; clipboard **text** survives a dictation; clipboard **image** survives a dictation; fn+arrow / fn+delete do not trigger dictation and pass through; **auto mode: focus a window on each Studio Display in turn, dictate, and confirm via the log that the matching mic was used**; switch mics via the dropdown and confirm it sticks after a Hammerspoon reload; connect or disconnect the iPhone/AirPods mid-session and dictate again; unplug an assigned display's mic and confirm the fallback alert; first dictation immediately after a Hammerspoon reload (server warm-up path); a recording that hits the `max_duration_s` cap.

## Build order

Work incrementally and verify each stage before the next: (1) confirm deps and device enumeration on this machine, (2) record-and-play-back a WAV, (3) start whisper-server and transcribe the WAV via curl from the CLI, (4) wire the hotkey, indicator, and insertion with a fixed mic, (5) add the mic menu, auto-follow-focus, cleanup, and edge cases, (6) write setup.sh and docs. Ask me to test the microphone stage and the first end-to-end dictation before polishing.
