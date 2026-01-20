#!/bin/bash
# Test connectivity checks in aba.sh
# This verifies that connectivity check failures are properly detected and reported

set -e

cd "$(dirname "$0")/../.."

source scripts/include_all.sh

echo "=== Testing Connectivity Checks ==="
echo ""

# Backup original aba.sh with unique name
BACKUP_FILE="scripts/aba.sh.connectivity-test-backup-$$"
cp scripts/aba.sh "$BACKUP_FILE"

cleanup() {
	echo "[Cleanup] Restoring original files..."
	# Restore original aba.sh
	if [ -f "$BACKUP_FILE" ]; then
		cp "$BACKUP_FILE" scripts/aba.sh
		rm -f "$BACKUP_FILE"
	fi
	# Clean up any .bak files from sed
	rm -f scripts/aba.sh.bak scripts/aba.sh.test-backup
	# Clean up test runner cache (both broken and normal task IDs)
	rm -rf ~/.aba/runner/cli:check:x* 2>/dev/null || true
	rm -rf ~/.aba/runner/cli:check:api.openshift.com 2>/dev/null || true
	rm -rf ~/.aba/runner/cli:check:mirror.openshift.com 2>/dev/null || true
	rm -rf ~/.aba/runner/cli:check:registry.redhat.io 2>/dev/null || true
	echo "[Cleanup] Done"
}
trap cleanup EXIT INT TERM

# Clear any existing check cache
rm -rf ~/.aba/runner/cli:check:* 2>/dev/null || true

##############################################################
echo "Test 1: Single site failure (api.openshift.com)"
echo "----------------------------------------------"

# Break api.openshift.com URL
sed -i.bak 's|https://api.openshift.com/|https://xapi.openshift.com/|g' scripts/aba.sh

# Try to run aba (will fail at connectivity check)
trap - ERR
set +e
output=$(timeout 30 bash -c "cd ~/aba && ./aba" 2>&1)
test_rc=$?
set -e
trap 'show_error' ERR

# Check that failure was detected (task ID shows as api.openshift.com even though URL is broken)
if echo "$output" | grep -q "Cannot access required sites.*api.openshift.com"; then
	echo "✓ PASS: Failed site detected and reported"
	# Show what was detected
	echo "$output" | grep "Cannot access required sites:" | sed 's/\[ABA\] Error: /  → /'
else
	echo "✗ FAIL: Failed site not properly detected"
	echo "Output was:"
	echo "$output" | grep "Cannot access" || echo "(no error message found)"
	exit 1
fi

# Check that error details are shown
if echo "$output" | grep -q "Error details:"; then
	echo "✓ PASS: Error details shown"
else
	echo "✗ FAIL: Error details not shown"
	exit 1
fi

# Restore for next test (also done by trap, but explicit is better)
cp "$BACKUP_FILE" scripts/aba.sh
rm -f scripts/aba.sh.bak
rm -rf ~/.aba/runner/cli:check:* 2>/dev/null || true

echo ""

##############################################################
echo "Test 2: Multiple site failures (api + mirror)"
echo "----------------------------------------------"

# Break two URLs
cp "$BACKUP_FILE" scripts/aba.sh  # Start fresh from backup
sed -i.bak 's|https://api.openshift.com/|https://xapi.openshift.com/|g; s|https://mirror.openshift.com/|https://xmirror.openshift.com/|g' scripts/aba.sh

# Try to run aba (disable error traps temporarily since aba will fail on purpose)
trap - ERR
set +e
output=$(timeout 30 bash -c "cd ~/aba && ./aba" 2>&1)
test_rc=$?
set -e
trap 'show_error' ERR

# Check if two sites are reported (order may vary)
if echo "$output" | grep -qE "Cannot access required sites:.*,.*"; then
	echo "✓ PASS: Multiple failed sites detected"
	# Show which sites were reported
	echo "$output" | grep "Cannot access required sites:" | sed 's/\[ABA\] Error: /  → /'
else
	echo "✗ FAIL: Not all failed sites detected"
	echo "Output was:"
	echo "$output" | grep "Cannot access"
	exit 1
fi

if echo "$output" | grep -q "Error details:"; then
	echo "✓ PASS: Error details shown"
else
	echo "✗ FAIL: Error details not shown"
	exit 1
fi

# Restore for next test (also done by trap, but explicit is better)
cp "$BACKUP_FILE" scripts/aba.sh
rm -f scripts/aba.sh.bak
rm -rf ~/.aba/runner/cli:check:* 2>/dev/null || true

echo ""

##############################################################
echo "Test 3: All sites working (no failures)"
echo "----------------------------------------------"

# Don't break any URLs, but clear cache to force fresh check
rm -rf ~/.aba/runner/cli:check:* 2>/dev/null || true

# Run connectivity check portion only (not full aba)
source scripts/include_all.sh
export ABA_ROOT="$PWD"

run_once -i "cli:check:api.openshift.com" -- curl -sL --head --connect-timeout 5 --max-time 10 https://api.openshift.com/
run_once -i "cli:check:mirror.openshift.com" -- curl -sL --head --connect-timeout 5 --max-time 10 https://mirror.openshift.com/
run_once -i "cli:check:registry.redhat.io" -- curl -sL --head --connect-timeout 5 --max-time 10 https://registry.redhat.io/

failed_sites=""
if ! run_once -w -i "cli:check:api.openshift.com"; then
	failed_sites="api.openshift.com"
fi
if ! run_once -w -i "cli:check:mirror.openshift.com"; then
	[[ -n "$failed_sites" ]] && failed_sites="$failed_sites, "
	failed_sites="${failed_sites}mirror.openshift.com"
fi
if ! run_once -w -i "cli:check:registry.redhat.io"; then
	[[ -n "$failed_sites" ]] && failed_sites="$failed_sites, "
	failed_sites="${failed_sites}registry.redhat.io"
fi

if [[ -z "$failed_sites" ]]; then
	echo "✓ PASS: All sites accessible (no failures)"
else
	echo "✗ FAIL: Unexpected failures: $failed_sites"
	echo "Note: This may be a real network issue, not a test failure"
fi

echo ""

##############################################################
echo "Test 4: Check caching behavior"
echo "----------------------------------------------"

# Checks should already be cached from Test 3
# Running again should be instant (cached results)

start_time=$(date +%s)
run_once -w -i "cli:check:api.openshift.com" >/dev/null 2>&1
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [[ $elapsed -lt 2 ]]; then
	echo "✓ PASS: Cached results used (${elapsed}s)"
else
	echo "⚠ WARNING: Check took ${elapsed}s (expected <2s for cache)"
fi

echo ""

##############################################################
echo "=== All Tests Complete ==="
echo ""
aba_info_ok "✓ Connectivity check tests passed!"
