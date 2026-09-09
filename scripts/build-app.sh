#!/bin/bash
# A standalone app for teammates: no developer account, Homebrew, or toolchain at runtime.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_DIR="$REPO_DIR/dist/Air Whisper.app"
FRAMEWORK_SOURCE="$REPO_DIR/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
[[ "$CONFIGURATION" == release || "$CONFIGURATION" == debug ]] || { echo "CONFIGURATION must be release or debug" >&2; exit 1; }
AIR_WHISPER_APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/Resources/Info.plist")}"
AIR_WHISPER_APP_BUILD="${APP_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$REPO_DIR/Resources/Info.plist")}"
[[ "$AIR_WHISPER_APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APP_VERSION must have three numeric components, for example 0.1.1" >&2; exit 1; }
[[ "$AIR_WHISPER_APP_BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "APP_BUILD must contain one to three numeric components, for example 2" >&2; exit 1; }
"$REPO_DIR/scripts/bootstrap-whisper.sh"
"$REPO_DIR/scripts/swift.sh" build -c "$CONFIGURATION"
BIN_DIR="$("$REPO_DIR/scripts/swift.sh" build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$REPO_DIR/dist"
# Delete only our generated artifact, never an installed app or user data.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/AirWhisper" "$APP_DIR/Contents/MacOS/AirWhisper"
# SwiftPM may add the build machine's Xcode toolchain as a library search path.
# The distributed app resolves only OS libraries and its own embedded framework.
while IFS= read -r SEARCH_PATH; do
    case "$SEARCH_PATH" in
        /usr/lib/swift|@*) ;;
        *) install_name_tool -delete_rpath "$SEARCH_PATH" "$APP_DIR/Contents/MacOS/AirWhisper" ;;
    esac
done < <(otool -l "$APP_DIR/Contents/MacOS/AirWhisper" | awk '/cmd LC_RPATH/{getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*$/, ""); print}')
cp "$REPO_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $AIR_WHISPER_APP_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $AIR_WHISPER_APP_BUILD" "$APP_DIR/Contents/Info.plist"
ditto "$FRAMEWORK_SOURCE" "$APP_DIR/Contents/Frameworks/whisper.framework"
ditto "$REPO_DIR/ThirdParty" "$APP_DIR/Contents/Resources/ThirdParty"
mkdir -p "$REPO_DIR/.build/AppIcon.iconset"
CLANG_MODULE_CACHE_PATH="$REPO_DIR/.build/ModuleCache" /usr/bin/swift "$REPO_DIR/scripts/make-icon.swift" "$REPO_DIR/.build/AppIcon.iconset"
iconutil -c icns "$REPO_DIR/.build/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
# '-' is a local ad hoc signature, with no certificate, account, or notarization.
codesign --force --sign - "$APP_DIR/Contents/Frameworks/whisper.framework"
codesign --force --sign - "$APP_DIR"
"$REPO_DIR/scripts/verify-app.sh" "$APP_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$REPO_DIR/dist/Air-Whisper.zip"
(
    cd "$REPO_DIR/dist"
    shasum -a 256 Air-Whisper.zip > SHA256SUMS
)
echo "Built Air Whisper $AIR_WHISPER_APP_VERSION ($AIR_WHISPER_APP_BUILD): $APP_DIR"
echo "Share $REPO_DIR/dist/Air-Whisper.zip and SHA256SUMS with teammates."
