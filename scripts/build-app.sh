#!/usr/bin/env bash
# HSpace build pipeline without Xcode: swift build → assemble .app → sign
# Usage: ./scripts/build-app.sh [debug|release]   (default release)
# Signing identity priority: env SIGN_IDENTITY > the local fixed certificate "HSpace Dev" (I-29 root fix: ad-hoc changes the fingerprint on every build,
# so the icon service/TCC treats each build as an unknown app: blank icons + FDA grant drift) > ad-hoc fallback (CI without a certificate lands here automatically)
if [ -z "${SIGN_IDENTITY:-}" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "HSpace Dev"; then
  SIGN_IDENTITY="HSpace Dev"
fi
# Environment: SIGN_IDENTITY can point to a self-signed certificate so TCC grants persist across builds; default "-" (ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-release}"
APP="build/HSpace.app"
BIN=".build/$CONF/HSpace"

swift build -c "$CONF"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HSpace"

# The probe stays out of the bundle (production binary isolation)
cp Support/Info.plist "$APP/Contents/Info.plist"
VERSION="$(cat VERSION | tr -d '[:space:]')"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUM" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Localization (every Resources/*.lproj: en is the development region, fr since L68) and icons
for LPROJ in Resources/*.lproj; do
  cp -R "$LPROJ" "$APP/Contents/Resources/"
done
if [ ! -f Support/HSpace.icns ]; then
  swift scripts/generate-icon.swift Support/icon_1024.png
  ./scripts/make-icns.sh
fi
cp Support/HSpace.icns "$APP/Contents/Resources/HSpace.icns"
# AppleScript dictionary (L62)
cp Support/HSpace.sdef "$APP/Contents/Resources/HSpace.sdef"

# App extensions (Lane 7). SwiftPM has no app extension target, so each extension is a plain executable product
# (its main hands over to NSExtensionMain) and is wrapped here. One folder per extension under Support/Extensions:
# Info.plist names the executable, and the one *.entitlements file holds its sandbox. Nested code is signed first.
for EXT_DIR in Support/Extensions/*/; do
  [ -f "$EXT_DIR/Info.plist" ] || continue
  EXT_BIN="$(plutil -extract CFBundleExecutable raw "$EXT_DIR/Info.plist")"
  EXT_ID="$(plutil -extract CFBundleIdentifier raw "$EXT_DIR/Info.plist")"
  EXT_ENT="$(ls "$EXT_DIR"*.entitlements)"
  EXT="$APP/Contents/PlugIns/$EXT_BIN.appex"
  mkdir -p "$EXT/Contents/MacOS" "$EXT/Contents/Resources"
  cp ".build/$CONF/$EXT_BIN" "$EXT/Contents/MacOS/$EXT_BIN"
  cp "$EXT_DIR/Info.plist" "$EXT/Contents/Info.plist"
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$EXT/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUM" "$EXT/Contents/Info.plist"
  plutil -lint "$EXT/Contents/Info.plist" >/dev/null
  # The app's strings table in every language, then the extension's own InfoPlist.strings (its display name)
  for LPROJ in Resources/*.lproj; do
    mkdir -p "$EXT/Contents/Resources/$(basename "$LPROJ")"
    cp "$LPROJ/Localizable.strings" "$EXT/Contents/Resources/$(basename "$LPROJ")/"
  done
  for LPROJ in "$EXT_DIR"*.lproj; do
    [ -d "$LPROJ" ] || continue
    mkdir -p "$EXT/Contents/Resources/$(basename "$LPROJ")"
    cp "$LPROJ"/*.strings "$EXT/Contents/Resources/$(basename "$LPROJ")/"
  done
  codesign --force --sign "${SIGN_IDENTITY:--}" --identifier "$EXT_ID" --entitlements "$EXT_ENT" "$EXT"
done

codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.hoax017.hspace "$APP"
echo "✓ Built and signed $APP (v$VERSION build $BUILD_NUM, sign=${SIGN_IDENTITY:-ad-hoc})"

# LS registration hygiene (I-15 root-cause regression guard): remove com.hspace registrations for vanished paths (leftovers from concurrent worktree builds
# make LaunchServices resolve to a dead bundle → setting the default app fails with "could not open the file" and the TCC panel loses the icon), then register the current build.
# CI runners have no existing registration (zero grep hits would kill the script under pipefail: item 5 on this project's pitfall list, confirmed by a CI recurrence),
# and registration means nothing for CI artifacts, so this runs only in a local dev environment.
if [ -z "${CI:-}" ]; then
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  # A dump line reads "path:   /some dir/HSpace.app (0x1a2b)": keep the whole path, spaces included.
  { "$LSREG" -dump 2>/dev/null | grep -E "^path:" | grep -i hspace | sed -E 's/^path:[[:space:]]+//; s/ \(0x[0-9a-f]+\)$//' | sort -u || true; } | while IFS= read -r p; do
    [ -d "$p" ] || "$LSREG" -u "$p" >/dev/null 2>&1 || true
  done
  "$LSREG" -f "$APP" >/dev/null 2>&1 || true
  echo "✓ LaunchServices cleared dead registrations and registered $APP"
fi
