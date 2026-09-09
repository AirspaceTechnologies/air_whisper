#!/bin/bash
# Build the native app without modifying an installed app or Hammerspoon configuration.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$REPO_DIR/scripts/build-app.sh" "$@"
