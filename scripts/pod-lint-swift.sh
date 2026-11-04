#!/usr/bin/env bash
# NSpace project-local enforcement: the Swift-stack instance of the pod four axioms (replaces META's Go reference pod-lint.sh).
# Also machine-checks BG-1, no writes to authoritative state from the presentation layer. Runs on pre-commit; violations exit 1.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PODS="$ROOT/Sources/Pods"
APP="$ROOT/Sources/NSpaceApp"
rc=0

# ---- Pod four axioms (Swift adaptation, deviations registered in META_COMPLIANCE.json) ----
if [ -d "$PODS" ]; then
  for pod in "$PODS"/*/; do
    [ -d "$pod" ] || continue
    name="$(basename "$pod")"

    # Axiom 3: single external contract surface
    [ -f "$pod/Contract.swift" ] || { echo "✗ [$name] missing Contract.swift (Axiom 3: expose only a unified contract)"; rc=1; }

    # Axiom 4: self-contained physical proof (SwiftPM forces a separate Tests/ directory; equivalent enforcement: a same-named non-empty test directory)
    tests="$ROOT/Tests/${name}Tests"
    if [ ! -d "$tests" ] || [ -z "$(find "$tests" -name '*.swift' -print -quit 2>/dev/null)" ]; then
      echo "✗ [$name] missing non-empty Tests/${name}Tests/ (Axiom 4: independent self-contained physical proof)"; rc=1
    fi

    # Axiom 2: zero global mutable state (UserDefaults.standard / home-made global singletons; FileManager is the controlled plant, not banned)
    hits="$(grep -rnE 'UserDefaults\.standard|static (var|let) shared' "$pod" 2>/dev/null | grep -vE ':[0-9]+:\s*//')"
    if [ -n "$hits" ]; then
      echo "✗ [$name] global singleton/UserDefaults.standard (Axiom 2: constructor injection):"; echo "$hits" | sed 's/^/      /'; rc=1
    fi

    # BG-11: zero intrusion: pods must never import other pods (shared dependencies only compose through the Kernel contract layer)
    others="$(ls "$PODS" | grep -v "^$name\$" | paste -sd'|' -)"
    if [ -n "$others" ]; then
      xhits="$(grep -rnE "^\s*import ($others)\b" "$pod" 2>/dev/null)"
      if [ -n "$xhits" ]; then
        echo "✗ [$name] cross-pod import (BG-11: zero intrusion):"; echo "$xhits" | sed 's/^/      /'; rc=1
      fi
    fi
  done
fi

# ---- BG-1: presentation layer must not write authoritative state (no write-type FileManager APIs or direct JSON saves in NSpaceApp) ----
if [ -d "$APP" ]; then
  # UISelfTest.swift is exempt: the UI self-test channel (gated by the NSPACE_UITEST env var, not a product path) needs to
  # create/delete temp fixture files; it is a test harness, like Tests/, and is not the presentation layer writing authoritative state
  whits="$(grep -rnE 'FileManager\.[a-zA-Z]*\.(copyItem|moveItem|removeItem|trashItem|createDirectory|createFile)|copyfile\(' "$APP" 2>/dev/null | grep -v 'UISelfTest.swift' | grep -vE ':[0-9]+:\s*//')"
  if [ -n "$whits" ]; then
    echo "✗ [NSpaceApp] presentation layer calls a write-type file API directly (BG-1, must go through an OperationSpec Command):"
    echo "$whits" | sed 's/^/      /'; rc=1
  fi
fi

# ---- Pinpoint invariants (SearchEngine, surfaced by a real red in v0.19.17) ----
# Pure-function unit tests can prove "the formula is right", not "the call site really uses it": remove the formula from drainSpotlight and
# SearchEngineTests still goes 11/11 green (adversarial review measured 3/3). These greps fill that hole.
# Note comment lines must be stripped before grepping: the first version did not, and with the autoreleasepool in the code deleted
# the comment above it, "one autoreleasepool per directory", still matched, so the gate might as well not exist.
codeonly() { grep -vE '^\s*(//|///|\*)' "$1" 2>/dev/null; }
SESS="$ROOT/Sources/Pods/SearchEngine/InternalSession.swift"
WALK="$ROOT/Sources/Pods/SearchEngine/LevelOrderWalk.swift"
if [ -f "$SESS" ] && [ -f "$WALK" ]; then
  if ! codeonly "$SESS" | grep -q 'SearchLimits\.spotlightReadBudget(kept:'; then
    echo "✗ [SearchEngine] read budget not computed through SearchLimits.spotlightReadBudget"
    echo "      (channel A eats maxResults in one go → append() teardown → channel B silently starves)"
    rc=1
  fi
  if codeonly "$SESS" | grep -qE 'readBudget = max\(0, SearchLimits\.maxResults'; then
    echo "✗ [SearchEngine] bypasses the channel B reservation, computing the read budget directly from maxResults"
    rc=1
  fi
  if ! codeonly "$SESS" | grep -q 'LevelOrderWalk\.walk(root:'; then
    echo "✗ [SearchEngine] scan() does not use LevelOrderWalk (back to DFS: shallow hits found 15s late)"
    rc=1
  fi
  if ! codeonly "$WALK" | grep -q 'autoreleasepool {'; then
    echo "✗ [SearchEngine] LevelOrderWalk lacks autoreleasepool (peak RSS 51MB → 1219MB, measured on a real machine)"
    rc=1
  fi
fi

[ $rc -eq 0 ] && echo "pod-lint-swift: all pods and presentation layer passed ✓"
exit $rc
