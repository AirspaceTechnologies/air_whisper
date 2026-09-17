# Security reporting

Please report suspected vulnerabilities privately. Do not post credentials, recorded audio, transcripts, personal data, or a working exploit against another person's system in an issue or pull request.

While this repository is private and public release approval is pending, use an existing private contact with a repository maintainer. A public reporting channel must be confirmed as part of the [release checklist](docs/PUBLIC_RELEASE.md).

Once enabled for the public repository, GitHub's **Security → Advisories → Report a vulnerability** form provides private reporting. Do not assume a normal GitHub issue is private. If that button is unavailable and you have no private maintainer contact, open an issue requesting a private security contact without describing the vulnerability, affected data, or exploit. Wait for a private channel before sending details.

Include the Air Whisper version/build, macOS version, affected component, expected versus actual behavior, and reproduction steps using synthetic data. Identify whether you used a published ZIP or built a branch yourself. Keep any proof of concept limited to systems and data you are authorized to test.

Air Whisper records only on explicit push-to-talk and performs inference locally. Its microphone, global hotkey, accessibility, clipboard, and model-download paths still cross security and privacy boundaries. Clipboard restoration cannot remove copies retained by another app or clipboard service; see [privacy and storage](README.md#privacy-and-storage). Include the relevant boundary when describing a report.
