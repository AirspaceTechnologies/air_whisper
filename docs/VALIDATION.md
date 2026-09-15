# Swift build validation

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
