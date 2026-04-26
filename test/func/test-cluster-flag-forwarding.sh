#!/bin/bash
# Test: Verify CLI flags flow through the full aba cluster -n pipeline
# Covers: first creation, override of existing cluster.conf, idempotent re-run
# Unit test (fast, local, no network, no cluster install)

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$((pass + 1)); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; fail=$((fail + 1)); FAILURES=1; }

assert_conf_value() {
	local file="$1" key="$2" expected="$3"
	local actual
	actual=$(grep -E "^${key}=" "$file" | head -1 | sed 's/[[:space:]]*#.*//' | cut -d= -f2)
	if [ "$actual" = "$expected" ]; then
		test_pass "$key=$expected"
	else
		test_fail "$key expected [$expected] got [$actual]"
	fi
}

CLUSTER_DIR="test-flagfwd-$$"

# Save and restore aba.conf around the test (non-interactive mode needed)
cp aba.conf aba.conf.test-backup

cleanup() {
	rm -rf "$CLUSTER_DIR"
	[ -f aba.conf.test-backup ] && mv aba.conf.test-backup aba.conf
}
trap cleanup EXIT

# Set non-interactive mode so create-cluster-conf.sh doesn't open an editor
sed -i -E 's/^ask=.*/ask=false/' aba.conf

echo
echo "=== Testing: CLI flag forwarding via aba cluster -n ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: First creation with flags
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 1: First creation with flags ---"

./aba cluster -n "$CLUSTER_DIR" -t standard --num-workers 7 --vlan 100 --mirror-name enclave1 -I proxy --step cluster.conf >/dev/null 2>&1

CONF="$CLUSTER_DIR/cluster.conf"

[ -f "$CONF" ] && test_pass "cluster.conf created" || test_fail "cluster.conf not created"

assert_conf_value "$CONF" num_workers 7
assert_conf_value "$CONF" vlan 100
assert_conf_value "$CONF" mirror_name enclave1
assert_conf_value "$CONF" int_connection proxy

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Override existing cluster.conf
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 2: Override existing cluster.conf ---"

./aba cluster -n "$CLUSTER_DIR" --num-workers 5 -I direct --mirror-name enclave2 --step cluster.conf >/dev/null 2>&1

assert_conf_value "$CONF" num_workers 5
assert_conf_value "$CONF" int_connection direct
assert_conf_value "$CONF" mirror_name enclave2
# vlan should be unchanged (not passed this time)
assert_conf_value "$CONF" vlan 100

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Idempotent re-run (no file change)
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 3: Idempotent re-run ---"

ts_before=$(stat -c %Y "$CONF")
sleep 1

./aba cluster -n "$CLUSTER_DIR" --num-workers 5 --step cluster.conf >/dev/null 2>&1

ts_after=$(stat -c %Y "$CONF")

if [ "$ts_before" = "$ts_after" ]; then
	test_pass "cluster.conf timestamp unchanged (no-op)"
else
	test_fail "cluster.conf timestamp changed (expected no-op)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="

[ "$fail" -gt 0 ] && exit 1
exit 0
