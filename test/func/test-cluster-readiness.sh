#!/bin/bash
# Unit tests for cluster_is_ready() helper.
# Uses a mock oc command to simulate various cluster states.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

_mock_dir=$(mktemp -d)
trap 'rm -rf "$_mock_dir"' EXIT

source scripts/include_all.sh dummy_arg 2>/dev/null

echo
echo "=== Testing: cluster_is_ready() ==="
echo

# Helper to create a mock oc that returns specific jsonpath values
# Args: cv_available cv_progressing degraded_statuses
_create_mock_oc() {
	local cv_available="$1" cv_progressing="$2" degraded_list="$3"
	cat > "$_mock_dir/oc" <<MOCK
#!/bin/bash
# Parse arguments to determine what's being queried
args="\$*"
case "\$args" in
	*clusterversion*Available*)
		echo "$cv_available" ;;
	*clusterversion*Progressing*)
		echo "$cv_progressing" ;;
	*co*Degraded*)
		echo "$degraded_list" ;;
	*)
		exit 0 ;;
esac
MOCK
	chmod +x "$_mock_dir/oc"
}

# Test 1: fully ready cluster
_create_mock_oc "True" "False" "False
False
False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_pass "Fully ready cluster returns 0" \
  || test_fail "Fully ready cluster returns 0" "expected rc=0"

# Test 2: ClusterVersion not available
_create_mock_oc "False" "False" "False
False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "CV not available should return 1" "expected rc=1 but got 0" \
  || test_pass "CV not available returns 1"

# Test 3: ClusterVersion still progressing
_create_mock_oc "True" "True" "False
False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "CV progressing should return 1" "expected rc=1 but got 0" \
  || test_pass "CV still progressing returns 1"

# Test 4: one operator degraded
_create_mock_oc "True" "False" "False
True
False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "Degraded operator should return 1" "expected rc=1 but got 0" \
  || test_pass "Degraded operator returns 1"

# Test 5: multiple operators degraded
_create_mock_oc "True" "False" "True
True
False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "Multiple degraded should return 1" "expected rc=1 but got 0" \
  || test_pass "Multiple degraded operators returns 1"

# Test 6: everything broken (not available, progressing, degraded)
_create_mock_oc "False" "True" "True"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "All broken should return 1" "expected rc=1 but got 0" \
  || test_pass "All broken returns 1 (fails on first check)"

# Test 7: oc command fails entirely (unreachable cluster)
cat > "$_mock_dir/oc" <<'MOCK'
#!/bin/bash
exit 1
MOCK
chmod +x "$_mock_dir/oc"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "oc failure should return 1" "expected rc=1 but got 0" \
  || test_pass "oc failure (unreachable cluster) returns 1"

# Test 8: empty output from oc (partial failure)
cat > "$_mock_dir/oc" <<'MOCK'
#!/bin/bash
echo ""
MOCK
chmod +x "$_mock_dir/oc"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "Empty oc output should return 1" "expected rc=1 but got 0" \
  || test_pass "Empty oc output returns 1"

# Test 9: no degraded operators at all (fresh small cluster)
_create_mock_oc "True" "False" ""
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_pass "No operators listed (zero degraded) returns 0" \
  || test_fail "No operators listed (zero degraded) returns 0" "expected rc=0"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="
[ -z "$FAILURES" ] && echo -e "${GREEN}All tests passed!${NC}" || echo -e "${RED}Some tests failed!${NC}"
exit ${FAILURES:+1}
exit 0
