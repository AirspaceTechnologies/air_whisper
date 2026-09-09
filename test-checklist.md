# Swift manual QA checklist

Run `make all` for automated checks. Items below remain unverified until tested by a person on real hardware.

## Installation

- [ ] Open the shared ZIP on a second Apple Silicon Mac without Homebrew/Hammerspoon.
- [ ] Complete the app-specific Open Anyway step under company policy.
- [ ] Grant Microphone/Accessibility/Input Monitoring as requested; recover after denial/regrant.
- [ ] Download Small English; cancel/retry download, then dictate offline.
- [ ] Select an existing official model; reject a corrupt/truncated file clearly.
- [ ] Verify legacy model reuse without redownloading.
- [ ] Replace an installed ad hoc build and check permission persistence.
- [ ] Toggle launch at login and verify after login from the installed app.

## Dictation and keyboard

- [ ] Disable the old Hammerspoon dictation module before testing.
- [ ] Dictate into TextEdit, VS Code, Terminal and a browser text field.
- [ ] Starting changes to Listening only after audio arrives.
- [ ] Release/cancel during startup leaves no open mic.
- [ ] Short taps insert nothing, a 60-second take works, and the 120-second cap releases the microphone.
- [ ] Fn+arrow/Fn+delete/other keys cancel while retaining their normal behavior.
- [ ] Test Right Option/Command/Control, including holding the matching left modifier when releasing the right.
- [ ] Presses during transcription do not enqueue a recording.
- [ ] Change the focused app/window while transcribing; no text reaches the unexpected destination.
- [ ] Silence/filler-only input inserts nothing; background music does not produce an unwanted canned transcript.

## Clipboard and UI

- [ ] Previous text, image, rich text and multiple clipboard items survive.
- [ ] New content copied during paste restoration is preserved.
- [ ] Keystroke mode works in an app blocking paste.
- [ ] The overlay never steals focus and follows the correct display/Space/fullscreen app.
- [ ] UI stays responsive while hashing, loading and transcribing.

## Devices and recovery

- [ ] Pair each Studio Display mic by speaking near it and verify focus-following selection.
- [ ] Replug/reorder same-named devices; native ID assignments remain correct.
- [ ] Unplug a chosen mic before/during capture; fallback/error leaves no stuck recording.
- [ ] Implicit fallback avoids Bluetooth if a built-in mic exists; explicit Bluetooth selection works.
- [ ] Reset during startup/transcription; stale work never pastes later.
- [ ] Sleep/lock during capture stops it; unlock supports a new take.
- [ ] Quit during capture releases the microphone.

## Privacy

- [ ] No application-created audio files during or after dictation.
- [ ] Diagnostics contain no audio or transcripts.
- [ ] No network traffic during offline dictation or listening inference port.
- [ ] New Application Support directories are owner-only.
