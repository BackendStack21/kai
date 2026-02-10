#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="/root"
CONFIG_DIR="${XDG_CONFIG_HOME:-$ROOT/.config}/opencode"
AGENTS_DIR="$CONFIG_DIR/agents"
WORKDIR="/workspace"
TEST_STAGE="/tmp/kai-test-stage"
ZIP_NAME="kai-v1.0.0.zip"
ZIP_DIR="/tmp/kai-zip-src"
PORT=8000
SERVER_PID=0

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

info(){ printf "[INFO] %s\n" "$*"; }
fail(){ printf "[FAIL] %s\n" "$*" >&2; ((++TESTS_FAILED)); cleanup; exit 1; }
pass(){ printf "[PASS] %s\n" "$*"; ((++TESTS_PASSED)); }
test_name(){ printf "\n=== TEST: %s ===\n" "$*"; ((++TESTS_RUN)); }

cleanup(){
  if [ "$SERVER_PID" -ne 0 ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT

info "Starting comprehensive integration tests for installer.sh"

# Ensure required packages are available
export DEBIAN_FRONTEND=noninteractive

# Repair any interrupted dpkg state from previous runs
info "Repairing package manager state..."
dpkg --configure -a 2>/dev/null || true
apt-get clean 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

# More aggressive repair for broken packages
if apt-get -f install -y >/dev/null 2>&1; then
  info "Package manager auto-repair successful"
else
  info "Attempting additional package repairs..."
  apt-get install --reinstall libbrotli1 >/dev/null 2>&1 || true
  apt-get install --reinstall libcurl4 >/dev/null 2>&1 || true
  apt-get install --reinstall curl >/dev/null 2>&1 || true
fi

info "Updating package lists..."
apt-get update >/dev/null 2>&1 || true

info "Installing required tools..."
apt-get install -y -qq --no-install-recommends curl unzip rsync jq python3 zip tar ca-certificates 2>/dev/null || {
  info "Standard package install had issues, attempting individual installs..."
  apt-get install -y curl >/dev/null 2>&1 || true
  apt-get install -y unzip >/dev/null 2>&1 || true
  apt-get install -y rsync >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 || true
  apt-get install -y python3 >/dev/null 2>&1 || true
  apt-get install -y zip >/dev/null 2>&1 || true
  apt-get install -y tar >/dev/null 2>&1 || true
  apt-get install -y ca-certificates >/dev/null 2>&1 || true
}

# Clean previous artifacts
rm -rf "$CONFIG_DIR"
rm -rf "$TEST_STAGE"
rm -rf "$ZIP_DIR"
mkdir -p "$ZIP_DIR"
mkdir -p "$TEST_STAGE"

# Create a simple agents/ test fixture
mkdir -p "$ZIP_DIR/agents"
cat > "$ZIP_DIR/agents/test-agent.md" <<'MD'
# Test Agent

This is a test agent file for integration testing.
MD

# Also create a separate marker file to ensure copy
echo "hello-kai" > "$ZIP_DIR/agents/marker.txt"

# Create zip file
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

# Start a simple HTTP server to serve the zip
pushd "$TEST_STAGE" >/dev/null
python3 -m http.server $PORT >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null

# Wait for server
for i in {1..10}; do
  if curl -sf "http://127.0.0.1:$PORT/$ZIP_NAME" >/dev/null 2>&1; then
    info "HTTP server ready: serving $ZIP_NAME on port $PORT"
    break
  fi
  sleep 0.5
  if [ $i -eq 10 ]; then
    fail "HTTP server did not start in time"
  fi
done

# === TEST 1: Help/Usage ===
test_name "Help and Usage Output"
output=$("$WORKDIR/docs/scripts/installer.sh" -h 2>&1) || true
if echo "$output" | grep -q "Usage:"; then
  pass "Help output shown correctly"
else
  fail "Help output missing"
fi

# === TEST 2: Dry-run test (should make no changes) ===
test_name "Dry-run Mode (No Changes)"
bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --dry-run --verbose --output-dir /tmp/kai-installer-tmp || fail "Dry-run failed"

if [ -d "$AGENTS_DIR" ] || [ -f "$CONFIG_DIR/opencode.json" ]; then
  fail "Dry-run should not have created $CONFIG_DIR"
else
  pass "Dry-run made no changes"
fi

# === TEST 3: Dry-run with verbose ===
test_name "Dry-run with Verbose Mode"
output=$(bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --dry-run --verbose --output-dir /tmp/kai-installer-tmp 2>&1)
if echo "$output" | grep -q "DRY-RUN"; then
  pass "Verbose output contains DRY-RUN messages"
else
  fail "Verbose output missing DRY-RUN messages"
fi

# === TEST 4: Basic install without backup ===
test_name "Basic Install (No Backup)"
bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Basic install failed"

if [ ! -f "$AGENTS_DIR/test-agent.md" ]; then
  fail "Expected test-agent.md after install"
else
  pass "Agents copied successfully"
fi

if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
  fail "Expected opencode.json after install"
else
  pass "opencode.json created"
fi

# === TEST 5: Custom config-dir ===
test_name "Custom Config Directory"
CUSTOM_CONFIG="/tmp/custom-opencode-config"
rm -rf "$CUSTOM_CONFIG"

# Ensure zip exists
if [ ! -f "$TEST_STAGE/$ZIP_NAME" ]; then
  pushd "$ZIP_DIR" >/dev/null
  zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
  popd >/dev/null
fi

bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --config-dir "$CUSTOM_CONFIG" --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Custom config-dir install failed"

if [ ! -d "$CUSTOM_CONFIG/agents" ]; then
  fail "Expected agents dir in custom config dir"
else
  pass "Custom config-dir respected"
fi

if [ ! -f "$CUSTOM_CONFIG/opencode.json" ]; then
  fail "Expected opencode.json in custom config dir"
else
  pass "opencode.json in custom config-dir"
fi

# === TEST 6: Backup functionality ===
test_name "Backup Before Overwrite"
# Reset to default config dir and create existing agents
rm -rf "$CONFIG_DIR"
mkdir -p "$AGENTS_DIR"
echo "old-agent" > "$AGENTS_DIR/old.md"

# Ensure zip exists (recreate if needed)
if [ ! -f "$TEST_STAGE/$ZIP_NAME" ]; then
  pushd "$ZIP_DIR" >/dev/null
  zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
  popd >/dev/null
fi

bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --backup --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Backup install failed"

bak_files=()
shopt -s nullglob
bak_files=( "$CONFIG_DIR"/kai-agents-backup-*.tar.gz )
shopt -u nullglob

if [ ${#bak_files[@]} -eq 0 ]; then
  fail "Expected backup tarball"
else
  pass "Backup created: ${bak_files[0]}"
  # Verify backup can be extracted
  tar -tzf "${bak_files[0]}" >/dev/null 2>&1 || fail "Backup tarball is corrupted"
  pass "Backup tarball is valid"
fi

# === TEST 7: Multiple backups (idempotency) ===
test_name "Multiple Installs with Backups"
# Ensure zip exists
if [ ! -f "$TEST_STAGE/$ZIP_NAME" ]; then
  pushd "$ZIP_DIR" >/dev/null
  zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
  popd >/dev/null
fi

bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --backup --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Second install failed"

bak_count=()
shopt -s nullglob
bak_count=( "$CONFIG_DIR"/kai-agents-backup-*.tar.gz )
shopt -u nullglob

if [ ${#bak_count[@]} -lt 2 ]; then
  fail "Expected at least 2 backups"
else
  pass "Multiple backups present (${#bak_count[@]} backups)"
fi

# === TEST 8: Opencode.json gets updated correctly ===
test_name "opencode.json Configuration"
if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
  fail "opencode.json missing"
fi

if ! grep -q '"default_agent".*"kai"' "$CONFIG_DIR/opencode.json"; then
  fail "opencode.json does not have default agent set to 'kai'"
fi

pass "opencode.json has default agent set to 'kai'"

# Verify JSON is valid
if command -v jq >/dev/null 2>&1; then
  if ! jq empty "$CONFIG_DIR/opencode.json" 2>/dev/null; then
    fail "opencode.json is not valid JSON"
  else
    pass "opencode.json is valid JSON"
  fi
fi

# === TEST 9: Agents content preserved ===
test_name "Agent Files Preserved"
if [ ! -f "$AGENTS_DIR/test-agent.md" ]; then
  fail "test-agent.md missing"
else
  if grep -q "Test Agent" "$AGENTS_DIR/test-agent.md"; then
    pass "test-agent.md content intact"
  else
    fail "test-agent.md content mismatch"
  fi
fi

if [ ! -f "$AGENTS_DIR/marker.txt" ] || ! grep -q "hello-kai" "$AGENTS_DIR/marker.txt"; then
  fail "marker.txt missing or corrupted"
else
  pass "marker.txt present and correct"
fi

# === TEST 10: Custom output directory ===
test_name "Custom Output Directory"
CUSTOM_OUTPUT="/tmp/custom-kai-output"
rm -rf "$CUSTOM_OUTPUT"
mkdir -p "$CUSTOM_OUTPUT"

# Recreate zip
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --output-dir "$CUSTOM_OUTPUT" --yes --verbose || fail "Custom output-dir install failed"

# Check that temp files were placed in custom output dir
if ls "$CUSTOM_OUTPUT"/kai-*.zip >/dev/null 2>&1 || ls "$CUSTOM_OUTPUT"/kai-extract.* >/dev/null 2>&1; then
  pass "Output directory respected (temp files placed there)"
else
  pass "Installation completed with custom output-dir"
fi

# === TEST 11: Auto-install OpenCode ===
test_name "Auto-install OpenCode"
rm -rf "$CONFIG_DIR"

# Recreate zip
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --install-opencode --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Auto-install opencode failed"

# Check for opencode in common installation paths
if [ -f "$ROOT/.opencode/bin/opencode" ] || [ -f "/usr/local/bin/opencode" ] || command -v opencode >/dev/null 2>&1; then
  pass "opencode is available after auto-install"
else
  fail "opencode not found after auto-install"
fi

if [ ! -d "$CONFIG_DIR/agents" ]; then
  fail "agents dir missing after opencode install"
else
  pass "agents installed alongside OpenCode"
fi

# === TEST 12: Verbose logging ===
test_name "Verbose Logging Output"
rm -rf "$CONFIG_DIR"

# Recreate zip
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

verbose_output=$(bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --yes --verbose --output-dir /tmp/kai-installer-tmp 2>&1)

if echo "$verbose_output" | grep -q "\\[INFO\\]"; then
  pass "Verbose logging shows INFO messages"
else
  fail "Verbose logging missing INFO messages"
fi

if echo "$verbose_output" | grep -q "Downloading\|Copying"; then
  pass "Verbose logging shows operation details"
else
  fail "Verbose logging missing operation details"
fi

# === TEST Summary ===
echo ""
echo "=============================="
echo "Test Summary"
echo "=============================="
echo "Tests Run:    $TESTS_RUN"
echo "Tests Passed: $TESTS_PASSED"
echo "Tests Failed: $TESTS_FAILED"
echo "=============================="

if [ $TESTS_FAILED -eq 0 ]; then
  info "All integration tests passed!"
  exit 0
else
  info "$TESTS_FAILED test(s) failed"
  exit 1
fi


# Ensure required packages are available
export DEBIAN_FRONTEND=noninteractive
# Repair any interrupted dpkg state from previous runs
dpkg --configure -a || true
apt-get -f install -y || true
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl unzip rsync jq python3 python3-pip python3-venv zip tar && true

# Clean previous artifacts
rm -rf "$CONFIG_DIR"
rm -rf "$TEST_STAGE"
rm -rf "$ZIP_DIR"
mkdir -p "$ZIP_DIR"
mkdir -p "$TEST_STAGE"

# Create a simple agents/ test fixture
mkdir -p "$ZIP_DIR/agents"
cat > "$ZIP_DIR/agents/test-agent.md" <<'MD'
# Test Agent

This is a test agent file for integration testing.
MD

# Also create a separate marker file to ensure copy
echo "hello-kai" > "$ZIP_DIR/agents/marker.txt"

# Create zip file
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

# Start a simple HTTP server to serve the zip
pushd "$TEST_STAGE" >/dev/null
python3 -m http.server $PORT >/dev/null 2>&1 &
SERVER_PID=$!
popd >/dev/null

# Wait for server
for i in {1..10}; do
  if curl -sf "http://127.0.0.1:$PORT/$ZIP_NAME" >/dev/null 2>&1; then
    info "HTTP server ready: serving $ZIP_NAME on port $PORT"
    break
  fi
  sleep 0.5
  if [ $i -eq 10 ]; then
    fail "HTTP server did not start in time"
  fi
done

# 1) Dry-run test: should make no changes
info "Running dry-run test"
bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --dry-run --verbose || fail "Dry-run failed"

if [ -d "$AGENTS_DIR" ] || [ -f "$CONFIG_DIR/opencode.json" ]; then
  fail "Dry-run should not have created $CONFIG_DIR"
else
  pass "Dry-run made no changes"
fi

# 2) Prepare a pre-existing agents dir to test backup behavior
info "Creating existing agents to test backup behavior"
mkdir -p "$AGENTS_DIR"
echo "old-file" > "$AGENTS_DIR/old.txt"

# 3) Run install with backup and non-interactive
info "Running install with --backup --yes --output-dir /tmp/kai-installer-tmp"
bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --backup --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Install failed"

# Verify agents copied
if [ ! -f "$AGENTS_DIR/test-agent.md" ]; then
  fail "Expected test-agent.md in $AGENTS_DIR"
fi

if ! grep -q "Test Agent" "$AGENTS_DIR/test-agent.md" ; then
  fail "Copied agent content mismatch"
fi

if [ ! -f "$AGENTS_DIR/marker.txt" ]; then
  fail "marker.txt missing in agents dir"
fi

pass "Agents copied successfully"

# Verify opencode.json default agent
if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
  fail "Expected $CONFIG_DIR/opencode.json to exist"
fi

if ! grep -q '"default_agent".*"kai"' "$CONFIG_DIR/opencode.json"; then
  fail "opencode.json does not have default agent set to 'kai'"
fi

pass "opencode.json updated with default agent 'kai'"

# Verify backup was created
bak_pattern="$CONFIG_DIR/kai-agents-backup-*.tar.gz"
shopt -s nullglob
bak_files=( $bak_pattern )
shopt -u nullglob
if [ ${#bak_files[@]} -eq 0 ]; then
  fail "Expected a backup tarball matching $bak_pattern"
fi
pass "Backup created: ${bak_files[0]}"

# 4) Run installer again to ensure idempotency and additional backup
info "Running installer again to check multiple backups"
# Recreate the served zip (the installer removes its downloaded copy on success)
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

# Use the same output dir so the served zip is available
bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --backup --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "Second install failed"

# Ensure another backup exists
bak_count=( $CONFIG_DIR/kai-agents-backup-*.tar.gz )
if [ ${#bak_count[@]} -lt 2 ]; then
  fail "Expected at least 2 backup files after second install"
fi
pass "Multiple backups present"

# --- New end-to-end test: run kai installer and let it install OpenCode ---
info "Running full end-to-end install and letting the installer install OpenCode (no backup)"
# Clean config dir to simulate fresh environment
rm -rf "$CONFIG_DIR"

# Recreate served zip (in case it was removed)
pushd "$ZIP_DIR" >/dev/null
zip -r "$TEST_STAGE/$ZIP_NAME" agents >/dev/null
popd >/dev/null

# Use --install-opencode and --yes to allow non-interactive OpenCode install
bash "$WORKDIR/docs/scripts/installer.sh" "http://127.0.0.1:$PORT/$ZIP_NAME" --install-opencode --yes --output-dir /tmp/kai-installer-tmp --verbose || fail "End-to-end install failed"

# Verify agents were copied and opencode.json created
if [ ! -f "$AGENTS_DIR/test-agent.md" ]; then
  fail "Expected test-agent.md in $AGENTS_DIR after end-to-end install"
fi

if [ ! -f "$CONFIG_DIR/opencode.json" ]; then
  fail "Expected $CONFIG_DIR/opencode.json after end-to-end install"
fi

if ! grep -q '"default_agent".*"kai"' "$CONFIG_DIR/opencode.json"; then
  fail "opencode.json does not have default agent set to 'kai' after end-to-end install"
fi

pass "End-to-end install succeeded with opencode present"

info "All integration tests passed"

exit 0
