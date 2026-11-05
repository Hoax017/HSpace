#!/usr/bin/env bash
# Build and launch HSpace; `./scripts/run.sh install` copies to /Applications and registers with LaunchServices
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh release

if [ "${1:-}" = "install" ]; then
  # Copy first, swap after: a failed copy must leave the installed app in place.
  NEW=/Applications/.HSpace.app.new
  OLD=/Applications/.HSpace.app.old
  rm -rf "$NEW" "$OLD"
  trap 'rm -rf "$NEW"' EXIT
  cp -R build/HSpace.app "$NEW"
  [ ! -e /Applications/HSpace.app ] || mv /Applications/HSpace.app "$OLD"
  mv "$NEW" /Applications/HSpace.app
  rm -rf "$OLD"
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREG" -f /Applications/HSpace.app
  echo "✓ Installed /Applications/HSpace.app and registered with LaunchServices"
  open /Applications/HSpace.app
else
  open build/HSpace.app
fi
