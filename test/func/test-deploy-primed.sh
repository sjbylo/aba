#!/bin/bash
# test-deploy-primed.sh — Validate deploy-primed CLI dispatch and help
#
# Tests:
# 1. deploy-primed recognized as target
# 2. deploy alias recognized as target
# 3. bundle-primed alias recognized as target
# 4. Help dispatch works for deploy-primed
# 5. Help dispatch works for transfer-primed
# 6. deploy-primed requires cluster.conf (aborts otherwise)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_green() { echo -e "\033[0;32m$*\033[0m"; }
_red() { echo -e "\033[0;31m$*\033[0m"; }

PASS=0
FAIL=0

assert_pass() { PASS=$(( PASS + 1 )); _green "  ✓ $1"; }
assert_fail() { FAIL=$(( FAIL + 1 )); _red "  ✗ $1"; }

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF "$needle"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (needle '$needle' not found in output)"
	fi
}

assert_exit_zero() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		assert_pass "$desc"
	else
		assert_fail "$desc (exit code: $?)"
	fi
}

assert_exit_nonzero() {
	local desc="$1"
	shift
	if ! "$@" >/dev/null 2>&1; then
		assert_pass "$desc"
	else
		assert_fail "$desc (expected failure, got exit 0)"
	fi
}

echo "=== test-deploy-primed.sh ==="
echo

# --- Test 1: Help for deploy-primed ---
echo "Test 1: Help for deploy-primed"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh deploy-primed --help 2>/dev/null || true)
assert_contains "deploy-primed help shows pipeline" "$output" "Pipeline steps"

# --- Test 2: Help for deploy alias ---
echo "Test 2: Help for deploy alias"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh deploy --help 2>/dev/null || true)
assert_contains "deploy help shows pipeline" "$output" "Pipeline steps"

# --- Test 3: Help for transfer-primed ---
echo "Test 3: Help for transfer-primed"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh transfer-primed --help 2>/dev/null || true)
assert_contains "transfer-primed help shows usage" "$output" "config-only transfer"

# --- Test 4: Help for transfer alias ---
echo "Test 4: Help for transfer alias"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh transfer --help 2>/dev/null || true)
assert_contains "transfer help shows usage" "$output" "config-only transfer"

# --- Test 5: bundle-primed in main help ---
echo "Test 5: bundle-primed listed in main help"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh --help 2>/dev/null || true)
assert_contains "bundle-primed in main help" "$output" "bundle-primed"

# --- Test 6: deploy-primed in main help ---
echo "Test 6: deploy-primed listed in main help"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh --help 2>/dev/null || true)
assert_contains "deploy-primed in main help" "$output" "deploy-primed"

# --- Test 7: transfer-primed in main help ---
echo "Test 7: transfer-primed listed in main help"
output=$(cd "$ABA_ROOT" && bash scripts/aba.sh --help 2>/dev/null || true)
assert_contains "transfer-primed in main help" "$output" "transfer-primed"

# --- Test 8: missing cluster.conf aborts ---
# Place the temp cluster under ABA_ROOT so ../mirror exists; mirror is checked
# before cluster.conf, so we need a valid mirror path to reach the conf guard.
echo "Test 8: deploy-primed without cluster.conf aborts"
TMP_ERR="$ABA_ROOT/.test-deploy-primed-err-$$"
mkdir -p "$TMP_ERR"
ln -sfn "$ABA_ROOT/scripts" "$TMP_ERR/scripts"
err_out=$(cd "$TMP_ERR" && bash "$ABA_ROOT/scripts/deploy-primed.sh" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
	assert_pass "missing cluster.conf exits non-zero"
else
	assert_fail "missing cluster.conf exits non-zero (got exit 0)"
fi
assert_contains "missing cluster.conf message" "$err_out" "Not in a cluster directory"

# --- Test 9: missing mirror dir aborts ---
echo "Test 9: deploy-primed with missing mirror dir aborts"
echo "image_source=no-such-mirror-dir-$$" > "$TMP_ERR/cluster.conf"
err_out=$(cd "$TMP_ERR" && bash "$ABA_ROOT/scripts/deploy-primed.sh" 2>&1) && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
	assert_pass "missing mirror dir exits non-zero"
else
	assert_fail "missing mirror dir exits non-zero (got exit 0)"
fi
assert_contains "missing mirror dir message" "$err_out" "Mirror directory not found"
rm -rf "$TMP_ERR"

# --- Summary ---
echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
