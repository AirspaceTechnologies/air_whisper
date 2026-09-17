# Contributing to Air Whisper

Bug reports and focused pull requests are welcome. Include the app version/build and steps to reproduce a problem using non-sensitive examples. For release maintenance, see [the release checklist](docs/PUBLIC_RELEASE.md).

## Develop and validate

Use an Apple Silicon Mac with Xcode and its selected command-line tools. No paid developer account or signing team is needed. Fork and clone the repository, create a branch, and run:

```sh
make all
```

This verifies the pinned framework download, runs offline bootstrap regressions and Swift tests, and builds and verifies the app ZIP. The first build needs internet access for the dependency archive. Generated files in `.build/`, `Vendor/`, and `dist/` are ignored; do not add them to commits. CI runs the automated checks on pull requests.

For subsequent development, `make test` runs the test suite and `make app` packages the app. The optional real-model test is skipped unless `AIR_WHISPER_TEST_MODEL` and `AIR_WHISPER_TEST_WAV` name the verified model and public speech fixture described in [ThirdParty/NOTICES.md](ThirdParty/NOTICES.md). Report skipped checks explicitly. Do not use a private recording as a committed test fixture.

Use the packaged app for manual testing of permissions, recording, hotkeys, and text insertion. Building does not replace an installed app. Ad hoc signed builds can require renewed macOS permissions when installed; see the [update instructions](README.md#accessibility-still-asks-for-access-after-an-update). The [manual checklist](test-checklist.md) covers checks that automated tests cannot perform. Do not report unperformed hardware checks as passed.

## Propose a change

- Describe the problem and observable before/after behavior. Keep changes focused so they can be reviewed independently.
- Include build/test results and any remaining manual checks. Changes to capture, focus, clipboard, and permission behavior need relevant regression coverage or a reproducible manual check.
- Preserve explicit push-to-talk capture, local inference, cancellation/cleanup, and the original text destination check. Avoid recording transcripts or audio in diagnostics.
- Keep dependency and model versions, verified hashes, and license notices together when updating them. Update install or troubleshooting instructions when behavior changes.
- Do not add credentials, recordings, transcripts, model files, private paths, customer data, or company-only integrations. Review screenshots, logs, and commit metadata before sharing them.

You must have permission to contribute the material you submit under the project license. Preserve notices for any third-party code and explain its source and license in the pull request. Report suspected vulnerabilities using [SECURITY.md](SECURITY.md), without putting sensitive details in a public issue.
