# air_whisper — local push-to-talk dictation for macOS

**Totally private, totally local, and totally free!**

Hold a key, talk, release — the transcript lands at your cursor in whatever app is frontmost. Everything runs on-device (whisper.cpp on Apple Silicon, with the **small.en** model by default); after setup the tool makes **zero network requests** beyond HTTP to `127.0.0.1`.

## Install

```
git clone <repo-url> && cd air_whisper && ./setup.sh
```

Add `--with-medium` to also download the larger `medium.en` model (~1.5 GB).

## Permissions (required, manual)

macOS will not let a script grant these. After `setup.sh`:

1. **System Settings → Privacy & Security → Microphone** → enable **Hammerspoon**
2. **System Settings → Privacy & Security → Accessibility** → enable **Hammerspoon**
   - On recent macOS you may additionally be prompted for **Input Monitoring** — grant it.
3. **Restart Hammerspoon** after granting (permissions only take effect on restart).

## Globe key setup

The default push-to-talk key is **fn (Globe)**, held alone. macOS binds that key to its own action by default, so set:

**System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**

— otherwise every dictation also opens the emoji picker or Apple's own Dictation.

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
| Emoji picker pops up | System Settings → Keyboard → "Press 🌐 key to" → Do Nothing |

## Privacy

- Audio is written to `~/.dictate/tmp/rec.wav` and **deleted after every dictation**, success or failure; leftovers are cleared on load.
- The log (`~/.dictate/log.txt`) records device names and errors — **never transcripts, never audio**.
- Transcription happens in a local `whisper-server` bound to `127.0.0.1` (loopback never leaves the machine). The only true network access is `setup.sh` downloading models from Hugging Face, once.
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
