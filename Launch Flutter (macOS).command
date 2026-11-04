#!/usr/bin/env bash
# Double-click in Finder: installs Flutter if needed (Homebrew), fetches the
# dependencies, builds the unsigned macOS app against the dev backend and
# opens it. Same as `scripts/launch.sh build macos`.
set -euo pipefail
cd "$(dirname "$0")"
scripts/launch.sh build macos
open "frontend/build/macos/Build/Products/Release/EveryAI.app"
