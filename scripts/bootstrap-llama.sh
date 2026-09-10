#!/bin/bash
set -euo pipefail

# Developer-only dependency setup. Recipients use the framework embedded in the app.
AIR_WHISPER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIR_WHISPER_LLAMA_VERSION="b10896"
AIR_WHISPER_LLAMA_CHECKSUM="66b906c00395d7b34e693595b47040ff39ac38363ae69c2ba249a8775ee6a31b"
AIR_WHISPER_VENDOR="$AIR_WHISPER_ROOT/Vendor"
AIR_WHISPER_LLAMA_FRAMEWORK="$AIR_WHISPER_VENDOR/llama.xcframework"
AIR_WHISPER_LLAMA_STAMP="$AIR_WHISPER_VENDOR/llama.sha256"

if [[ -f "$AIR_WHISPER_LLAMA_FRAMEWORK/Info.plist" && -f "$AIR_WHISPER_LLAMA_STAMP" ]] &&
   [[ "$(cat "$AIR_WHISPER_LLAMA_STAMP")" == "$AIR_WHISPER_LLAMA_CHECKSUM" ]]; then
    echo "llama.cpp $AIR_WHISPER_LLAMA_VERSION is ready."
    exit 0
fi

mkdir -p "$AIR_WHISPER_VENDOR"
AIR_WHISPER_TEMP="$(mktemp -d "$AIR_WHISPER_VENDOR/.llama-download.XXXXXX")"
trap 'rm -rf "$AIR_WHISPER_TEMP"' EXIT
echo "Downloading official llama.cpp $AIR_WHISPER_LLAMA_VERSION XCFramework…"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "https://github.com/ggml-org/llama.cpp/releases/download/$AIR_WHISPER_LLAMA_VERSION/llama-$AIR_WHISPER_LLAMA_VERSION-xcframework.zip" \
    --output "$AIR_WHISPER_TEMP/llama.zip"
AIR_WHISPER_LLAMA_ACTUAL="$(shasum -a 256 "$AIR_WHISPER_TEMP/llama.zip" | awk '{print $1}')"
if [[ "$AIR_WHISPER_LLAMA_ACTUAL" != "$AIR_WHISPER_LLAMA_CHECKSUM" ]]; then
    echo "llama.cpp checksum mismatch; refusing to install." >&2
    exit 1
fi
ditto -x -k "$AIR_WHISPER_TEMP/llama.zip" "$AIR_WHISPER_TEMP/extracted"
test -f "$AIR_WHISPER_TEMP/extracted/build-apple/llama.xcframework/Info.plist"
rm -rf "$AIR_WHISPER_LLAMA_FRAMEWORK"
mv "$AIR_WHISPER_TEMP/extracted/build-apple/llama.xcframework" "$AIR_WHISPER_LLAMA_FRAMEWORK"
printf '%s\n' "$AIR_WHISPER_LLAMA_CHECKSUM" > "$AIR_WHISPER_LLAMA_STAMP"
echo "Verified llama.cpp $AIR_WHISPER_LLAMA_VERSION."
