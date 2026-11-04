#!/usr/bin/env bash
# Deterministic grid enforcement (BG-0 compiled output; rule source: frontend-design-methodology.md:84 "all sizes strictly converge on the 4pt/8pt scale")
# Scans UI size constants (constraint constant / spacing / NSEdgeInsets sides):
#   Exempt: multiples of 4; |value|≤2 (hairlines and optical corrections, the same document's :86 allows 1~2px centering tweaks); decimals (0.5 hairlines).
#   Legacy/intentional exceptions go in scripts/grid-lint-allow.txt (format "filename:value", reason in an inline # comment); anything unregistered is red.
set -euo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel)}"
ALLOW="$ROOT/scripts/grid-lint-allow.txt"

# Default incremental mode: check only Swift files staged this time (pre-commit semantics: the file you touch is the file you must bring into line);
# GRID_LINT_ALL=1 = full audit (for acceptance gates/CI).
if [ "${GRID_LINT_ALL:-0}" = "1" ]; then
    TARGETS="$ROOT/Sources"
else
    staged=$(git -C "$ROOT" diff --cached --name-only --diff-filter=ACM 2>/dev/null \
             | grep -E '^Sources/.*\.swift$' || true)
    if [ -z "$staged" ]; then echo "✓ grid-lint: no Sources Swift changes this time"; exit 0; fi
    TARGETS=$(printf '%s\n' "$staged" | sed "s|^|$ROOT/|" | tr '\n' ' ')
fi

violations=$( { grep -rnE '(equalToConstant:|constant:|spacing[[:space:]]*[:=]|NSEdgeInsets\()' \
    $TARGETS --include='*.swift' 2>/dev/null \
  | grep -v 'UISelfTest.swift' \
  | awk -F: '
    {
      file=$1; lineno=$2
      line=$0; sub(/^[^:]*:[^:]*:/, "", line)
      rest=line
      while (match(rest, /[a-zA-Z]+[[:space:]]*[:=][[:space:]]*-?[0-9]+(\.[0-9]+)?/)) {
        tok=substr(rest, RSTART, RLENGTH)
        rest=substr(rest, RSTART+RLENGTH)
        key=tok; sub(/[[:space:]]*[:=].*/, "", key)
        val=tok; sub(/^[a-zA-Z]+[[:space:]]*[:=][[:space:]]*/, "", val)
        low=tolower(key)
        if (low !~ /onstant$/ && key !~ /^(spacing|top|left|bottom|right)$/) continue
        if (val ~ /\./) continue                # Decimal = hairline, exempt
        a = val + 0; if (a < 0) a = -a
        if (a <= 2) continue                    # Optical correction exempt
        if (a % 4 == 0) continue                # On the scale
        n=split(file, parts, "/"); base=parts[n]
        printf "%s:%s  %s = %s\n", base, lineno, key, val
      }
    }' | sort -u; } || true)

fail=0; out=""
while IFS= read -r v; do
  [ -z "$v" ] && continue
  base="${v%%:*}"
  num=$(printf '%s' "$v" | grep -oE '\-?[0-9]+$')
  if [ -f "$ALLOW" ] && grep -qE "^${base}:${num}([[:space:]]|#|$)" "$ALLOW"; then continue; fi
  out="${out}${v}\n"; fail=1
done <<< "$violations"

if [ "$fail" = "1" ]; then
  echo "✗ grid-lint: these UI sizes are off the 4pt scale and not registered in grid-lint-allow.txt (change to a multiple of 4, or register with a reason)::" >&2
  printf "%b" "$out" >&2
  exit 1
fi
echo "✓ grid-lint: UI sizes all on the 4pt scale (or registered exceptions)"
