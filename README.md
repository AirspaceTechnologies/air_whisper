# Air Whisper

Local push-to-talk dictation for macOS. Hold **Fn / Globe**, speak, release, and your words appear in the focused app. The native Swift menu app records audio in memory and transcribes with a bundled, Metal-accelerated whisper.cpp library. No dictation-service account, telemetry, cloud transcription, or paid developer membership.

Requires **macOS 13.3 or later** and **Apple Silicon** for the supported app distribution. Users do not need Swift, Xcode, Homebrew, ffmpeg, or Hammerspoon.

Download **[Air Whisper 0.1.4 (build 5)](https://github.com/AirspaceTechnologies/air_whisper/releases/tag/v0.1.4)** and follow the installation steps below. Air Whisper is open source under the [MIT license](LICENSE).

**First launch:** if macOS says it cannot verify Air Whisper and offers **Move to Trash** or **Done**, choose **Done** and follow [these opening instructions](#macos-blocked-the-app-on-first-open).

## Install

1. Open the [0.1.4 release](https://github.com/AirspaceTechnologies/air_whisper/releases/tag/v0.1.4) and download **Air-Whisper.zip** from its **Assets** section. Choose the app ZIP, not GitHub's source-code archive, and read the release's installation notes.
2. Double-click the ZIP to extract it. Move **Air Whisper.app** to **Applications** (or `~/Applications`) and open that copy.
3. If macOS says it cannot verify the app is free of malware, follow [macOS blocked the app on first open](#macos-blocked-the-app-on-first-open) below, then continue with step 4.
4. Open **Settings…** from the microphone icon in the menu bar. Grant **Microphone**, **Accessibility**, and **Input Monitoring** if requested for the global keyboard listener. Quit and reopen the app if a permission change requires it.
5. Download **Small English**, or choose an existing official `ggml-small.en.bin`. Models already in `~/.dictate/models/` are also recognized. Small English is approximately 488 MB; Medium English is approximately 1.53 GB.
6. Set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**. Select Right Option, Right Command, or Right Control if your keyboard does not send Fn to macOS.

No terminal commands or developer tools are needed for installation. To check a download optionally, save the release's `SHA256SUMS` beside the ZIP and run `shasum -a 256 -c SHA256SUMS` from that folder.

### macOS blocked the app on first open

Air Whisper is signed locally (ad hoc), without an Apple Developer ID or Apple's notarization check. Follow these steps only for an app you trust from the [official release](https://github.com/AirspaceTechnologies/air_whisper/releases/tag/v0.1.4).

1. In the warning, choose **Done** to keep the app.
2. In Finder, move **Air Whisper.app** to **Applications** if needed, then try opening that installed copy. Choose **Done** again if the warning returns.
3. Open **System Settings → Privacy & Security** and scroll down to the **Security** section.
4. Click **Open Anyway** beside the message that Air Whisper was blocked. **This button is in System Settings**; the original warning only offers **Move to Trash** and **Done**.
5. Confirm **Open** and authenticate if prompted. Once Air Whisper opens, continue with **step 4 under [Install](#install)** to grant its permissions and finish setup.

If **Open Anyway** is missing, try opening the installed app again, then return to **Privacy & Security**. A company-managed Mac may require IT to allow the app. See [Apple's instructions](https://support.apple.com/en-us/102445).

## Update an installed app

Updates are installed manually; the app has no automatic updater.

Starting with 0.1.4, the microphone menu and Settings header show the running app's version and build, for example **Air Whisper 0.1.4 (5)**. Use these to confirm which copy you opened after an update. For the older 0.1.2 release, select the installed app in Finder and use **Get Info** to check its version.

1. Download the newer **Air-Whisper.zip** from [Releases](https://github.com/AirspaceTechnologies/air_whisper/releases). Keep the previous ZIP if you want an easy rollback.
2. Choose **microphone menu → Quit Air Whisper**. Closing the Settings window leaves dictation running.
3. Extract the new ZIP and replace the existing **Air Whisper.app** in the same Applications folder. Keep one installed copy and reopen it from there.
4. Approve **Open Anyway** or permissions again if macOS requests them. Confirm a short dictation works in a text field and that your chosen microphone is still selected.

Replacing the app preserves downloaded models and settings because they are stored outside the app bundle. If the new build causes trouble, quit it and replace it with the previous app from your saved ZIP, then reopen and check permissions. Before rolling back across a future version that changes stored settings, check that release's compatibility notes.

### Accessibility still asks for access after an update

An ad hoc signed update can require a new Accessibility grant because macOS identifies the changed build separately. The old **Air Whisper** entry can still look enabled while the new app has no access. [Apple explains how code identity affects privacy permissions](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

1. Choose **microphone menu → Quit Air Whisper**.
2. Open **System Settings → Privacy & Security → Accessibility**. Select only **Air Whisper** and click **−** to remove its old entry.
3. Click **+**, select your installed **Air Whisper.app** in **Applications** or `~/Applications`, and enable its switch. Choose the same copy you normally open.
4. Reopen that installed app and check that Accessibility is granted in its Settings, then try dictating again.

This refreshes Air Whisper's Accessibility permission and preserves your models and settings.

If Fn does nothing after an update, check Air Whisper's own Settings status. Missing Accessibility access also disables push-to-talk. If Accessibility is granted but the shortcut is still unavailable, check **Privacy & Security → Input Monitoring**, allow the installed Air Whisper app, then quit and reopen it. An enabled-looking macOS entry does not guarantee that the updated build has access.

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
git clone https://github.com/AirspaceTechnologies/air_whisper.git
cd air_whisper
./setup.sh
# Equivalent:
make app
```

To reproduce a published version, check out its release tag before building. Features in an unmerged PR require checking out that PR's branch; they are not included in a release until explicitly merged and released.

This downloads a pinned, SHA-256-verified official whisper.cpp XCFramework, builds the executable, embeds its framework and licenses, ad hoc signs and verifies the bundle, runs a noninteractive self-check, and produces:

```text
dist/Air Whisper.app
dist/Air-Whisper.zip
dist/SHA256SUMS
```

The dependency ZIP is retained in `Vendor/`. Every bootstrap verifies that ZIP again and extracts a fresh framework before building, so changes to an old extracted copy cannot enter the next build. A valid cached ZIP works offline. If a cached ZIP fails verification, the build stops; remove the named ZIP and rerun to download a fresh copy. Older checkouts that only cached an extracted framework need one new download.

Build on Apple Silicon for the supported initial release; the executable targets the build machine's architecture. Model files are downloaded separately, not included in the ZIP. Building does not install or launch the app, modify Hammerspoon, or access the microphone.

```sh
make all          # Automated tests and a release app
make test         # Automated tests
make build        # Development executable
make clean        # Remove generated build/distribution files
```

After bootstrapping, open `Package.swift` in Xcode if desired. Use the packaged app to test microphone permissions, login registration, and menu behavior.

## Build and share an update

A maintainer builds once on Apple Silicon and distributes the same ZIP to users. Complete the [release checklist](docs/PUBLIC_RELEASE.md) before publication. Start from a clean checkout after the change has been reviewed and merged:

```sh
git switch main
git pull --ff-only
make all
```

`APP_VERSION` sets the displayed app version and `APP_BUILD` sets its build number. Defaults come from `Resources/Info.plist` (currently `0.1.4` and `5`); increase them for each distributed update and match the release tag to the version. The overrides change the packaged app, not the checked-in bundle metadata.

Test the resulting app using the [manual checklist](test-checklist.md), including replacement of an existing installation. Keep the reviewed commit SHA with your release notes. Attach **both** `dist/Air-Whisper.zip` and `dist/SHA256SUMS` to a draft GitHub Release for review. An approved shared folder is also suitable for internal review builds.

The following is an example for a maintainer with the GitHub CLI installed and authenticated. Run it only after review and merge, from the checkout used for the build. Write release notes first, including changes, required macOS/architecture, and any update caveats:

```sh
# Example only: match version/build to the tested app and use its full commit SHA.
gh release create v0.1.4 dist/Air-Whisper.zip dist/SHA256SUMS \
  --draft \
  --target "<reviewed-commit-SHA>" \
  --title "Air Whisper 0.1.4" \
  --notes-file /path/to/release-notes.md
```

This creates a draft for review. Check its version, commit, notes, and attached files, then publish it in GitHub's Releases page when approved. The build scripts do not install the app or publish releases. CI runs automated build and test checks; a passing check does not publish a release or complete the manual hardware checks.

## Privacy and storage

- Capture starts only after a key press, with no always-listening buffer.
- Audio stays in process memory. The app does not create recording files or upload audio. This does not prevent operating-system swap or diagnostic dumps.
- Embedded inference requires no HTTP server, listening port, or network connection.
- Explicit model downloads contact Hugging Face and its download hosting. Exact file size and SHA-256 are verified before atomic installation; dictation then works offline.
- Clipboard insertion temporarily places the transcript on the system clipboard. Clipboard managers, Universal Clipboard, and destination apps may retain or sync it; restoring the previous clipboard cannot recall copies they have taken. **Preferences → Insert using → Simulated typing** avoids the clipboard for automatic insertion. Explicit **Copy Dictation** writes the transcript to the clipboard and leaves it there for you to paste.
- When automatic insertion fails, **Copy Dictation** holds the result in memory for up to five minutes. Starting a new recording, resetting dictation, sleeping/locking, or quitting clears it. The app does not maintain a transcript history.
- New models live in `~/Library/Application Support/Air Whisper/models` in private app directories. Legacy models are read without being moved or deleted.
- Settings use the app's macOS preferences. Diagnostics omit audio and transcript content. The explicit `--transcribe-file` diagnostic reports the supplied file's duration and recognized character count.
- The model stays loaded for responsive dictation. Medium English needs more RAM and processing time than Small English.

## Validation and troubleshooting

```sh
"dist/Air Whisper.app/Contents/MacOS/AirWhisper" --self-check
```

This diagnostic does not access the microphone. The [manual checklist](test-checklist.md) covers actual hardware, keyboard, clipboard, sleep, permission, and update behavior. Automated checks do not replace these tests.

For support, the packaged executable also accepts `--version` and `--permission-status`. The latter reports version/build and the diagnostic process's Accessibility, Input Monitoring and Microphone grants without requesting permission, recording audio, or loading a model. Terminal-launched diagnostics can have a different macOS permission context; the running app's Setup status remains the user-facing check.

See [validation results](docs/VALIDATION.md) for the tested build, real inference checks, and remaining hardware checks.

If the hotkey is inactive, check permissions and try Right Option. For wrong-microphone problems, inspect the display assignment; same-named mics have distinct IDs. For model errors, use a verified official model. Embedded inference supports cooperative cancellation; an underlying native-library/GPU hang can require quitting and reopening the app.

If dictation appears under **Copy Dictation** but is not inserted into Slack or a Chrome web field, recording and transcription have succeeded. Air Whisper may not have been able to identify the focused text field when recording began. It requests accessibility support automatically from Slack and Google Chrome/Chromium. After opening or switching to the app, click the intended field and give it a couple of seconds before the first dictation. Copy any waiting transcript from the menu, then try again. Keep the same field focused until transcription finishes. A web editor that replaces its focused element may still require manual copying; Air Whisper keeps the original destination check even if a field becomes available later. Changing microphones or insertion mode does not bypass that check.

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

## Contributing, security, and licensing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and testing, and [SECURITY.md](SECURITY.md) for reporting a vulnerability. Please keep recordings, transcripts, credentials, and private workspace data out of issues and pull requests.

Air Whisper's original code and documentation use the [MIT license](LICENSE), with copyright attributed to Airspace Technologies. The project license is included in packaged apps at `Contents/Resources/LICENSE`. Dependencies and downloaded model weights retain their own licenses and copyright notices; see [ThirdParty/NOTICES.md](ThirdParty/NOTICES.md). MIT licensing of the application does not change those upstream terms.
