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

# Find non-executable .sh files (portable across Bash versions)
bad_files_found=false
bad_files_list=""
while IFS= read -r -d '' f; do
  if [ ! -x "$f" ]; then
    bad_files_found=true
    bad_files_list+="$f"$'\n'
  fi
done < <(find "$CHECK_DIR" -type f -name '*.sh' -print0)

if [ "$bad_files_found" = false ]; then
  echo "[PASS] All .sh files under $CHECK_DIR are executable"
  exit 0
fi

echo "[FAIL] The following .sh files are not executable:"
printf '%s' "$bad_files_list"

exit 1
