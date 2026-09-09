#!/bin/bash
# Developer release check. Reads a built bundle; never installs, opens the GUI,
# requests permissions, touches preferences, or records audio.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -le 1 ]] || { echo "Usage: $0 [path/to/Air Whisper.app]" >&2; exit 2; }
APP_PATH="${1:-$REPO_DIR/dist/Air Whisper.app}"

fail() { echo "App verification failed: $*" >&2; exit 1; }
[[ -d "$APP_PATH" ]] || fail "bundle does not exist: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd -P)"
INFO_PATH="$APP_PATH/Contents/Info.plist"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/AirWhisper"
FRAMEWORK_PATH="$APP_PATH/Contents/Frameworks/whisper.framework"
LIBRARY_PATH="$FRAMEWORK_PATH/Versions/Current/whisper"

[[ -f "$INFO_PATH" ]] || fail "missing Info.plist"
/usr/bin/plutil -lint "$INFO_PATH" >/dev/null
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PATH"; }
[[ "$(plist_value CFBundleIdentifier)" == org.airspace.AirWhisper ]] || fail "unexpected bundle identifier"
[[ "$(plist_value CFBundleExecutable)" == AirWhisper ]] || fail "unexpected executable name"
[[ "$(plist_value CFBundlePackageType)" == APPL ]] || fail "bundle is not an application"
[[ "$(plist_value LSMinimumSystemVersion)" == 13.3 ]] || fail "deployment target must match the packaged framework (13.3)"
[[ "$(plist_value LSUIElement)" == true ]] || fail "menu app metadata is missing"
[[ -n "$(plist_value NSMicrophoneUsageDescription)" ]] || fail "microphone permission explanation is missing"
[[ -n "$(plist_value CFBundleShortVersionString)" && -n "$(plist_value CFBundleVersion)" ]] || fail "version metadata is missing"
[[ -x "$EXECUTABLE_PATH" && -f "$LIBRARY_PATH" ]] || fail "executable or embedded whisper framework is missing"
[[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]] || fail "app icon is missing"
for NOTICE in NOTICES.md whisper.cpp-LICENSE.txt Whisper-LICENSE.txt; do
    [[ -s "$APP_PATH/Contents/Resources/ThirdParty/$NOTICE" ]] || fail "missing third-party notice: $NOTICE"
done

# No certificate or developer account is involved. Verify both the nested code and
# the final resource seal before running even the noninteractive diagnostic.
for SIGNED_PATH in "$FRAMEWORK_PATH" "$APP_PATH"; do
    /usr/bin/codesign --verify --deep --strict "$SIGNED_PATH"
    SIGNING_DETAILS="$(/usr/bin/codesign --display --verbose=4 "$SIGNED_PATH" 2>&1)"
    case "$SIGNING_DETAILS" in
        *$'\nSignature=adhoc'*) ;;
        *) fail "expected an ad hoc signature: $SIGNED_PATH" ;;
    esac
done

# The app and official universal framework may reference only system libraries or
# this embedded framework. Check every architecture reported by otool.
for MACHO_PATH in "$EXECUTABLE_PATH" "$LIBRARY_PATH"; do
    MACHO_DEPENDENCIES="$(/usr/bin/otool -L "$MACHO_PATH")"
    while IFS= read -r DEPENDENCY; do
        case "$DEPENDENCY" in
            /System/Library/*|/usr/lib/*) ;;
            @rpath/whisper.framework/Versions/Current/whisper|@rpath/whisper.framework/Versions/A/whisper) ;;
            *) fail "unexpected runtime dependency in $MACHO_PATH: $DEPENDENCY" ;;
        esac
    done < <(printf '%s\n' "$MACHO_DEPENDENCIES" | awk '/^[[:space:]]/ { print $1 }')

    MACHO_LOAD_COMMANDS="$(/usr/bin/otool -l "$MACHO_PATH")"
    while IFS= read -r SEARCH_PATH; do
        case "$SEARCH_PATH" in
            /usr/lib/swift) continue ;;
            @executable_path*) RESOLVED_PATH="$APP_PATH/Contents/MacOS${SEARCH_PATH#@executable_path}" ;;
            @loader_path*) RESOLVED_PATH="$(dirname "$MACHO_PATH")${SEARCH_PATH#@loader_path}" ;;
            *) fail "unexpected runtime search path in $MACHO_PATH: $SEARCH_PATH" ;;
        esac
        [[ -d "$RESOLVED_PATH" ]] || fail "runtime search directory is missing: $SEARCH_PATH"
        RESOLVED_PATH="$(cd "$RESOLVED_PATH" && pwd -P)"
        case "$RESOLVED_PATH/" in
            "$APP_PATH/"*) ;;
            *) fail "runtime search path escapes the application: $SEARCH_PATH" ;;
        esac
    done < <(printf '%s\n' "$MACHO_LOAD_COMMANDS" | awk '/cmd LC_RPATH/ { getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*$/, ""); print }')
done

"$EXECUTABLE_PATH" --self-check
echo "Verified $(plist_value CFBundleDisplayName) $(plist_value CFBundleShortVersionString) ($(plist_value CFBundleVersion)): ad hoc signatures, bundle metadata, and portable dependencies."
