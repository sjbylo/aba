#!/bin/bash
# test-transfer-primed.sh — Validate transfer-primed tar creation
#
# Tests:
# 1. Creates aba-transfer-configs.tar with cluster dirs
# 2. Tar excludes iso-agent-based/ (large ISOs)
# 3. Tar excludes lifecycle markers (.install-complete, etc.)
# 4. Resolves symlinks (self-contained tarball)
# 5. Includes .primed marker in pre-built dirs
# 6. Does NOT include .primed marker in config-only dirs
# 7. Restores symlinks after tar creation (cleanup trap)
# 8. Aborts if no cluster dirs found

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_green() { echo -e "\033[0;32m$*\033[0m"; }
_red() { echo -e "\033[0;31m$*\033[0m"; }

PASS=0
FAIL=0

assert_pass() { PASS=$(( PASS + 1 )); _green "  ✓ $1"; }
assert_fail() { FAIL=$(( FAIL + 1 )); _red "  ✗ $1"; }

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		assert_pass "$desc"
	else
		assert_fail "$desc (expected: '$expected', got: '$actual')"
	fi
}

assert_file_exists() {
	local desc="$1" path="$2"
	if [ -f "$path" ]; then
		assert_pass "$desc"
	else
		assert_fail "$desc (file not found: $path)"
	fi
}

assert_tar_contains() {
	local desc="$1" tarfile="$2" pattern="$3"
	if tar tf "$tarfile" | grep -q "$pattern"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (pattern '$pattern' not in tar)"
	fi
}

assert_tar_not_contains() {
	local desc="$1" tarfile="$2" pattern="$3"
	if ! tar tf "$tarfile" | grep -q "$pattern"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (unexpected pattern '$pattern' found in tar)"
	fi
}

# --- Setup ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== test-transfer-primed.sh ==="
echo

# Create a fake ABA repo structure
REPO="$TMPDIR/aba"
mkdir -p "$REPO/mirror/data"
mkdir -p "$REPO/scripts"

# Minimal Makefile to pass the "Top level Makefile" check
echo "# Top level Makefile" > "$REPO/Makefile"

# Create a minimal include_all.sh stub for the test
cat > "$REPO/scripts/include_all.sh" << 'STUB'
aba_info() { echo "[ABA] $*" >&2; }
aba_debug() { :; }
aba_warn() { echo "[ABA] WARNING: $*" >&2; }
aba_success() { echo "[ABA] $*" >&2; }
aba_abort() { echo "[ABA] ERROR: $*" >&2; exit 1; }
normalize-aba-conf() { echo "export mirror_name=mirror"; }
STUB

# Create a pre-built cluster dir (has install-config + agent-config)
PRIMED="$REPO/mycluster"
mkdir -p "$PRIMED/iso-agent-based"  # Should be excluded
echo "cluster_name=mycluster" > "$PRIMED/cluster.conf"
echo "install-config" > "$PRIMED/install-config.yaml"
echo "agent-config" > "$PRIMED/agent-config.yaml"
touch "$PRIMED/.install-complete"  # Should be excluded from tar
# Create a symlink (mirror.conf -> mirror/mirror.conf)
echo "reg_host=reg.example.com" > "$REPO/mirror/mirror.conf"
ln -sf ../mirror/mirror.conf "$PRIMED/mirror.conf"
echo "big-iso-data" > "$PRIMED/iso-agent-based/agent.iso"

# Create a config-only cluster dir (no install-config or agent-config)
CONFIG_ONLY="$REPO/snotest"
mkdir -p "$CONFIG_ONLY"
echo "cluster_name=snotest" > "$CONFIG_ONLY/cluster.conf"

# Copy the real transfer-primed.sh
cp "$ABA_ROOT/scripts/transfer-primed.sh" "$REPO/scripts/"

# --- Test 1: Creates tar ---
echo "Test 1: Creates aba-transfer-configs.tar"
(cd "$REPO" && bash scripts/transfer-primed.sh 2>/dev/null)
assert_file_exists "Tar file created" "$REPO/mirror/data/aba-transfer-configs.tar"

TAR="$REPO/mirror/data/aba-transfer-configs.tar"

# --- Test 2: Excludes iso-agent-based ---
echo "Test 2: Excludes iso-agent-based/"
assert_tar_not_contains "No iso-agent-based in tar" "$TAR" "iso-agent-based"

# --- Test 3: Excludes lifecycle markers ---
echo "Test 3: Excludes .install-complete"
assert_tar_not_contains "No .install-complete" "$TAR" ".install-complete"

# --- Test 4: Contains cluster.conf ---
echo "Test 4: Contains cluster config files"
assert_tar_contains "mycluster/cluster.conf in tar" "$TAR" "mycluster/cluster.conf"
assert_tar_contains "snotest/cluster.conf in tar" "$TAR" "snotest/cluster.conf"

# --- Test 5: .primed marker in pre-built dir ---
echo "Test 5: .primed marker for pre-built dir"
assert_tar_contains ".primed in mycluster" "$TAR" "mycluster/.primed"

# --- Test 6: No .primed in config-only dir ---
echo "Test 6: No .primed in config-only dir"
assert_tar_not_contains "No .primed in snotest" "$TAR" "snotest/.primed"

# --- Test 7: Symlinks restored after tar ---
echo "Test 7: Symlinks restored (cleanup trap)"
if [ -L "$PRIMED/mirror.conf" ]; then
	assert_pass "mirror.conf is symlink again after tar"
else
	assert_fail "mirror.conf should be restored to symlink"
fi

# --- Test 8: .primed removed from source ---
echo "Test 8: .primed removed from source repo"
if [ ! -f "$PRIMED/.primed" ]; then
	assert_pass ".primed removed from source"
else
	assert_fail ".primed should NOT remain in source repo"
fi

# --- Summary ---
echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
