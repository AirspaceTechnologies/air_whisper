#!/bin/bash
# Keep SwiftPM/compiler caches inside the checkout, including on restricted build runners.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$REPO_DIR/.build/cache" "$REPO_DIR/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$REPO_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_DIR/.build/ModuleCache"
cd "$REPO_DIR"
ACTION="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
exec /usr/bin/swift "$ACTION" --disable-sandbox --cache-path "$REPO_DIR/.build/cache" "$@"
