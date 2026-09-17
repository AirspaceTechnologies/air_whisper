# Swift build validation

## Public release 0.1.4 (build 5) — 2026-09-17

Validated on an Apple Silicon Mac running macOS 26.5.1 with Swift 6.3.3. This release uses the merged native app and public-release preparation changes; the open custom-vocabulary and cleanup features are not included.

- `make all` passed from a fresh worktree: 64 Swift tests, 63 passed and one optional model test skipped; all seven dependency-cache regression checks passed. The optional verified Small English/public JFK integration test then passed separately, including expected speech, silence suppression, cancellation and model reuse.
- Extracted the generated ZIP and verified its SHA-256, arm64 executable, version/build, app/framework signatures, portable dependencies, exact project and third-party licenses, and noninteractive self-check. The extracted executable also transcribed the public JFK fixture with an expected-phrase assertion. No live microphone, installed app, or normal clipboard was accessed.
- The ZIP contains no model/audio files, AppleDouble entries or archived extended attributes. The packaged app executable contains no developer home path. Upstream frameworks may retain public upstream build metadata.
- Publication artifact SHA-256: `882e846f2a86e6236be3817f53913dbac714b0660ed9ac425e62a2c9481328c8`. Both the app ZIP and `SHA256SUMS` are release assets; a subsequent rebuild can have a different ZIP hash.

Installation on a second physical Mac, a fresh permission/hotkey/Chrome/Slack session, and the full manual hardware matrix were not repeated for this publication. Prior user feedback indicates the native app works well, but does not establish that every manual case or supported macOS version passed. These remain explicit limits of this release's validation.

## Version visibility and permission recovery — 2026-09-15

- `make all` passed using checked-in version 0.1.4 (build 5): 64 tests executed, 63 passed, one optional real-model test skipped; all seven bootstrap regression checks passed. Package self-check, signatures and portable dependencies verified successfully.
- The menu title, Settings header and tooltip read version/build from bundle metadata. The packaged `--version` command returned `Air Whisper 0.1.4 (5)`; help lists the new read-only permission diagnostic.
- The user reported an inactive Fn key after installing 0.1.3. Metadata confirmed Fn was still configured and the observed app event tap was disabled. Exact access for that older build was not available to the separate diagnostic runner.
- Installed 0.1.4 in `/Applications` with a backup of 0.1.3. Launching the installed app through LaunchServices with `--permission-status` reported Accessibility and Input Monitoring **not authorized**, and Microphone **not determined**. These checks do not request permission, capture input or load models. Missing Accessibility directly stops the push-to-talk listener in the app.
- Permission restoration requires user interaction in System Settings. Successful Fn detection and Chrome insertion after regrant remain pending; do not treat the build/test pass as a completed live hotkey check.

## Chrome accessibility update — 2026-09-15

- `APP_VERSION=0.1.3 APP_BUILD=4 make all` passed on the development Mac: 64 tests executed, 63 passed and the optional real-model integration test skipped because its fixture environment variables were not configured. All seven bootstrap regression checks also passed.
- The 21 accessibility preparation/focus tests cover Chrome/Chromium fallback, Electron precedence, exact browser bundle matching, inherited AppKit state, retry behavior, one successful request per launch, and rejection of a destination first discovered after dictation started. Tests inject AX responses and do not inspect browser page content.
- Release packaging, bundle self-check, ad hoc signatures and portable dependency verification passed for 0.1.3 (build 4). Independent code review found no additional issues.
- Live Chrome insertion and first-activation timing still require user validation. The read-only diagnostic runner lacks Accessibility permission, so it could not inspect Chrome's focused field. See the Chrome cases in `test-checklist.md`.

## Previous release validation — 2026-09-09

Verified on 2026-09-09 using an Apple Silicon Mac, macOS 26.5.1, Xcode's Swift 6.3.3 toolchain. The app's deployment target is macOS 13.3; older supported OS versions and other machines still need manual validation.

## Completed

- `APP_VERSION=0.1.2 APP_BUILD=3 make -j2 all` passed from the PR worktree with the optional integration-test model/fixture environment variables set: all 56 tests passed, zero failures or skips, followed by successful release packaging. Shared SwiftPM/framework build steps remain serialized even when make is invoked with parallel jobs.
- All seven offline bootstrap regression checks passed through `make all`, using real ZIP extraction and SHA-256 checks with a mocked download. They cover repair of modified extracted files and injected symlinks, initial download/offline reuse, forged legacy stamps, corrupt cached/downloaded archives, extraction failure, and missing framework files. The original bootstrap fails the modified-cache regression. The fixed bootstrap also verified the official dependency on first download and on subsequent cached builds.
- The real-model integration test used the verified existing small.en model and upstream JFK fixture. It checks expected phrases, silence suppression, cancellation/recovery, and canceled-unload handling while reusing a loaded context. This test is skipped by default when local model/fixture paths are not supplied; the other 55 tests need no model.
- Thirteen accessibility preparation/focus regression tests passed. They cover one request per application launch, already-enabled and unsupported applications, permission/transient-failure retries, relaunches, exact field identity and rejection of a field first discovered after recording began. These tests inject AX responses and do not inspect live Slack content.
- The user confirmed dictation inserts into Slack desktop 4.50.143 with installed Air Whisper 0.1.2 after restoring Accessibility access. The update initially left an enabled-looking Accessibility entry while the new app reported no access; removing and re-adding the installed app was the recovery guidance. Both old and new app signatures were valid, with different ad hoc code identities.
- Named-pasteboard tests passed outside the restricted command sandbox. They preserve multiple items/binary types and confirm ownership-generation behavior. The user's normal clipboard was not accessed.
- Release app and embedded framework passed `codesign --verify --deep --strict`. The bundle is ad hoc signed, with no TeamIdentifier or developer account.
- Removed the build machine's Xcode toolchain library search path from the shipped executable. Remaining paths resolve OS libraries and the bundled framework.
- Verified `SHA256SUMS`, extracted the release ZIP into a separate temporary folder, and ran `scripts/verify-app.sh` against that copy. It confirmed version 0.1.2 (build 3), signatures, bundle metadata, portable dependencies and `--self-check`. Real file transcription with an expected-phrase assertion also passed: the 11-second fixture produced 108 cleaned characters; speech content was not printed.
- Metal inference passed outside the tool sandbox. The CPU fallback passed inside the restricted environment where Metal buffer allocation is unavailable.
- Bundle metadata, shell syntax and whitespace checks passed. Invalid version/build overrides were rejected before bootstrap/build. Generated app icon was visually inspected.

Artifacts: `dist/Air Whisper.app`, `dist/Air-Whisper.zip`, and `dist/SHA256SUMS`. Models are not bundled. Packaging generates the checksum for each build; rebuilt ZIPs can have different hashes.

## Still requires a person

Automated build validation did not capture live microphone input or type into another application. The user subsequently reported that the native app works well in hands-on use; this is a basic smoke check, not completion of the full hardware matrix. Use `test-checklist.md` for Studio Display assignments, device removal, lock/sleep, login registration, permission persistence across updates, and installation on a second company Mac.

Basic Slack insertion is now user-confirmed. Both application launch orders, immediate first-activation timing, and changing the target field during transcription still require the focused checks in `test-checklist.md`. Direct Slack focus inspection was unavailable because the diagnostic runner lacks Accessibility permission; automated AX regression tests use injected responses.

Disable the old Hammerspoon dictation module before testing the Swift app with the same hotkey. The legacy implementation and documentation remain in `legacy/`. The app/build does not modify Hammerspoon configuration or relocate legacy models automatically.
