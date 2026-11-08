#!/usr/bin/env bash
# Checks a built HSpace.app and the app extensions inside it, without launching anything.
# macOS refuses an extension silently when one of these is wrong, so CI and the release check them after build-app.sh.
# Usage: ./scripts/check-bundle.sh [path/to/HSpace.app]   (default build/HSpace.app)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/HSpace.app}"
APP_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
rc=0
fail() { echo "✗ $*"; rc=1; }

expected=0
for EXT_DIR in Support/Extensions/*/; do
  [ -f "$EXT_DIR/Info.plist" ] || continue
  expected=$((expected + 1))
  BIN="$(plutil -extract CFBundleExecutable raw "$EXT_DIR/Info.plist")"
  EXT="$APP/Contents/PlugIns/$BIN.appex"
  PLIST="$EXT/Contents/Info.plist"
  [ -d "$EXT" ] || { fail "$BIN.appex is missing from $APP"; continue; }
  plutil -lint "$PLIST" >/dev/null || fail "$BIN: Info.plist does not parse"
  [ -x "$EXT/Contents/MacOS/$BIN" ] || fail "$BIN: executable missing"
  [ "$(plutil -extract CFBundlePackageType raw "$PLIST")" = "XPC!" ] || fail "$BIN: package type must be XPC!"
  ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")"
  case "$ID" in "$APP_ID".*) ;; *) fail "$BIN: identifier $ID must start with $APP_ID." ;; esac
  [ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" = "$APP_VERSION" ] || fail "$BIN: version differs from the app"
  plutil -extract NSExtension.NSExtensionPointIdentifier raw "$PLIST" >/dev/null || fail "$BIN: no extension point"
  PRINCIPAL="$(plutil -extract NSExtension.NSExtensionPrincipalClass raw "$PLIST")"
  # The Objective-C class list, not the symbol table: a release build strips the symbols
  CLASSES="$(otool -ov "$EXT/Contents/MacOS/$BIN")"
  grep -qE "^ +name +0x[0-9a-f]+ $PRINCIPAL\$" <<< "$CLASSES" || fail "$BIN: principal class $PRINCIPAL is not in the executable"
  for LPROJ in Resources/*.lproj; do
    LANG_DIR="$(basename "$LPROJ")"
    [ -f "$EXT/Contents/Resources/$LANG_DIR/Localizable.strings" ] || fail "$BIN: $LANG_DIR strings missing"
  done
  for LPROJ in "$EXT_DIR"*.lproj; do
    [ -d "$LPROJ" ] || continue
    [ -f "$EXT/Contents/Resources/$(basename "$LPROJ")/InfoPlist.strings" ] || fail "$BIN: $(basename "$LPROJ") InfoPlist.strings missing"
  done
  ENTS="$(codesign -d --entitlements - --xml "$EXT" 2>/dev/null || true)"
  grep -q "com.apple.security.app-sandbox" <<< "$ENTS" || fail "$BIN: not sandboxed, macOS will not load it"
  codesign --verify --strict "$EXT" || fail "$BIN: signature does not verify"
done
# Localizations (L68): every language in Resources lands in the app, and each table parses
for LPROJ in Resources/*.lproj; do
  for TABLE in "$LPROJ"/*.strings; do
    SHIPPED="$APP/Contents/Resources/$(basename "$LPROJ")/$(basename "$TABLE")"
    [ -f "$SHIPPED" ] || { fail "$SHIPPED is missing"; continue; }
    plutil -lint "$SHIPPED" >/dev/null || fail "$SHIPPED does not parse"
  done
done
found="$(find "$APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' 2>/dev/null | wc -l | tr -d ' ')"
[ "$found" = "$expected" ] || fail "$found extensions in the app, $expected expected"
# AppleScript dictionary (L62): present, and valid against the system's sdef DTD with the Standard Suite pulled in
SDEF="$APP/Contents/Resources/$(plutil -extract OSAScriptingDefinition raw "$APP/Contents/Info.plist")"
[ -f "$SDEF" ] || fail "the scripting dictionary is missing"
xmllint --noout --xinclude --dtdvalid /System/Library/DTDs/sdef.dtd "$SDEF" || fail "the scripting dictionary does not validate"
codesign --verify --strict --deep "$APP" || fail "the app's signature does not verify"

[ $rc -eq 0 ] && echo "✓ check-bundle: $APP and $expected extensions are well formed"
exit $rc
