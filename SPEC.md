# Air Whisper — native macOS specification

This supersedes the Lua proof of concept at the user's request. The original specification is in `legacy/SPEC.md`.

## Product

A private push-to-talk menu app for macOS 13.3+ on Apple Silicon, shared internally as a prebuilt, locally ad hoc signed app. No Apple developer account is required. Recipients allow the downloaded app and grant microphone/Accessibility/keyboard permissions subject to company policy.

Hold Fn/Globe or a supported right-side modifier, wait for actual audio capture, speak, release, and insert the cleaned transcript at the original focused destination. Another key cancels. Presses during transcription are ignored and short taps are discarded. The overlay never steals focus. Preserve all clipboard items/types and newer clipboard changes. Avoid insertion into an unexpected destination if focus changes.

## Architecture

- Swift Package Manager executable, SwiftUI/AppKit shell, three supporting modules.
- Native AVFoundation discovery/capture and CoreAudio device metadata. Persist device IDs and display UUIDs; initial screen-to-mic pairing is explicit.
- In-memory 16 kHz mono float PCM, no recording files or ambient pre-roll.
- Pinned, embedded whisper.cpp with Metal and a persistent model context on a serial worker. No inference server, curl, ffmpeg, or runtime Homebrew dependency.
- User-triggered model download with cancellation, progress, private directories and atomic installation after SHA-256/exact-size verification. Official small.en default and medium.en option. Reuse legacy models read-only.
- Session IDs prevent stale asynchronous completions from inserting text. Independent capture cap at 120 seconds; handle release/cancel during startup, dropped key-release events, device failures, sleep and exit. Inference cancellation is cooperative; native-library hangs can require app restart.
- Permission setup and native launch-at-login settings. Build/CLI diagnostics must never prompt or capture audio.

## Distribution and validation

`make all` runs tests and produces `dist/Air Whisper.app`, `dist/Air-Whisper.zip`, and `dist/SHA256SUMS`, including framework and licenses. Packaging ad hoc signs, verifies the bundle, and runs its self-check. Maintainers can set `APP_VERSION` and `APP_BUILD` for distributed updates. No account registration, notarization, global security changes, automatic installation, or microphone access occurs in the build.

Automated checks cover cleanup, device routing, session invalidation, resampling, cancellation and model handling. A known speech fixture verifies real packaged inference. The manual checklist covers hardware, permissions, keyboard, clipboard, sleep and updates; never infer those results from compilation.

No cloud transcription, accounts, telemetry, or runtime networking except explicit model downloads. Do not log audio or transcripts, or promise to prevent operating-system swap/dumps. Keep app-owned data private under Application Support.
