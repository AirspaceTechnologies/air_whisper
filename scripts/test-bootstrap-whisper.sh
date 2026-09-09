#!/bin/bash
set -euo pipefail

# Exercise the production script offline with real SHA-256 and ZIP operations.
# Only curl is mocked; the copied script pins our tiny fixture's checksum.
AIR_WHISPER_TEST_SOURCE="$(cd "$(dirname "$0")" && pwd)/bootstrap-whisper.sh"
AIR_WHISPER_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/air-whisper-bootstrap-test.XXXXXX")"
trap 'rm -rf "$AIR_WHISPER_TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
digest() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$AIR_WHISPER_TEST_ROOT/bin"
cat > "$AIR_WHISPER_TEST_ROOT/bin/curl" <<'CURL'
#!/bin/bash
set -euo pipefail
printf 'curl\n' >> "$AIR_WHISPER_TEST_CURL_LOG"
[[ "$AIR_WHISPER_TEST_OFFLINE" == 0 ]] || exit 89
while (( $# )); do
    if [[ "$1" == --output ]]; then
        cp "$AIR_WHISPER_TEST_DOWNLOAD" "$2"
        exit 0
    fi
    shift
done
exit 90
CURL
chmod +x "$AIR_WHISPER_TEST_ROOT/bin/curl"
export PATH="$AIR_WHISPER_TEST_ROOT/bin:$PATH"

AIR_WHISPER_TEST_FIXTURE="$AIR_WHISPER_TEST_ROOT/fixture/build-apple/whisper.xcframework"
AIR_WHISPER_TEST_MACOS="$AIR_WHISPER_TEST_FIXTURE/macos-arm64_x86_64/whisper.framework"
mkdir -p "$AIR_WHISPER_TEST_MACOS/Headers" "$AIR_WHISPER_TEST_MACOS/Modules" "$AIR_WHISPER_TEST_MACOS/Resources"
printf 'fixture xcframework metadata\n' > "$AIR_WHISPER_TEST_FIXTURE/Info.plist"
printf 'original framework binary\n' > "$AIR_WHISPER_TEST_MACOS/whisper"
printf 'fixture header\n' > "$AIR_WHISPER_TEST_MACOS/Headers/whisper.h"
printf 'fixture module\n' > "$AIR_WHISPER_TEST_MACOS/Modules/module.modulemap"
printf 'fixture framework metadata\n' > "$AIR_WHISPER_TEST_MACOS/Resources/Info.plist"
AIR_WHISPER_TEST_ZIP="$AIR_WHISPER_TEST_ROOT/fixture.zip"
ditto -c -k --keepParent "$AIR_WHISPER_TEST_ROOT/fixture/build-apple" "$AIR_WHISPER_TEST_ZIP"
AIR_WHISPER_TEST_CHECKSUM="$(digest "$AIR_WHISPER_TEST_ZIP")"

new_case() {
    AIR_WHISPER_TEST_CASE="$AIR_WHISPER_TEST_ROOT/$1"
    mkdir -p "$AIR_WHISPER_TEST_CASE/scripts" "$AIR_WHISPER_TEST_CASE/Vendor"
    sed "s/^AIR_WHISPER_CHECKSUM=.*/AIR_WHISPER_CHECKSUM=\"${2:-$AIR_WHISPER_TEST_CHECKSUM}\"/" \
        "$AIR_WHISPER_TEST_SOURCE" > "$AIR_WHISPER_TEST_CASE/scripts/bootstrap-whisper.sh"
    AIR_WHISPER_TEST_FRAMEWORK="$AIR_WHISPER_TEST_CASE/Vendor/whisper.xcframework"
    AIR_WHISPER_TEST_ARCHIVE="$AIR_WHISPER_TEST_CASE/Vendor/whisper-b4938-xcframework.zip"
    export AIR_WHISPER_TEST_CURL_LOG="$AIR_WHISPER_TEST_CASE/curl.log"
    export AIR_WHISPER_TEST_DOWNLOAD="$AIR_WHISPER_TEST_ZIP"
    export AIR_WHISPER_TEST_OFFLINE=0
}

bootstrap() {
    bash "$AIR_WHISPER_TEST_CASE/scripts/bootstrap-whisper.sh" > "$AIR_WHISPER_TEST_CASE/output.log" 2>&1
}

expect_success() {
    if ! bootstrap; then
        cat "$AIR_WHISPER_TEST_CASE/output.log" >&2
        fail "bootstrap failed in $AIR_WHISPER_TEST_CASE"
    fi
}

expect_failure() {
    if bootstrap; then fail "bootstrap unexpectedly accepted $1"; fi
    case "$(cat "$AIR_WHISPER_TEST_CASE/output.log")" in
        *"$2"*) ;;
        *) cat "$AIR_WHISPER_TEST_CASE/output.log" >&2; fail "wrong failure for $1" ;;
    esac
}

expect_original_framework() {
    diff -r "$AIR_WHISPER_TEST_FIXTURE" "$AIR_WHISPER_TEST_FRAMEWORK" || fail "framework was not restored from the verified archive"
}

preserve_existing_framework() {
    ditto "$AIR_WHISPER_TEST_FIXTURE" "$AIR_WHISPER_TEST_FRAMEWORK"
    printf 'preserve existing installation\n' > "$AIR_WHISPER_TEST_FRAMEWORK/local-marker"
    ditto "$AIR_WHISPER_TEST_FRAMEWORK" "$AIR_WHISPER_TEST_CASE/before"
}

expect_preserved_framework() {
    diff -r "$AIR_WHISPER_TEST_CASE/before" "$AIR_WHISPER_TEST_FRAMEWORK" || fail "failed bootstrap changed the existing framework"
}

# This is the original regression: a plausible stamp cannot authenticate an
# extracted framework. Cached, verified bytes must repair it without networking.
new_case tampered-extraction
ditto "$AIR_WHISPER_TEST_FIXTURE" "$AIR_WHISPER_TEST_FRAMEWORK"
cp "$AIR_WHISPER_TEST_ZIP" "$AIR_WHISPER_TEST_ARCHIVE"
printf '%s\n' "$AIR_WHISPER_TEST_CHECKSUM" > "$AIR_WHISPER_TEST_CASE/Vendor/whisper.sha256"
printf 'altered framework binary\n' > "$AIR_WHISPER_TEST_FRAMEWORK/macos-arm64_x86_64/whisper.framework/whisper"
printf 'injected file\n' > "$AIR_WHISPER_TEST_FRAMEWORK/injected"
printf 'external file stays intact\n' > "$AIR_WHISPER_TEST_CASE/external"
ln -s "$AIR_WHISPER_TEST_CASE/external" "$AIR_WHISPER_TEST_FRAMEWORK/injected-link"
AIR_WHISPER_TEST_OFFLINE=1
expect_success
expect_original_framework
[[ ! -e "$AIR_WHISPER_TEST_CURL_LOG" ]] || fail "cached bootstrap invoked curl"
[[ "$(cat "$AIR_WHISPER_TEST_CASE/external")" == 'external file stays intact' ]] || fail "cleanup followed an injected symlink"
echo 'PASS: verified offline cache repairs changed files and removes injected files/symlinks'

new_case initial-download
expect_success
expect_original_framework
cmp "$AIR_WHISPER_TEST_ZIP" "$AIR_WHISPER_TEST_ARCHIVE" || fail "verified download was not retained"
[[ "$(cat "$AIR_WHISPER_TEST_CURL_LOG")" == curl ]] || fail "initial bootstrap did not download exactly once"
AIR_WHISPER_TEST_OFFLINE=1
expect_success
expect_original_framework
[[ "$(cat "$AIR_WHISPER_TEST_CURL_LOG")" == curl ]] || fail "offline reuse invoked curl"
echo 'PASS: initial download is retained and reused offline'

new_case forged-legacy-stamp
ditto "$AIR_WHISPER_TEST_FIXTURE" "$AIR_WHISPER_TEST_FRAMEWORK"
printf 'altered metadata\n' > "$AIR_WHISPER_TEST_FRAMEWORK/Info.plist"
printf '%s\n' "$AIR_WHISPER_TEST_CHECKSUM" > "$AIR_WHISPER_TEST_CASE/Vendor/whisper.sha256"
expect_success
expect_original_framework
[[ -s "$AIR_WHISPER_TEST_ARCHIVE" && -s "$AIR_WHISPER_TEST_CURL_LOG" ]] || fail "legacy stamp bypassed archive acquisition"
echo 'PASS: forged legacy stamp cannot bypass archive verification'

new_case corrupt-cache
preserve_existing_framework
cp "$AIR_WHISPER_TEST_ZIP" "$AIR_WHISPER_TEST_ARCHIVE"
printf 'corruption\n' >> "$AIR_WHISPER_TEST_ARCHIVE"
AIR_WHISPER_TEST_OFFLINE=1
expect_failure 'corrupt cached archive' 'checksum mismatch'
expect_preserved_framework
[[ ! -e "$AIR_WHISPER_TEST_CURL_LOG" ]] || fail "corrupt cache triggered a download"
echo 'PASS: corrupt cached archive is rejected without changing the framework'

new_case corrupt-download
preserve_existing_framework
AIR_WHISPER_TEST_DOWNLOAD="$AIR_WHISPER_TEST_CASE/corrupt.zip"
printf 'corrupt downloaded archive\n' > "$AIR_WHISPER_TEST_DOWNLOAD"
expect_failure 'corrupt downloaded archive' 'checksum mismatch'
expect_preserved_framework
[[ ! -e "$AIR_WHISPER_TEST_ARCHIVE" ]] || fail "corrupt download was cached"
echo 'PASS: corrupt downloaded archive is rejected without changing the framework'

# Match the digest deliberately to reach extraction and layout validation.
AIR_WHISPER_TEST_INVALID_ZIP="$AIR_WHISPER_TEST_ROOT/not-a-zip"
printf 'not a ZIP archive\n' > "$AIR_WHISPER_TEST_INVALID_ZIP"
new_case extraction-failure "$(digest "$AIR_WHISPER_TEST_INVALID_ZIP")"
preserve_existing_framework
AIR_WHISPER_TEST_DOWNLOAD="$AIR_WHISPER_TEST_INVALID_ZIP"
expect_failure 'invalid ZIP with matching digest' 'extraction failed'
expect_preserved_framework
[[ ! -e "$AIR_WHISPER_TEST_ARCHIVE" ]] || fail "invalid ZIP was cached"
echo 'PASS: extraction failure preserves the framework'

AIR_WHISPER_TEST_INCOMPLETE="$AIR_WHISPER_TEST_ROOT/incomplete/build-apple/whisper.xcframework"
mkdir -p "$AIR_WHISPER_TEST_INCOMPLETE"
cp "$AIR_WHISPER_TEST_FIXTURE/Info.plist" "$AIR_WHISPER_TEST_INCOMPLETE/Info.plist"
AIR_WHISPER_TEST_INCOMPLETE_ZIP="$AIR_WHISPER_TEST_ROOT/incomplete.zip"
ditto -c -k --keepParent "$AIR_WHISPER_TEST_ROOT/incomplete/build-apple" "$AIR_WHISPER_TEST_INCOMPLETE_ZIP"
new_case missing-framework-files "$(digest "$AIR_WHISPER_TEST_INCOMPLETE_ZIP")"
preserve_existing_framework
AIR_WHISPER_TEST_DOWNLOAD="$AIR_WHISPER_TEST_INCOMPLETE_ZIP"
expect_failure 'archive missing framework files' 'archive is missing'
expect_preserved_framework
[[ ! -e "$AIR_WHISPER_TEST_ARCHIVE" ]] || fail "incomplete framework was cached"
echo 'PASS: missing framework files preserve the existing installation'

echo 'All 7 bootstrap regression checks passed.'
