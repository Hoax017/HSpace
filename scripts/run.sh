#!/usr/bin/env bash
# Build and launch NSpace; `./scripts/run.sh install` copies to /Applications and registers with LaunchServices
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/NSpace.app
  cp -R build/NSpace.app /Applications/
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREG" -f /Applications/NSpace.app
  echo "✓ Installed /Applications/NSpace.app and registered with LaunchServices"
  open /Applications/NSpace.app
else
  open build/NSpace.app
fi
