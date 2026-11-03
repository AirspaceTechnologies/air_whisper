# Swift manual QA checklist

Run `make all` for automated checks. Checked items record user-confirmed results on the development Mac; unchecked items still need manual validation.

## Installation

- [ ] Open the shared ZIP on a second Apple Silicon Mac without Homebrew/Hammerspoon.
- [ ] Complete the app-specific Open Anyway step under company policy.
- [ ] Grant Microphone/Accessibility/Input Monitoring as requested; recover after denial/regrant.
- [ ] Download Small English; cancel/retry download, then dictate offline.
- [ ] Select an existing official model; reject a corrupt/truncated file clearly.
- [ ] Verify legacy model reuse without redownloading.
- [x] Replace installed 0.1.0 with 0.1.2 on the development Mac: Accessibility required reauthorization; dictation worked after recovery.
- [ ] Repeat an app update and permission checks on a second company Mac.
- [ ] Confirm the microphone menu and Settings show the same version/build as the installed bundle; missing permissions name the blocked access rather than showing Ready.
- [ ] Toggle launch at login and verify after login from the installed app.

## Dictation and keyboard

- [ ] After replacing an ad hoc build, Setup reports an unusable listener even if macOS permission toggles remain on. Re-add the installed app in Accessibility/Input Monitoring and verify recovery.
- [ ] Press Fn in Settings: the Keyboard access check shows a fresh detection time without recording audio. Reset/Recheck recreates a failed listener; transient disabling recovers without a restart.
- [ ] A Secure Input block is shown separately from missing permissions and cancels an in-progress recording.

- [ ] Disable the old Hammerspoon dictation module before testing.
- [ ] Dictate into TextEdit, VS Code, Terminal and a browser text field.
- [x] Basic dictation insertion in Slack desktop 4.50.143 with Air Whisper 0.1.2, confirmed by the user after restoring Accessibility access.
- [ ] Start Slack before and after Air Whisper, focus its message editor, wait a couple of seconds, and verify dictation inserts there without sending the message.
- [ ] Start dictation immediately after first activating Slack; if the field is unavailable, confirm the transcript can still be copied and a later dictation inserts normally.
- [ ] While transcribing in Slack, move from the message editor to search or a different composer; confirm automatic insertion is refused.
- [ ] Start Chrome before and after Air Whisper; focus a normal input, textarea and contenteditable field, wait a couple of seconds, and verify insertion without submitting the form.
- [ ] Dictate immediately after first activating Chrome; if accessibility is still loading, confirm menu recovery works and a later attempt inserts normally.
- [ ] While transcribing in Chrome, change fields, tabs or windows; confirm text never reaches the new destination. Repeat in the web editor that originally failed.
- [ ] Starting changes to Listening only after audio arrives.
- [ ] Release/cancel during startup leaves no open mic.
- [ ] Short taps insert nothing, a 60-second take works, and the 120-second cap releases the microphone.
- [ ] Fn+arrow/Fn+delete/other keys cancel while retaining their normal behavior.
- [ ] Test Right Option/Command/Control, including holding the matching left modifier when releasing the right.
- [ ] Presses during transcription do not enqueue a recording.
- [ ] Change the focused app/window while transcribing; no text reaches the unexpected destination.
- [ ] Silence/filler-only input inserts nothing; background music does not produce an unwanted canned transcript.

## Clipboard and UI

- [ ] Listening shows live teal amplitude bars that follow speech and settle during silence. Release switches to the processing overlay; cancellation clears the graph. Overlays never steal focus or display microphone IDs.
- [ ] Check overlay text wrapping, light/dark mode, Reduce Motion, fullscreen, and both display sizes.

- [ ] After both a successful paste and a missing paste, Copy Dictation offers the latest result for five minutes. Copying it twice works; a cancelled or silent later recording does not erase it. A new recognized result replaces it and starts a fresh five-minute expiry.
- [ ] Reset, sleep/lock, and quit clear Copy Dictation immediately. An older result's expiry does not clear a newer result.
- [ ] Reproduce a failed Chrome paste while watching the unified log: distinguish missing hotkey, missing audio, empty transcription, rejected focus, and posted-but-unconfirmed events. Confirm logs contain no dictated or clipboard text.
- [ ] Previous text, image, rich text and multiple clipboard items survive.
- [ ] New content copied during paste restoration is preserved.
- [ ] Keystroke mode works in an app blocking paste.
- [ ] The overlay never steals focus and follows the correct display/Space/fullscreen app.
- [ ] UI stays responsive while hashing, loading and transcribing.

## Devices and recovery

- [ ] Both Studio Displays show Matched automatically without manual assignment. Move a focused text field between displays and verify each session uses its matched microphone. Replug/reorder displays and verify matching refreshes.
- [ ] Advanced overrides take priority, returning to Automatic clears the override, and unavailable or ambiguous hardware uses the fallback. One microphone everywhere ignores display matching.
- [ ] Optional Test opens a sound-check graph on the selected display. Stop and the twenty-second limit release the mic; no transcript is produced. Normal dictation stops the test before recording.
- [ ] Stop a microphone test during startup, close/switch away from Microphones, unplug its device, and sleep/lock: testing stops without leaving the microphone open.
- [ ] Verify both Studio Display microphones are matched by hardware identity and focus-following selection works without a listening comparison.
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
