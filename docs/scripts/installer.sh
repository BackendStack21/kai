#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

REPO="BackendStack21/kai"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
AGENTS_DIR="$CONFIG_DIR/agents"
TMPDIR="${TMPDIR:-/tmp}"

DRY_RUN=false
VERBOSE=false
AUTO_YES=false
INSTALL_OPENCODE=false
OUTPUT_DIR=""
BACKUP=false
OPENCODE_JSON="$CONFIG_DIR/opencode.json"
DOWNLOAD_PATH=""
EXTRACT_DIR=""
INSTALLER_PATH=""

# Cleanup handler for temp files on exit or error
cleanup() {
  local exit_code=$?
  [ -z "$INSTALLER_PATH" ] || rm -f "$INSTALLER_PATH" 2>/dev/null || true
  [ -z "$DOWNLOAD_PATH" ] || rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
  [ -z "$EXTRACT_DIR" ] || rm -rf "$EXTRACT_DIR" 2>/dev/null || true
  return $exit_code
}
trap cleanup EXIT
INSTALLER_PATH=""

# Cleanup handler for temp files
cleanup() {
  local exit_code=$?
  [ -z "$INSTALLER_PATH" ] || rm -f "$INSTALLER_PATH" 2>/dev/null || true
  [ -z "$DOWNLOAD_PATH" ] || rm -f "$DOWNLOAD_PATH" 2>/dev/null || true
  [ -z "$EXTRACT_DIR" ] || rm -rf "$EXTRACT_DIR" 2>/dev/null || true
  return $exit_code
}
trap cleanup EXIT

# Logging helpers
log() {
  if [ "$VERBOSE" = true ]; then
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  fi
}
info() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
die() { printf "[ERROR] %s\n" "$*" >&2; exit 1; }

print_usage(){

  cat <<USAGE
Usage: $(basename "$0") <version-or-url> [--repo owner/repo] [--config-dir DIR] [--dry-run] [--backup] [--output-dir DIR] [--yes|--force] [-v|--verbose]

Examples:
  $(basename "$0") v1.2.3
  $(basename "$0") 1.2.3
  $(basename "$0") https://github.com/BackendStack21/kai/releases/download/v1.2.3/kai-v1.2.3.zip
  $(basename "$0") latest --repo BackendStack21/kai

This script will:
  - download a release zip (e.g. kai-VERSION.zip) to $TMPDIR (or --output-dir)
  - extract and copy the included agents/ folder to $CONFIG_DIR/agents (overwriting existing files)
  - set "kai" as the default agent in $CONFIG_DIR/opencode.json

Flags:
  --dry-run        Perform a trial run; no changes will be made.
  --backup         Create a timestamped backup of existing agents and opencode.json before overwriting.
  --output-dir DIR Place temporary download and extraction files in DIR instead of system temp.
  --install-opencode  Download and run the OpenCode installer if OpenCode is missing.
  --yes, --force, -y  Suppress interactive prompts (answer yes to confirmations).
  -v, --verbose    Enable verbose logging (timestamps and extra details).

USAGE
}

if [[ ${#@} -lt 1 ]]; then
  print_usage
  exit 1
fi

# parse args
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_usage; exit 0 ;;
    --repo) REPO="$2"; shift 2 ;;
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --backup) BACKUP=true; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --install-opencode) INSTALL_OPENCODE=true; shift ;;
    --yes|--force|-y) AUTO_YES=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"; shift; else echo "Unknown arg: $1"; print_usage; exit 1; fi
      ;;
  esac
done

# Validate that target was provided
if [[ -z "$TARGET" ]]; then
  echo "Error: version or URL is required"
  print_usage
  exit 1
fi

# Recompute derived paths after arg parsing
AGENTS_DIR="$CONFIG_DIR/agents"
OPENCODE_JSON="$CONFIG_DIR/opencode.json"
OUTPUT_DIR="${OUTPUT_DIR:-$TMPDIR}"

# Validate that target was provided
if [[ -z "$TARGET" ]]; then
  echo "Error: version or URL is required" >&2
  print_usage
  exit 1
fi

# Requirements
if [ "$DRY_RUN" = true ]; then
  info "DRY-RUN: Skipping external tool checks (curl/unzip will not be required)"
else
  command -v curl >/dev/null 2>&1 || { die "curl is required. Install it and retry."; }
  command -v unzip >/dev/null 2>&1 || { die "unzip is required. Install it and retry."; }
fi

# Check OpenCode
if [ "$DRY_RUN" = true ]; then
  info "DRY-RUN: Skipping OpenCode detection and interactive prompts"
  opencode_present=true
else
  opencode_present=false
  if command -v opencode >/dev/null 2>&1; then
    opencode_present=true
  fi
  if [[ -d "$CONFIG_DIR" ]]; then
    opencode_present=true
  fi

  if ! $opencode_present; then
    warn "OpenCode does not appear to be installed or configured at $CONFIG_DIR."

    # Helper to install OpenCode
    install_opencode_now() {
      info "Installing OpenCode via official installer: https://opencode.ai/install"
      INSTALLER_PATH="$(mktemp "$OUTPUT_DIR/opencode-install.XXXX.sh")"
      curl -fsSL "https://opencode.ai/install" -o "$INSTALLER_PATH" || die "Failed to download OpenCode installer"
      chmod +x "$INSTALLER_PATH"
      bash "$INSTALLER_PATH" || die "OpenCode installer failed"
      
      # Refresh shell state and search for opencode binary
      hash -r 2>/dev/null || true
      if [ -f "$HOME/.bashrc" ]; then ( set +u; . "$HOME/.bashrc" ) 2>/dev/null || true; fi
      if [ -f "$HOME/.profile" ]; then ( set +u; . "$HOME/.profile" ) 2>/dev/null || true; fi
      
      # If not on PATH, try common locations
      if ! command -v opencode >/dev/null 2>&1; then
        local found_bin=""
        local candidates=("$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" "/usr/local/bin/opencode" "/usr/bin/opencode")
        for c in "${candidates[@]}"; do
          if [ -x "$c" ]; then found_bin="$c"; break; fi
        done
        if [ -z "$found_bin" ]; then
          found_bin="$(find "$HOME" -maxdepth 4 -type f -name opencode -perm /111 -print -quit 2>/dev/null || true)"
        fi
        if [ -n "$found_bin" ]; then
          export PATH="$(dirname "$found_bin"):$PATH"
          info "Added $(dirname "$found_bin") to PATH"
        fi
      fi
      
      if ! command -v opencode >/dev/null 2>&1; then
        die "OpenCode installation completed but 'opencode' is not available in PATH"
      fi
      info "OpenCode installed: $(opencode --version 2>/dev/null || echo 'installed')"
    }

    # Decide whether to install automatically
    if [ "$DRY_RUN" = true ]; then
      info "DRY-RUN: Would offer to install OpenCode (skipped in dry-run)"
      opencode_present=true
    elif [ "$AUTO_YES" = true ] || [ "$INSTALL_OPENCODE" = true ]; then
      info "Auto-installing OpenCode"
      install_opencode_now
      opencode_present=true
    else
      read -r -p "OpenCode is required but not installed. Install now? [y/N] " yn
      if [[ "$yn" =~ ^[Yy]$ ]]; then
        install_opencode_now
        opencode_present=true
      else
        die "OpenCode is required. Aborting."
      fi
    fi
  fi
fi

# Determine download URL / filename
is_url=false
if [[ "$TARGET" =~ ^https?:// ]]; then
  is_url=true
  URL="$TARGET"
  FILENAME="$(basename "$URL")"
else
  # normalize version (strip leading v)
  VERSION="$TARGET"
  VERSION="${VERSION#v}"
  
  # Special handling for "latest" - query GitHub API for latest release
  if [[ "$VERSION" == "latest" ]]; then
    info "Querying GitHub API for latest release..."
    LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/"tag_name": *"\(.*\)"/\1/' || echo "")
    if [[ -z "$LATEST_TAG" ]]; then
      die "Failed to determine latest release version from GitHub API"
    fi
    info "Latest release: $LATEST_TAG"
    VERSION="${LATEST_TAG#v}"
    VERSION_WITH_V="v${VERSION}"
    URLS=(
      "https://github.com/${REPO}/releases/download/${LATEST_TAG}/kai-${LATEST_TAG}.zip"
      "https://github.com/${REPO}/releases/latest/download/kai-${LATEST_TAG}.zip"
    )
  else
    VERSION_WITH_V="v${VERSION}"
    # Candidate URLs to try (in order)
    URLS=(
      "https://github.com/${REPO}/releases/download/${VERSION_WITH_V}/kai-${VERSION_WITH_V}.zip"
      "https://github.com/${REPO}/releases/download/${TARGET}/kai-${TARGET}.zip"
      "https://github.com/${REPO}/releases/download/${VERSION}/kai-${VERSION}.zip"
    )
  fi
fi

# Download to temp (respecting --output-dir)
mkdir -p "$OUTPUT_DIR"
DOWNLOAD_PATH=""

if [ "$DRY_RUN" = true ]; then
  if $is_url; then
    info "DRY-RUN: Would download $URL -> $OUTPUT_DIR/$FILENAME"
  else
    if [[ "${VERSION}" == "latest" ]]; then
      info "DRY-RUN: Would query GitHub API for latest release from $REPO"
      info "DRY-RUN: Would download latest kai release zip"
    else
      info "DRY-RUN: Would attempt to download kai-$VERSION.zip from $REPO releases (trying multiple URL patterns):"
      for u in "${URLS[@]}"; do info "  $u"; done
    fi
  fi
  info "DRY-RUN: Would extract the archive and copy 'agents/' to $AGENTS_DIR (overwriting existing files)"
  if [ "$BACKUP" = true ]; then
    info "DRY-RUN: Would create a backup of existing agents/opencode.json in $CONFIG_DIR"
  fi
  info "DRY-RUN: Would create/update $OPENCODE_JSON and set default agent to 'kai'"
  exit 0
fi

if $is_url; then
  DOWNLOAD_PATH="$OUTPUT_DIR/$FILENAME"
  info "Downloading $URL -> $DOWNLOAD_PATH"
  curl -fL -o "$DOWNLOAD_PATH" "$URL" || { die "Download failed: $URL"; }
else
  info "Attempting to download kai-$VERSION.zip from $REPO releases (trying multiple URL patterns)..."
  success=false
  for u in "${URLS[@]}"; do
    info "  trying: $u"
    FNAME="$(basename "$u")"
    TMPFILE="$OUTPUT_DIR/$FNAME"
    if curl -fL -o "$TMPFILE" "$u"; then
      DOWNLOAD_PATH="$TMPFILE"
      info "Downloaded: $DOWNLOAD_PATH"
      success=true
      break
    else
      rm -f "$TMPFILE" 2>/dev/null || true
    fi
  done
  if ! $success; then
    die "Failed to download release. Please check the version or provide a direct URL." 
  fi
fi

# Verify zip
if ! unzip -t "$DOWNLOAD_PATH" >/dev/null 2>&1; then
  die "Downloaded file is not a valid zip archive: $DOWNLOAD_PATH"
fi

# Extract
EXTRACT_DIR="$(mktemp -d "$OUTPUT_DIR/kai-extract.XXXX")"
unzip -q "$DOWNLOAD_PATH" -d "$EXTRACT_DIR"

# Find agents/ folder inside extracted archive
AGENTS_SRC="$(find "$EXTRACT_DIR" -type d -name agents -print -quit || true)"
if [[ -z "$AGENTS_SRC" || ! -d "$AGENTS_SRC" ]]; then
  echo "Could not find an 'agents' directory inside the downloaded release. Inspecting contents:";
  find "$EXTRACT_DIR" -maxdepth 3 -type d -print
  echo "Aborting."; rm -rf "$EXTRACT_DIR"; exit 7
fi

# Backup existing agents/opencode.json if requested
if [ "$BACKUP" = true ] && [ -d "$AGENTS_DIR" ]; then
  timestamp="$(date -u +%Y%m%dT%H%M%S)$(printf '%06d' $((RANDOM * 10)))Z"
  BACKUP_FILE="$CONFIG_DIR/kai-agents-backup-$timestamp.tar.gz"
  if [ "$DRY_RUN" = true ]; then
    info "DRY-RUN: Would create backup of existing agents -> $BACKUP_FILE"
  else
    info "Creating backup of existing agents -> $BACKUP_FILE"
    tar -C "$CONFIG_DIR" -czf "$BACKUP_FILE" agents || warn "Backup tar failed; continuing"
  fi
fi

# Optionally backup opencode.json as well
if [ "$BACKUP" = true ] && [ -f "$OPENCODE_JSON" ]; then
  json_bak="$CONFIG_DIR/opencode.json.bak.$(date -u +%Y%m%dT%H%M%S)$(printf '%06d' $((RANDOM * 10)))Z"
  if [ "$DRY_RUN" = true ]; then
    info "DRY-RUN: Would copy $OPENCODE_JSON -> $json_bak"
  else
    cp "$OPENCODE_JSON" "$json_bak" || warn "Failed to backup $OPENCODE_JSON"
    info "Backed up $OPENCODE_JSON -> $json_bak"
  fi
fi

# Confirm overwrite unless --yes was provided
if [ -d "$AGENTS_DIR" ] && [ "$AUTO_YES" = false ]; then
  read -r -p "This will overwrite existing files in $AGENTS_DIR. Proceed? [y/N] " yn
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    die "Aborted by user."
  fi
fi

info "Copying agents from $AGENTS_SRC -> $AGENTS_DIR (existing files will be overwritten)"
mkdir -p "$AGENTS_DIR"
# Use rsync if available for a safer copy, fallback to cp -a
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "$AGENTS_SRC/" "$AGENTS_DIR/"
else
  cp -a "$AGENTS_SRC/." "$AGENTS_DIR/"
fi

# Update opencode.json to set default agent to "kai"
mkdir -p "$CONFIG_DIR"
if [[ -f "$OPENCODE_JSON" ]]; then
  info "Updating existing $OPENCODE_JSON to set default agent to 'kai'"
  if [ "$DRY_RUN" = true ]; then
    info "DRY-RUN: Would update $OPENCODE_JSON to set default agent to 'kai'"
  else
    if command -v jq >/dev/null 2>&1; then
      tmpf="$(mktemp)"
      jq '.default_agent = "kai"' "$OPENCODE_JSON" > "$tmpf" && mv "$tmpf" "$OPENCODE_JSON"
    else
      python3 - <<PY
import json,sys
path = "$OPENCODE_JSON"
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
data['default_agent'] = 'kai'
with open(path+'.tmp','w') as f:
    json.dump(data,f,indent=2)
import os
os.replace(path+'.tmp', path)
print('Wrote', path)
PY
    fi
  fi
else
  if [ "$DRY_RUN" = true ]; then
    info "DRY-RUN: Would create $OPENCODE_JSON with default agent 'kai'"
  else
    info "Creating $OPENCODE_JSON with default agent 'kai'"
    cat > "$OPENCODE_JSON" <<JSON
{
  "default_agent": "kai"
}
JSON
  fi
fi

# Done
echo "✅ Kai agents installed to: $AGENTS_DIR"
echo "✅ Default agent set to 'kai' in: $OPENCODE_JSON"

exit 0
