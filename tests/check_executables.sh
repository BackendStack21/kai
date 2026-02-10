#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(dirname "${BASH_SOURCE[0]}")/.."
CHECK_DIR="$ROOT_DIR/docs/scripts"

echo "[INFO] Checking executable permissions for .sh files under $CHECK_DIR"

if [ ! -d "$CHECK_DIR" ]; then
  echo "[WARN] $CHECK_DIR does not exist; skipping executable checks"
  exit 0
fi

# Find non-executable .sh files
mapfile -t bad < <(find "$CHECK_DIR" -type f -name '*.sh' ! -perm /111 -print)

if [ ${#bad[@]} -eq 0 ]; then
  echo "[PASS] All .sh files under $CHECK_DIR are executable"
  exit 0
fi

echo "[FAIL] The following .sh files are not executable:"
for f in "${bad[@]}"; do
  echo "  - $f"
done

exit 1
