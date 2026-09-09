#!/bin/bash
set -euo pipefail

# Developer-only dependency setup. Recipients use the framework embedded in the app.
AIR_WHISPER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIR_WHISPER_VERSION="b4938"
AIR_WHISPER_CHECKSUM="dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
AIR_WHISPER_VENDOR="$AIR_WHISPER_ROOT/Vendor"
AIR_WHISPER_FRAMEWORK="$AIR_WHISPER_VENDOR/whisper.xcframework"
AIR_WHISPER_STAMP="$AIR_WHISPER_VENDOR/whisper.sha256"

if [[ -f "$AIR_WHISPER_FRAMEWORK/Info.plist" && -f "$AIR_WHISPER_STAMP" ]] &&
   [[ "$(cat "$AIR_WHISPER_STAMP")" == "$AIR_WHISPER_CHECKSUM" ]]; then
    echo "whisper.cpp $AIR_WHISPER_VERSION is ready."
    exit 0
fi

mkdir -p "$AIR_WHISPER_VENDOR"
AIR_WHISPER_TEMP="$(mktemp -d "$AIR_WHISPER_VENDOR/.whisper-download.XXXXXX")"
trap 'rm -rf "$AIR_WHISPER_TEMP"' EXIT
echo "Downloading official whisper.cpp $AIR_WHISPER_VERSION XCFramework…"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://github.com/ggml-org/whisper.cpp/releases/download/$AIR_WHISPER_VERSION/whisper-$AIR_WHISPER_VERSION-xcframework.zip" \
    --output "$AIR_WHISPER_TEMP/whisper.zip"
AIR_WHISPER_ACTUAL="$(shasum -a 256 "$AIR_WHISPER_TEMP/whisper.zip" | awk '{print $1}')"
if [[ "$AIR_WHISPER_ACTUAL" != "$AIR_WHISPER_CHECKSUM" ]]; then
    echo "whisper.cpp checksum mismatch; refusing to install." >&2
    exit 1
fi
ditto -x -k "$AIR_WHISPER_TEMP/whisper.zip" "$AIR_WHISPER_TEMP/extracted"
test -f "$AIR_WHISPER_TEMP/extracted/build-apple/whisper.xcframework/Info.plist"
rm -rf "$AIR_WHISPER_FRAMEWORK"
mv "$AIR_WHISPER_TEMP/extracted/build-apple/whisper.xcframework" "$AIR_WHISPER_FRAMEWORK"
printf '%s\n' "$AIR_WHISPER_CHECKSUM" > "$AIR_WHISPER_STAMP"
echo "Verified whisper.cpp $AIR_WHISPER_VERSION."
