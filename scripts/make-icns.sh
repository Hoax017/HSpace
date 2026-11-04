#!/usr/bin/env bash
# icon_1024.png → NSpace.icns (sips size ladder + iconutil, both ship with CLT)
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="Support/icon_1024.png"
SET="Support/icon.iconset"
[ -f "$SRC" ] || { echo "Missing $SRC, run first: swift scripts/generate-icon.swift $SRC"; exit 1; }
rm -rf "$SET" && mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "Support/NSpace.icns"
echo "Generated Support/NSpace.icns"
