#!/usr/bin/env bash
# Build and launch HSpace; `./scripts/run.sh install` copies to /Applications and registers with LaunchServices
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release

if [ "${1:-}" = "install" ]; then
  rm -rf /Applications/HSpace.app
  cp -R build/HSpace.app /Applications/
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREG" -f /Applications/HSpace.app
  echo "✓ Installed /Applications/HSpace.app and registered with LaunchServices"
  open /Applications/HSpace.app
else
  open build/HSpace.app
fi
