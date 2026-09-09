# Air Whisper

Private push-to-talk dictation for macOS. Hold **Fn / Globe**, speak, release, and your words appear in the focused app. The native Swift menu app records audio in memory and transcribes with a bundled, Metal-accelerated whisper.cpp library. No dictation-service account, telemetry, cloud transcription, or paid developer membership.

Requires **macOS 13.3 or later**. The initial release targets Apple Silicon. Teammates do not need Swift, Xcode, Homebrew, ffmpeg, or Hammerspoon.

## Install for teammates

1. Open this private repository's [Releases](https://github.com/AirspaceTechnologies/air_whisper/releases) and download **Air-Whisper.zip** from the release's **Assets** section. Choose the app ZIP, not GitHub's source-code archive. Repository access is required; a maintainer can also provide the same ZIP through an approved company shared folder. Maintainers publish reviewed builds after merge; until the first release is available, use the maintainer-provided ZIP.
2. Double-click the ZIP to extract it. Move **Air Whisper.app** to **Applications** (or `~/Applications`) and open that copy.
3. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway**, then confirm Open. Builds use local ad hoc signing, without Apple Developer ID or notarization. Company-managed Macs may require IT to allow the app. Do not disable Gatekeeper globally. [Apple's instructions](https://support.apple.com/en-us/102445).
4. Open **Settings…** from the microphone icon in the menu bar. Grant **Microphone**, **Accessibility**, and **Input Monitoring** if requested for the global keyboard listener. Quit and reopen the app if a permission change requires it.
5. Download **Small English**, or choose an existing official `ggml-small.en.bin`. Models already in `~/.dictate/models/` are also recognized. Small English is approximately 488 MB; Medium English is approximately 1.53 GB.
6. Set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**. Select Right Option, Right Command, or Right Control if your keyboard does not send Fn to macOS.

No terminal commands or developer tools are needed for installation. To check a download optionally, save the release's `SHA256SUMS` beside the ZIP and run `shasum -a 256 -c SHA256SUMS` from that folder.

## Update an installed app

Updates are installed manually; the app has no automatic updater.

1. Download the newer **Air-Whisper.zip** from Releases or your team's approved shared folder. Keep the previous ZIP if you want an easy rollback.
2. Choose **microphone menu → Quit Air Whisper**. Closing the Settings window leaves dictation running.
3. Extract the new ZIP and replace the existing **Air Whisper.app** in the same Applications folder. Keep one installed copy and reopen it from there.
4. Approve **Open Anyway** or permissions again if macOS requests them. Confirm a short dictation works in a text field and that your chosen microphone is still selected.

Replacing the app preserves downloaded models and settings because they are stored outside the app bundle. If the new build causes trouble, quit it and replace it with the previous app from your saved ZIP, then reopen and check permissions. Before rolling back across a future version that changes stored settings, check that release's compatibility notes.

## Use

- Hold the configured key. Wait for **Listening** before speaking; the floating indicator changes only after actual audio arrives.
- Release to transcribe. Prior clipboard contents, including images and rich text, are restored after pasting if nothing else has copied new content meanwhile.
- Another key while held cancels; ordinary keyboard shortcuts pass through.
- Taps under half a second are discarded. Capture stops at 120 seconds. Presses during transcription are ignored.
- If focus changes during transcription, the app avoids pasting into the unexpected destination and offers the result for explicit copying.
- Pick a fixed mic or use **Auto** with per-display assignments. Choices persist by native device ID, so duplicate names and enumeration order do not swap the assignments. Initial display-to-microphone assignment is manual.
- Automatic fallback prefers built-in audio over a Bluetooth headset mic. Explicit selections are honored.
- Launch at login is a user-controlled setting.
- Open settings, reset dictation, or quit from the microphone icon in the menu bar. Closing Settings does not quit the app.

## Build without a developer account

The build machine needs a current Xcode installation and its selected command-line tools. No signing team or developer account is configured.

```sh
./setup.sh
# Equivalent:
make app
```

This downloads a pinned, SHA-256-verified official whisper.cpp XCFramework, builds the executable, embeds its framework and licenses, ad hoc signs and verifies the bundle, runs a noninteractive self-check, and produces:

```text
dist/Air Whisper.app
dist/Air-Whisper.zip
dist/SHA256SUMS
```

Build on Apple Silicon for the supported initial release; the executable targets the build machine's architecture. Model files are downloaded separately, not included in the ZIP. Building does not install or launch the app, modify Hammerspoon, or access the microphone.

```sh
make all          # Automated tests and a release app
make test         # Automated tests
make build        # Development executable
make clean        # Remove generated build/distribution files
```

After bootstrapping, open `Package.swift` in Xcode if desired. Use the packaged app to test microphone permissions, login registration, and menu behavior.

## Build and share an update

A maintainer builds once on Apple Silicon and shares the same ZIP with teammates; recipients do not build from source. Start from a clean checkout after the change has been reviewed and merged:

```sh
git switch main
git pull --ff-only
APP_VERSION=0.1.1 APP_BUILD=2 make all
```

`APP_VERSION` sets the displayed app version and `APP_BUILD` sets its build number. Defaults are `0.1.0` and `1`; increase them for each distributed update and match the release tag to the version. The overrides change the packaged app, not the checked-in bundle metadata.

Test the resulting app using the [manual checklist](test-checklist.md), including replacement of an existing installation. Keep the reviewed commit SHA with your release notes. Upload **both** `dist/Air-Whisper.zip` and `dist/SHA256SUMS` to a private GitHub Release, or place both in an approved shared folder. Share the release or folder link with teammates, who follow the update steps above.

The following is an example for a maintainer with the GitHub CLI installed and authenticated. Run it only after review and merge, from the checkout used for the build. Write release notes first, including changes, required macOS/architecture, and any update caveats:

```sh
# Replace the placeholder with the full reviewed commit SHA used for the build.
gh release create v0.1.1 dist/Air-Whisper.zip dist/SHA256SUMS \
  --draft \
  --target "<reviewed-commit-SHA>" \
  --title "Air Whisper 0.1.1" \
  --notes-file /path/to/release-notes.md
```

This creates a draft for review. Check its version, commit, notes, and attached files, then publish it in GitHub's Releases page when approved. The build scripts do not publish releases, and builds/releases are not currently automated by CI.

## Privacy and storage

- Capture starts only after a key press, with no always-listening buffer.
- Audio stays in process memory. The app does not create recording files or upload audio. This does not prevent operating-system swap or diagnostic dumps.
- Embedded inference requires no HTTP server, listening port, or network connection.
- Explicit model downloads contact Hugging Face and its download hosting. Exact file size and SHA-256 are verified before atomic installation; dictation then works offline.
- New models live in `~/Library/Application Support/Air Whisper/models` in private app directories. Legacy models are read without being moved or deleted.
- Settings use the app's macOS preferences. Diagnostics omit audio and transcript content. The explicit `--transcribe-file` diagnostic reports the supplied file's duration and recognized character count.
- The model stays loaded for responsive dictation. Medium English needs more RAM and processing time than Small English.

## Validation and troubleshooting

```sh
"dist/Air Whisper.app/Contents/MacOS/AirWhisper" --self-check
```

This diagnostic does not access the microphone. The [manual checklist](test-checklist.md) covers actual hardware, keyboard, clipboard, sleep, permission, and update behavior. Automated checks do not replace these tests.

See [validation results](docs/VALIDATION.md) for the tested build, real inference checks, and remaining hardware checks.

If the hotkey is inactive, check permissions and try Right Option. For wrong-microphone problems, inspect the display assignment; same-named mics have distinct IDs. For model errors, use a verified official model. Embedded inference supports cooperative cancellation; an underlying native-library/GPU hang can require quitting and reopening the app.

## Migrating from Lua

The original prototype is preserved in [legacy/](legacy/README.md); its installer is `./legacy/setup.sh`.

Before enabling the Swift app, disable `require("dictate")` in Hammerspoon's `init.lua` and reload Hammerspoon, or quit Hammerspoon if it serves no other purpose. Otherwise both tools can react to the same key. Building the Swift app never edits that configuration.

Models can be reused. Select display/microphone assignments again: old enumeration-based labels cannot safely be converted to native IDs.

## Uninstall

Turn off **Launch Air Whisper at login** in Preferences, choose **microphone menu → Quit Air Whisper**, and move **Air Whisper.app** from Applications to the Trash. This leaves models and settings available for reinstalling. To reclaim model space, remove `~/Library/Application Support/Air Whisper/models` only if you no longer need those files. The separate `~/.dictate` directory belongs to the legacy setup and may contain models you still use; uninstalling the Swift app does not remove it or change Hammerspoon's configuration.

## Project layout

| Path | Purpose |
|---|---|
| `Sources/AirWhisper` | Menu/settings, permissions, hotkeys, clipboard, display routing, orchestration |
| `Sources/AirWhisperAudio` | Native microphone discovery, capture and resampling |
| `Sources/AirWhisperSpeech` | Embedded Whisper, model download and verification |
| `Sources/AirWhisperCore` | Shared settings, routing, cleanup, session identity |
| `scripts`, `Resources` | Build, packaging, bundle metadata and icon |
| `Tests` | Automated regression coverage |
| `ThirdParty` | Pinned dependency details and licenses |
| `legacy` | Original Hammerspoon implementation |
