#!/usr/bin/env bash
# Public asset sanitization gate (legislated after the I-35 incident, runs on pre-push):
# The sensitive term list lives in .sanitize-terms (gitignored, not committed: the list itself is sensitive); with no list the check is skipped (a new environment is not blocked).
# Scans all tracked text files; any hit refuses the push. Images cannot be machine-scanned: the cross-cutting spec requires final human review + demo fixture generation.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
TERMS="$ROOT/.sanitize-terms"
[ -f "$TERMS" ] || { echo "· sanitize-check: no term list on this machine, skipping (public screenshots still need human review)"; exit 0; }
hits=$( { git -C "$ROOT" grep -n -f "$TERMS" -- ':!*.png' ':!*.icns' || true; } | head -20)
if [ -n "$hits" ]; then
  echo "✗ sanitize-check: sensitive term hit, push refused:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "✓ sanitize-check: tracked text is free of sensitive terms"
