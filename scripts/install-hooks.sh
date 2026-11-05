#!/usr/bin/env bash
# Points this clone and all its worktrees at the tracked hooks in scripts/hooks. Run once per clone.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath scripts/hooks
echo "✓ Hooks installed: pre-commit (pod-lint, grid-lint, tests), pre-push (sanitize-check)"
