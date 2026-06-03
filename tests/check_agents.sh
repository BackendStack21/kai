#!/usr/bin/env bash
# Validates the agent definition files in agents/ for consistency and security.
# Single source of truth for the ecosystem version is README.md (**Version:** X.Y.Z).
#
# Checks, per agent file:
#   1. Full dangerous-command deny list is present (10 entries).
#   2. A `webfetch:` permission is explicitly declared.
#   3. The footer version matches the ecosystem version.
#   4. Any version in the H1 title matches the ecosystem version.
#   5. A `## Limitations` section is present.
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$ROOT_DIR/agents"
README="$ROOT_DIR/README.md"

# Required deny-list entries (kept in sync with README §"Dangerous Command Deny List").
DENY_ENTRIES=(
  '"rm -rf /*": deny'
  '"sudo *": deny'
  '"eval *": deny'
  '"mkfs*": deny'
  '"dd if=*": deny'
  '"chmod -R 777 *": deny'
  '"curl * | sh": deny'
  '"curl * | bash": deny'
  '"wget * | sh": deny'
  '"wget * | bash": deny'
)

if [ ! -d "$AGENTS_DIR" ]; then
  echo "[FAIL] agents directory not found: $AGENTS_DIR"
  exit 1
fi

EXPECTED_VERSION="$(grep -m1 -E '^\*\*Version:\*\*' "$README" | sed -E 's/[^0-9.]//g')"
if [ -z "$EXPECTED_VERSION" ]; then
  echo "[FAIL] could not read ecosystem version from $README"
  exit 1
fi
echo "[INFO] Ecosystem version (from README): $EXPECTED_VERSION"

errors=0
fail() { echo "[FAIL] $1"; errors=$((errors + 1)); }

for f in "$AGENTS_DIR"/*.md; do
  name="$(basename "$f")"

  # 1. Dangerous-command deny list
  for entry in "${DENY_ENTRIES[@]}"; do
    if ! grep -qF -- "$entry" "$f"; then
      fail "$name: missing deny-list entry: $entry"
    fi
  done

  # 2. webfetch declared
  if ! grep -qE '^\s*webfetch:\s*(allow|deny)' "$f"; then
    fail "$name: no explicit 'webfetch:' permission declared"
  fi

  # 3. Footer version (two accepted formats: '**Version:** X.Y.Z' or 'vX.Y.Z | Mode:')
  footer_ver="$(grep -oE '^\*\*Version:\*\* [0-9]+\.[0-9]+\.[0-9]+' "$f" | head -1 | sed -E 's/[^0-9.]//g' || true)"
  if [ -z "$footer_ver" ]; then
    footer_ver="$(grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+ \| Mode:' "$f" | head -1 | sed -E 's/[^0-9.]//g' || true)"
  fi
  if [ -z "$footer_ver" ]; then
    fail "$name: no version footer found"
  elif [ "$footer_ver" != "$EXPECTED_VERSION" ]; then
    fail "$name: footer version $footer_ver != ecosystem $EXPECTED_VERSION"
  fi

  # 4. H1 title version (if present) must match
  header_ver="$(grep -m1 -oE '^# .*v[0-9]+\.[0-9]+(\.[0-9]+)?' "$f" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?$' | sed 's/^v//' || true)"
  if [ -n "$header_ver" ] && [ "$header_ver" != "$EXPECTED_VERSION" ]; then
    fail "$name: H1 title version $header_ver != ecosystem $EXPECTED_VERSION"
  fi

  # 5. Limitations section
  if ! grep -qE '^##.*[Ll]imitation' "$f"; then
    fail "$name: missing '## Limitations' section"
  fi
done

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "[FAIL] Agent definition checks failed: $errors issue(s)."
  exit 1
fi

echo "[PASS] All agent definitions are consistent ($(ls "$AGENTS_DIR"/*.md | wc -l | tr -d ' ') files)."
