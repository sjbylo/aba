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

# Helper to create a mock oc that returns cluster operator status lines.
# cluster_is_ready() makes a single 'oc get co' call and expects each line
# to be "Available Progressing Degraded" for one CO.
_create_mock_oc() {
	local status_lines="$1"
	cat > "$_mock_dir/oc" <<MOCK
#!/bin/bash
echo "$status_lines"
MOCK
	chmod +x "$_mock_dir/oc"
}

# Test 1: fully ready cluster (3 operators, all healthy)
_create_mock_oc "True False False
True False False
True False False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_pass "Fully ready cluster returns 0" \
  || test_fail "Fully ready cluster returns 0" "expected rc=0"

# Test 2: one CO unavailable
_create_mock_oc "False False False
True False False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "CO not available should return 1" "expected rc=1 but got 0" \
  || test_pass "CO not available returns 1"

# Test 3: one CO still progressing
_create_mock_oc "True True False
True False False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "CO progressing should return 1" "expected rc=1 but got 0" \
  || test_pass "CO still progressing returns 1"

# Test 4: one operator degraded
_create_mock_oc "True False False
True False True
True False False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "Degraded operator should return 1" "expected rc=1 but got 0" \
  || test_pass "Degraded operator returns 1"

# Test 5: multiple operators degraded
_create_mock_oc "True False True
True False True
True False False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_fail "Multiple degraded should return 1" "expected rc=1 but got 0" \
  || test_pass "Multiple degraded operators returns 1"

# Test 6: everything broken (not available, progressing, degraded)
_create_mock_oc "False True True"
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

# Test 9: no operators listed (zero lines = empty cluster)
_create_mock_oc "True False False"
(
	export PATH="$_mock_dir:$PATH"
	cluster_is_ready
) && test_pass "Single healthy CO returns 0" \
  || test_fail "Single healthy CO returns 0" "expected rc=0"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="
[ -z "$FAILURES" ] && echo -e "${GREEN}All tests passed!${NC}" || echo -e "${RED}Some tests failed!${NC}"
exit ${FAILURES:+1}
exit 0
