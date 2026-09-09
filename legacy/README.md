# air_whisper — local push-to-talk dictation for macOS

**Totally private, totally local, and totally free!**

Hold **fn**, talk, release — your words land at the cursor in whatever app is frontmost. Whisper runs entirely on your Mac (small.en by default): audio never touches the network, there are no accounts, and nothing to pay for. What Wispr Flow charges $144/year for, auditable in one Lua file.

## Install (60 seconds + two clicks)

```
git clone git@github.com:AirspaceTechnologies/air_whisper.git && cd air_whisper/legacy && ./setup.sh
```

Setup asks **nothing**. When Hammerspoon launches, it walks you through the only two things Apple requires a human to click — the Accessibility and Microphone permissions — then configures everything else itself: Globe-key behavior, launch-at-login, mic selection, status readout in the 🎤 menu. Dictate once and it congratulates you; you're done.

Add `--with-medium` to also download the larger `medium.en` model (~1.5 GB). Requires **whisper-cpp ≥ 1.8.5** — setup.sh checks Homebrew's installed version and tells you to `brew upgrade whisper-cpp` if it's older. Self-built (non-Homebrew) binaries can't be version-verified; if you've verified yours, run `DICTATE_SKIP_VERSION_CHECK=1 ./setup.sh`.

**Note for existing Hammerspoon users:** setup appends `require("dictate")` to your `init.lua` without touching the rest. dictate.lua does not take ownership of any Hammerspoon singleton: device hot-plug is detected by a cheap 2-second signature poll (your `hs.audiodevice.watcher` handler, if any, is untouched), and an existing `hs.shutdownCallback` is preserved and chained.

## Permissions (the two clicks)

macOS requires a human to grant these — no script can. The built-in setup wizard fires each prompt at the right moment and continues automatically once you click (including the restart Accessibility needs). For reference, they live at **System Settings → Privacy & Security → Accessibility / Microphone → Hammerspoon**; on recent macOS you may additionally be prompted for **Input Monitoring** — grant it.

## Globe key

The push-to-talk key is **fn (Globe)**, held alone. macOS binds that key to its own action by default; the wizard sets it to "Do Nothing" for you. If the emoji picker ever pops on fn anyway, log out and back in once, or set it manually: System Settings → Keyboard → "Press 🌐 key to" → Do Nothing.

## Usage

- **Hold fn** → pill appears ("⏳ … starting", then "🎤 … listening" once audio is actually flowing — the mic takes ~0.3–0.7 s to open, so speak after the pill says listening).
- **Release** → "✍️ Transcribing…", then the text pastes at your cursor. Your previous clipboard contents (including images) are restored afterwards.
- **Press any other key while holding fn** (fn+arrows, fn+delete…) → recording cancels silently and the keystroke works as normal.
- Taps shorter than half a second are discarded.

## Choosing a microphone

Click the **🎤 menu bar icon**:

- **Auto — follow focused screen**: each dictation uses the mic assigned to the screen holding the focused window. This is the mode for multi-display setups where each display has its own mic.
- **Or pick a fixed device** from the live list (it refreshes as devices come and go; duplicate names get "(1)"/"(2)" suffixes).
- **Assign screen mics** pairs each screen with a mic for auto mode.

**Why pairing is manual:** macOS doesn't expose which of two identical "Studio Display Microphone" devices belongs to which physical display. Run **`./calibrate.sh`** to measure it automatically (you scratch near the left display; the louder mic wins) — or assign by hand in the menu. Assignments are keyed to display hardware UUIDs, so they survive reboots and rearranging.

The pill names the mic on every recording, so a wrong pairing is immediately visible; the decision path is also logged to `~/.dictate/log.txt`.

**Known limitation:** the "(1)/(2)" numbering of identical mics reflects enumeration order, which macOS does not guarantee stable across reboots or re-plugs (and exposes no identity ffmpeg can see). Calibration records the mics' hardware UIDs and the tool alerts you to **re-run `./calibrate.sh`** if a twin is ever *replaced* (different hardware). What it *cannot* detect is the same two mics swapping enumeration positions — no macOS API this tool can use exposes that. If dictation ever seems to pick up from the wrong display, don't debug it: just re-run `./calibrate.sh` — it re-measures physical reality in under a minute.

## Changing things

| What | How |
|---|---|
| Hotkey | `hotkey` in `~/.dictate/config.lua`: `"fn"`, `"rightalt"`, `"rightcmd"`, or `"rightctrl"`. Note many non-Apple keyboards handle fn in firmware and never send it to macOS — use `rightalt` there. |
| Model | Switch to medium.en for heavy jargon or accents: run `./setup.sh --with-medium`, then set `model_path` to `ggml-medium.en.bin` in the config. Costs ~2 GB resident RAM (vs ~600 MB for small.en) and is slower. |
| Mic | Use the 🎤 menu (preferred). `audio_device` in the config is only the last-resort fallback. |
| Paste style | `paste_mode = "keystrokes"` types the text instead of pasting — for apps that block ⌘V. |

After editing the config: Hammerspoon menu (🔨) → Reload Config.

## If it gets stuck — restarting

The tool self-heals in layers: a watchdog stops the recording within ~¼ s if macOS ever eats the key-release event, and a stuck-state guard force-resets the pipeline if any state outlives its legitimate bounds. If the UI ever freezes anyway:

- **First, run `./diagnose.sh`** (before killing anything). It saves a thread sample of the frozen process, Hammerspoon's system log, and the dictation log to a folder on your Desktop — the Console window's scrollback dies with the process, but these survive. Then:

- **🎤 menu → Restart dictation** (reloads the Hammerspoon config), or
- quit/kill Hammerspoon and relaunch it: **`open -a Hammerspoon`** (or Spotlight → "Hammerspoon"). On load the module kills any stray recorder process and deletes leftover audio, so a hard kill never leaves the mic open past the 120 s cap or audio on disk.

Tip: enable **"Launch Hammerspoon at login"** in Hammerspoon's preferences so the tool is always resident.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing is inserted | Accessibility permission missing → grant, restart Hammerspoon |
| Stuck on "Listening…" | Should self-recover in ~¼ s (watchdog); if truly frozen, see "If it gets stuck" above |
| Hotkey does nothing | Input Monitoring permission, or Globe key still bound to a system action, or a non-Apple keyboard swallowing fn |
| No audio / garbage text | Wrong mic — check the name in the pill and `~/.dictate/log.txt`, fix via the 🎤 menu |
| Wrong display's mic in auto mode | Swap the pairing: re-run `./calibrate.sh` or 🎤 menu → Assign screen mics |
| Slow transcription | Switch back to small.en |
| First dictation after a reload fails | whisper-server still warming up — it auto-retries once; just dictate again |
| Emoji picker pops up | Log out/in once (the wizard's Globe-key setting needs it on some systems), or set System Settings → Keyboard → "Press 🌐 key to" → Do Nothing |
| Headphone audio turns distorted during dictation | The recording used your Bluetooth headset's mic, which drops its output to call quality. The automatic fallback already prefers built-in mics; if you assigned the headset yourself, pin a desk or built-in mic in the 🎤 menu instead |

## Privacy

- Audio is written to `~/.dictate/tmp/rec.wav` and **deleted after every dictation**, success or failure; leftovers are cleared on load. The whole `~/.dictate` tree is kept at **0700** (repaired on every module load) — macOS home directories are staff-group-traversable by default, and live audio must not be readable by other local users even briefly.
- The log (`~/.dictate/log.txt`) records device names and errors — **never transcripts, never audio**.
- Transcription happens in a local `whisper-server` bound to `127.0.0.1` (loopback never leaves the machine). The upload is invoked proxy-immune (`curl -q --noproxy "*"`), so proxy environment variables or a `~/.curlrc` cannot reroute audio through a proxy. The only true network access is `setup.sh` downloading models from Hugging Face, once (that download *does* honor your proxy, deliberately — it's public content you may need a proxy to reach).
- The model stays resident in RAM (~600 MB for small.en) while Hammerspoon runs — that's the price of ~0.5 s transcriptions.
- No accounts, no telemetry, no cloud.

## Files

| File | Role |
|---|---|
| `setup.sh` | Idempotent installer (Homebrew packages, model download, config, Hammerspoon module) |
| `dictate.lua` | The entire tool — a single Hammerspoon module |
| `calibrate.sh` | Optional: pairs twin display mics with their screens by measurement |
| `config.template.lua` | Template for `~/.dictate/config.lua` |
| `test-checklist.md` | Manual QA checklist |
