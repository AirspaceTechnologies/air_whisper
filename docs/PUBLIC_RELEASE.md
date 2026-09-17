# Release checklist

Use this checklist when preparing an Air Whisper release. Releases contain the selected, reviewed commits on `main`; open pull requests are separate review decisions and are not included automatically. The build scripts and CI validate an app but do not publish it.

Air Whisper uses the standard [MIT license](../LICENSE), with **Copyright (c) 2026 Airspace Technologies**. Preserve that license and upstream notices. Contributors must have permission to license material they submit; review the source and exact license of any new dependency, model, or asset.

## Select and validate a release

- [ ] Select the reviewed commit and choose an unused version/build. Confirm the app metadata, release tag, and release notes agree. Never silently replace an existing release's ZIP with different code.
- [ ] Review the selected changes and hosted release content for secrets, customer data, internal integrations, and unnecessary personal metadata. Check commits, PR descriptions/comments, release notes, assets, and CI logs/artifacts. A passing scan is evidence for its scope, not proof that every possible secret is absent.
- [ ] Keep ignored local model stores, recordings, diagnostic folders, and working files out of the repository and release. Share the generated app ZIP and checksum file, not an archive of a development directory.
- [ ] Verify the root project license is bundled at `Contents/Resources/LICENSE`, with upstream notices under `Contents/Resources/ThirdParty`. Check [the dependency inventory](../ThirdParty/NOTICES.md) against the exact build. If a model or optional feature is added, review its exact variant's license; the project MIT license does not replace it.
- [ ] Run `make all` from a clean checkout of the reviewed commit on Apple Silicon. Record the commit, macOS/toolchain, test results, skipped tests, version/build, and artifact SHA-256. Run the optional real-model test with its documented public fixture when preparing a release.
- [ ] Extract the ZIP into a separate temporary folder, verify `SHA256SUMS`, and run `scripts/verify-app.sh` against the extracted app. Inspect the artifact for local build paths and extended attributes as well as source-level secrets. Upstream binary frameworks can retain their own public build metadata; removing application build paths is not a guarantee that every upstream path is absent.
- [ ] Run the relevant [manual checks](../test-checklist.md), including installation, replacement of an existing app, version display, permission reapproval, hotkey behavior, Chrome/Slack insertion, microphone release, clipboard handling, and sleep/lock. Record the Macs and OS versions used, any unperformed checks, and known limitations. Passing unit tests does not establish installation on another physical Mac or complete the hardware checklist.
- [ ] State the supported distribution accurately: Apple Silicon, macOS 13.3 or later, ad hoc signing, no notarization, and manual updates. Managed Macs may need IT approval. Do not claim validation on an OS or hardware configuration that has not been tested.

## Publish and verify

1. Build the exact selected commit. Prepare release notes stating changes, full commit SHA, version/build, supported macOS/architecture, installation steps, validation results, known limitations, and permission reapproval after an ad hoc signed update.
2. Use [README.md](../README.md#build-and-share-an-update) to create a **draft** release containing both `Air-Whisper.zip` and `SHA256SUMS`. Review the draft, its ZIP, licenses, and checksum before publishing.
3. Update the README's release link and version instructions to match the artifact being published. Check repository description, license detection, and installation links.
4. Confirm GitHub private vulnerability reporting is enabled, the [report form](https://github.com/AirspaceTechnologies/air_whisper/security/advisories/new) is available, and the responsible maintainer receives notifications. [GitHub's configuration instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)
5. Publish the reviewed release and verify its Assets links without organization membership. Download the public ZIP and checksum and verify that they match the reviewed artifact.

The [0.1.4 release](https://github.com/AirspaceTechnologies/air_whisper/releases/tag/v0.1.4) is build **5**, adding Chrome accessibility support, visible version information, permission diagnostics, and the project license to the published app. Custom vocabulary and optional AI cleanup remain separate, unmerged features.
