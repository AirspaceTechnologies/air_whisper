#!/bin/bash
set -euo pipefail

# Developer-only dependency setup. Recipients use the framework embedded in the app.
AIR_WHISPER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIR_WHISPER_VERSION="b4938"
AIR_WHISPER_CHECKSUM="dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
AIR_WHISPER_VENDOR="$AIR_WHISPER_ROOT/Vendor"
AIR_WHISPER_FRAMEWORK="$AIR_WHISPER_VENDOR/whisper.xcframework"
AIR_WHISPER_ARCHIVE="$AIR_WHISPER_VENDOR/whisper-$AIR_WHISPER_VERSION-xcframework.zip"

mkdir -p "$AIR_WHISPER_VENDOR"
AIR_WHISPER_TEMP="$(mktemp -d "$AIR_WHISPER_VENDOR/.whisper-download.XXXXXX")"
trap 'rm -rf "$AIR_WHISPER_TEMP"' EXIT
AIR_WHISPER_DOWNLOADED=false
if [[ -e "$AIR_WHISPER_ARCHIVE" || -L "$AIR_WHISPER_ARCHIVE" ]]; then
    [[ -f "$AIR_WHISPER_ARCHIVE" ]] || { echo "whisper.cpp archive cache is not a regular file: $AIR_WHISPER_ARCHIVE" >&2; exit 1; }
    echo "Verifying cached whisper.cpp $AIR_WHISPER_VERSION archive…"
    cp "$AIR_WHISPER_ARCHIVE" "$AIR_WHISPER_TEMP/whisper.zip"
else
    echo "Downloading official whisper.cpp $AIR_WHISPER_VERSION XCFramework…"
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "https://github.com/ggml-org/whisper.cpp/releases/download/$AIR_WHISPER_VERSION/whisper-$AIR_WHISPER_VERSION-xcframework.zip" \
        --output "$AIR_WHISPER_TEMP/whisper.zip"
    AIR_WHISPER_DOWNLOADED=true
fi
# Verify and extract the same temporary snapshot. The extracted cache and old
# checksum stamps cannot establish that the framework still matches this pin.
AIR_WHISPER_ACTUAL="$(shasum -a 256 "$AIR_WHISPER_TEMP/whisper.zip" | awk '{print $1}')"
if [[ "$AIR_WHISPER_ACTUAL" != "$AIR_WHISPER_CHECKSUM" ]]; then
    echo "whisper.cpp checksum mismatch; refusing to install." >&2
    if [[ "$AIR_WHISPER_DOWNLOADED" == false ]]; then
        echo "Remove the invalid archive cache and retry: $AIR_WHISPER_ARCHIVE" >&2
    fi
    exit 1
fi
if ! ditto -x -k "$AIR_WHISPER_TEMP/whisper.zip" "$AIR_WHISPER_TEMP/extracted"; then
    echo "whisper.cpp archive extraction failed; existing framework was preserved." >&2
    exit 1
fi
AIR_WHISPER_EXTRACTED="$AIR_WHISPER_TEMP/extracted/build-apple/whisper.xcframework"
for AIR_WHISPER_REQUIRED in Info.plist \
    macos-arm64_x86_64/whisper.framework/whisper \
    macos-arm64_x86_64/whisper.framework/Headers/whisper.h \
    macos-arm64_x86_64/whisper.framework/Modules/module.modulemap \
    macos-arm64_x86_64/whisper.framework/Resources/Info.plist; do
    if [[ ! -s "$AIR_WHISPER_EXTRACTED/$AIR_WHISPER_REQUIRED" ]]; then
        echo "whisper.cpp archive is missing $AIR_WHISPER_REQUIRED; existing framework was preserved." >&2
        exit 1
    fi
done
if [[ "$AIR_WHISPER_DOWNLOADED" == true ]]; then
    mv "$AIR_WHISPER_TEMP/whisper.zip" "$AIR_WHISPER_ARCHIVE"
fi
rm -rf "$AIR_WHISPER_FRAMEWORK"
mv "$AIR_WHISPER_EXTRACTED" "$AIR_WHISPER_FRAMEWORK"
echo "Verified and restored whisper.cpp $AIR_WHISPER_VERSION."
