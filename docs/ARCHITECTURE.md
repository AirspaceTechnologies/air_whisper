# Native dictation architecture

Air Whisper is a Swift Package Manager executable for macOS 13.3+, initially distributed for Apple Silicon. The `.app` bundle contains the executable and the pinned whisper.cpp framework; recipients need no developer tools or separately installed inference server.

## Module responsibilities

| Module | Responsibility |
|---|---|
| `AirWhisper` | App lifecycle, settings/onboarding, menu/overlay, keyboard, display routing and text insertion |
| `AirWhisperAudio` | Native device discovery, capture lifecycle, streaming resampling and bounded buffers |
| `AirWhisperSpeech` | Model verification/download and serialized inference using the C API |
| `AirWhisperCore` | Settings and audio types, microphone selection, text cleanup and session identity |

Audio and speech depend only on Core. The app composes the modules and owns user-visible session state. SwiftUI/AppKit state is isolated to the main actor. Capture and C inference execute on separate serial queues so neither blocks the UI during normal operation.

## Capture lifecycle

Discovery reads metadata without opening a microphone. Saved selections use native device IDs; display assignments use display UUIDs. Duplicate display-microphone names receive distinct labels while full device IDs remain the persisted identity.

A push-to-talk press creates a session ID and captures the intended text destination. Input begins only after permission and session validity checks. Samples convert incrementally to 16 kHz mono float PCM in a bounded buffer. Listening status requires actual samples. The capture worker closes the microphone on the configured duration limit independently of the UI callback.

Start/stop/cancel requests enter the capture queue in main-actor order. A separate ownership ID survives a pending stop until physical cleanup completes; a new recording cannot overlap that cleanup. Cancellation while waiting for permission must not start capture after a later permission grant. Old callbacks cannot affect new sessions.

The keyboard listener passes all events through, recognizes supported modifier keys by side-specific flags, cancels modifier chords, and checks physical modifier state for missed release events. Sleep, display sleep, inactive session and lock are tracked independently so a wake notification cannot re-arm a still-locked session.

## Inference and insertion

The inference worker owns a persistent whisper.cpp context. It verifies model header, exact length and SHA-256 before loading, then prefers Metal after an allocation preflight and falls back to CPU if GPU access is unavailable. Normal dictation sends no audio to a server and creates no recording files.

Cancellation generations and per-operation deadlines feed native abort callbacks. C model initialization cannot be interrupted mid-call; cancellation is checked before and after it. A canceled or superseded unload must not invalidate a newer operation. App quit has a bounded fallback if native teardown stalls.

The app checks session identity again before insertion and compares the focused accessibility element with the original target. If automatic insertion is unavailable, it offers explicit copying of the result and expires the in-memory text after five minutes. Clipboard insertion snapshots all items/types and restores them only while it still owns the temporary clipboard generation. Newer clipboard content is preserved.

On application activation and after Accessibility permission is available, Air Whisper requests `AXManualAccessibility` from apps that support it. This exposes Electron text fields without requiring VoiceOver. Preparation is remembered per process lifetime so repeated checks do not restart Electron's delayed accessibility activation. The original field must still be known when dictation begins: a later-discovered field is never substituted into a running session.

## Distribution and updates

`make all` runs tests, builds the release executable, embeds the framework/licenses, sets version metadata, removes development-tool search paths, ad hoc signs, verifies the bundle and packages `Air-Whisper.zip` with `SHA256SUMS`. `APP_VERSION` and `APP_BUILD` optionally override the source defaults for a release.

The bundle identifier and Application Support location stay stable across updates, preserving settings/models. Ad hoc signatures do not provide a stable Developer ID identity, so macOS permission reapproval can be necessary. There is no automatic updater. A maintainer publishes a reviewed build and teammates replace the app, following the README.

The original Hammerspoon implementation remains in `legacy/`. Its ordinal microphone labels cannot safely be imported as native device assignments. Compatible official model files can be reused read-only or moved into the native model directory after quitting the old app.
