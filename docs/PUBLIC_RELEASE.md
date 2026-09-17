# Public release preparation

Status: **company approval pending**. This change prepares source, licensing, documentation, and build checks for review. It does not approve a repository visibility change, merge open pull requests, or publish an app release.

The proposed license is the standard [MIT license](../LICENSE), with **Copyright (c) 2026 Airspace Technologies**. The authorized company owner must confirm that attribution, the legal rights holder, and the decision to license the work under MIT before this preparation is merged for publication. The license text contains no extra restrictions or invented exceptions. See the [Open Source Initiative's MIT text](https://opensource.org/license/mit) and [company review guidance](https://opensource.guide/legal/#what-does-my-companys-legal-team-need-to-know).

## Decisions for company review

- [ ] Approve publication of this code and associated documentation, with authority to license employee-created contributions.
- [ ] Confirm the copyright holder and MIT license, including any required review of employment/IP obligations.
- [ ] Confirm the project name, organization/repository location, and company association. The app currently uses `org.airspace.AirWhisper`; changing it needs a settings and permissions migration plan.
- [ ] Approve the contributor names/email addresses and company references visible in Git history and hosted PR/release content. Rewriting the README does not remove historical metadata.
- [ ] Choose the specific reviewed commits and features for the first public release. Open feature PRs remain separate review decisions; preparation does not authorize merging them.
- [ ] Identify who will publish releases and receive private vulnerability reports. Do not invent an unmonitored support email or promise a response time.

Record the approval through the company's chosen process. Do not commit private approval correspondence or employee agreements into a repository intended to become public.

## Validate the selected source and artifact

- [ ] Review the final selected Git refs and hosted content for secrets, customer data, internal integrations, and unnecessary personal metadata. Include all reachable history that will become public, PR descriptions/comments, release notes, assets, and CI logs/artifacts. A scan passing is evidence for that scope, not proof that every possible secret is absent.
- [ ] Keep ignored local model stores, recordings, diagnostic folders, and working files out of the repository and release. Share the generated app ZIP and checksum file, not an archive of a development directory.
- [ ] Verify the root project license is bundled at `Contents/Resources/LICENSE`, with upstream notices under `Contents/Resources/ThirdParty`. Check [the dependency inventory](../ThirdParty/NOTICES.md) against the exact build. If a model or optional feature is added, review its exact variant's license; the project MIT license does not replace it.
- [ ] Run `make all` from a clean checkout of the reviewed commit on Apple Silicon. Record the commit, macOS/toolchain, test results, skipped tests, version/build, and artifact SHA-256. Run the optional real-model test with its documented public fixture when preparing a release.
- [ ] Extract the ZIP into a separate temporary folder, verify `SHA256SUMS`, and run `scripts/verify-app.sh` against the extracted app. Inspect the artifact for local build paths and extended attributes as well as source-level secrets. Upstream binary frameworks can retain their own public build metadata; removing application build paths is not a guarantee that every upstream path is absent.
- [ ] Complete the relevant [manual checks](../test-checklist.md) on the selected artifact, including clean installation, replacement of an existing install, version display, permission reapproval, hotkey behavior, Chrome/Slack insertion, microphone release, clipboard handling, and sleep/lock. Confirm installation on another Mac; do not substitute passing unit tests for these checks.
- [ ] State the supported distribution accurately: Apple Silicon, macOS 13.3 or later, ad hoc signing, no notarization, and manual updates. Managed Macs may need IT approval. Do not claim validation on an OS or hardware configuration that has not been tested.

## Prepare a reviewable release

The existing published release is **0.1.2**. This preparation contains **0.1.4 (build 5)** source changes, including Chrome accessibility support, visible version information, and permission diagnostics. Those changes are not downloadable from Releases until a reviewed artifact is published. Feature PRs are not implicitly part of that version.

1. After approval and review, merge only the selected changes through the normal review process. Build the exact resulting commit with a new version/build when needed; never silently replace an existing release's ZIP with different code.
2. Prepare release notes stating changes, full commit SHA, version/build, supported macOS/architecture, installation steps, known limitations, and permission reapproval after an ad hoc signed update. Use [README.md](../README.md#build-and-share-an-update) to create a **draft** release containing both `Air-Whisper.zip` and `SHA256SUMS`.
3. Review the draft, its ZIP, licenses, and checksum. Keep it private while company publication approval is pending. CI builds and tests changes; it does not publish a release.
4. At approved publication, remove the pending-approval notice and update the README to describe the actual available release. Check repository description, links, license detection, and install instructions. Enable GitHub private vulnerability reporting once the repository is public, verify that **Report a vulnerability** is available, and ensure the responsible maintainer receives notifications. [GitHub's configuration instructions](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)
5. Publish only the reviewed release and verify its Assets links as a user without organization membership. Keep future release notes and version instructions aligned with the actual artifact.

Changing visibility can expose the full repository history and hosted development content. Public copies and forks cannot be recalled by making the original private again. Review [GitHub's visibility consequences](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility) before that final action.
