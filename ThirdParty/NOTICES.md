# Third-party components

Air Whisper embeds the official whisper.cpp XCFramework, including ggml, and optionally downloads converted OpenAI Whisper model weights. It also embeds the official llama.cpp XCFramework and optionally downloads a small local instruct model used only to clean up finished transcripts. Include this directory in distributed app bundles.

## whisper.cpp and ggml

- Upstream: https://github.com/ggml-org/whisper.cpp
- Build: **b4938**, source commit `371b5a7561823ab2bb32142d2751e35e7534727b`.
- Official artifact: https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-b4938-xcframework.zip
- Archive SHA256: `dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd`.
- License: MIT, reproduced in `whisper.cpp-LICENSE.txt`.

The corresponding semantic tag is v1.9.3, currently marked as a prerelease upstream, while the b4938 artifact release is not marked prerelease. This pinned build includes fixes for very short audio and malformed model tensor headers that were absent from v1.9.2. Updating it requires reviewing its release notes, pinning its checksum, and repeating inference and packaging checks.

The macOS framework requires macOS 13.3 or later, contains arm64 and x86_64 slices, uses Metal and Accelerate, and links only to Apple system libraries. Air Whisper's initial app build targets Apple Silicon. It probes Metal buffer allocation before model loading and falls back to CPU inference when the host denies GPU access. No Homebrew library paths or external speech executables are required. The framework must be copied intact into `Contents/Frameworks` and signed with the same ad hoc signing process as the application. The official archive includes the Metal implementation in the framework; no runtime compiler tools are needed.

Run `./scripts/bootstrap-whisper.sh` before building a fresh checkout. The script retains `Vendor/whisper-b4938-xcframework.zip` and verifies a temporary copy against the pinned archive SHA-256 on every invocation. It always regenerates the extracted framework from those verified bytes, replacing any changes to an older extracted copy. The old `whisper.sha256` stamp is not trusted. A valid cached archive works offline; a corrupt cached archive stops the build before replacing the existing framework and must be removed before retrying the download.

## OpenAI Whisper models

- Original model project: https://github.com/openai/whisper
- License: MIT, reproduced in `Whisper-LICENSE.txt`.
- Converted model source: https://huggingface.co/ggerganov/whisper.cpp
- Pinned model revision: `5359861c739e955e79d9a303bcbc70fb988958b1`.

| Model file | Exact bytes | SHA256 |
| --- | ---: | --- |
| ggml-small.en.bin | 487614201 | c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d |
| ggml-medium.en.bin | 1533774781 | cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356 |

Hashes are the official model repository's LFS SHA256 identifiers. Air Whisper checks model header, exact length, and SHA256 before installing a download or initializing inference. Existing files in `~/.dictate/models` may be used read-only, after the same initialization check. Downloaded models live in `~/Library/Application Support/Air Whisper/models`, with private directory and file permissions. Inference keeps captured PCM audio in memory and does not log transcripts.

## Inference verification

The optional `SpeechTests.testKnownSpeechFixtureAndCancelRecovery` integration test uses the upstream public `samples/jfk.wav` fixture from the pinned whisper.cpp source commit. Fixture SHA256: `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`. It checks known words without printing the transcript, silence suppression, cancellation, and successful reuse of the model after cancellation. It never opens a microphone.

To run it with an existing verified model and downloaded fixture, set `AIR_WHISPER_TEST_MODEL` and `AIR_WHISPER_TEST_WAV` to their absolute paths, then run `./scripts/swift.sh test --filter SpeechTests.testKnownSpeechFixtureAndCancelRecovery`. Without those variables, this test is skipped; ordinary unit tests need no models or network. Run outside a restricted command sandbox to exercise Metal rather than the CPU fallback.

## llama.cpp and ggml

- Upstream: https://github.com/ggml-org/llama.cpp
- Release: **b10896**.
- Official artifact: https://github.com/ggml-org/llama.cpp/releases/download/b10896/llama-b10896-xcframework.zip
- Archive SHA256: `66b906c00395d7b34e693595b47040ff39ac38363ae69c2ba249a8775ee6a31b`.
- License: MIT, reproduced in `llama.cpp-LICENSE.txt`.

Used only to clean up a finished transcript (punctuation, capitalization, hesitation-sound removal); it is never used for speech-to-text, and whisper.cpp remains the only transcription path. The macOS framework requires macOS 13.3 or later, contains arm64 and x86_64 slices, uses Metal and Accelerate, and links only to Apple system libraries. It probes Metal buffer allocation before model loading and falls back to CPU inference when the host denies GPU access. The framework must be copied intact into `Contents/Frameworks` and signed with the same ad hoc signing process as the application.

Run `./scripts/bootstrap-llama.sh` before building a fresh checkout. The script retains `Vendor/llama-b10896-xcframework.zip`, verifies a temporary copy against the pinned archive SHA-256 on every invocation, and restores the framework from that verified copy. Old checksum stamps are ignored. A corrupt archive stops the build before the framework is replaced. Run `make test-bootstrap` for offline regression checks covering both dependencies.

## Qwen2.5 1.5B Instruct (cleanup model)

- Original model project: https://github.com/QwenLM/Qwen2.5
- License: Apache 2.0, reproduced in `Qwen-LICENSE.txt`.
- Converted model source: https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF
- Pinned model revision: `91cad51170dc346986eccefdc2dd33a9da36ead9`.

| Model file | Exact bytes | SHA256 |
| --- | ---: | --- |
| qwen2.5-1.5b-instruct-q4_k_m.gguf | 1117320736 | 6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e |

Downloading this model is optional and off by default; dictation and transcription never require it. Air Whisper checks the GGUF magic header, exact length, and SHA256 before installing a download or initializing inference. Downloaded models live alongside speech models in `~/Library/Application Support/Air Whisper/models`, with private directory and file permissions. Cleanup runs entirely on-device; the transcript text passed to it never leaves the Mac, and unavailable, failed, incomplete, or rejected cleanup falls back to the original transcript. A conservative output check preserves substantive words in their original order; it permits punctuation/case changes and removal of hesitation sounds. It is not a guarantee of semantic equivalence: punctuation can affect meaning, so review dictated text before sending it.

The optional `CleanupSafetyTests.testRealCleanupModelAcrossIndependentRequestsAndReload` test uses synthetic typed sentences and the pinned Qwen GGUF, without recording audio or printing generated text. Set `AIR_WHISPER_TEST_CLEANUP_MODEL` to the model's absolute path, then run `./scripts/swift.sh test --filter CleanupSafetyTests.testRealCleanupModelAcrossIndependentRequestsAndReload`. This exercises separate requests on one context, a prompt longer than one batch, cancellation/recovery, and unload/reload. Without the variable the test is skipped. Ordinary tests cover settings migration, input/output validation, mocked cancellation and load/unload behavior without a model.
