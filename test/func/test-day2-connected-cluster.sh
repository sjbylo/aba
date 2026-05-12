#!/bin/bash
# Test: Verify day2 scripts correctly detect connected clusters (no mirror needed)
# Unit test (fast, static analysis, no network)

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }

echo
echo "=== Testing: day2 scripts with connected clusters (no mirror) ==="
echo

# ---------------------------------------------------------------
# Test 1: day2.sh sources normalize-cluster-conf which exposes int_connection
# ---------------------------------------------------------------
echo "--- Test 1: day2.sh reads int_connection from cluster.conf ---"

grep -q 'normalize-cluster-conf' scripts/day2.sh && \
	test_pass "day2.sh sources normalize-cluster-conf (provides int_connection)" || \
	test_fail "day2.sh does not source normalize-cluster-conf"

# Test 2: Verify the day2.sh script contains the early-exit guard
grep -q 'if \[ "$int_connection" \]' scripts/day2.sh && \
	test_pass "day2.sh checks int_connection variable" || \
	test_fail "day2.sh missing int_connection check"

# Test 3: Verify day2.sh exits 0 when int_connection is set
grep -A5 'if \[ "$int_connection" \]' scripts/day2.sh | grep -q 'exit 0' && \
	test_pass "day2.sh exits 0 for connected clusters" || \
	test_fail "day2.sh does not exit 0 for connected clusters"

# Test 4: Verify day2-config-osus.sh also guards against connected clusters
grep -q 'if \[ "$int_connection" \]' scripts/day2-config-osus.sh && \
	test_pass "day2-config-osus.sh checks int_connection variable" || \
	test_fail "day2-config-osus.sh missing int_connection check"

grep -A4 'if \[ "$int_connection" \]' scripts/day2-config-osus.sh | grep -q 'exit 0' && \
	test_pass "day2-config-osus.sh exits 0 for connected clusters" || \
	test_fail "day2-config-osus.sh does not exit 0 for connected clusters"

# Test 5: Verify day2-config-ntp.sh does NOT skip connected clusters (NTP is always needed)
if grep -q 'if \[ "$int_connection" \]' scripts/day2-config-ntp.sh 2>/dev/null; then
	# If it has the check, verify it does NOT exit (NTP should run for all clusters)
	if grep -A3 'if \[ "$int_connection" \]' scripts/day2-config-ntp.sh | grep -q 'exit 0'; then
		test_fail "day2-config-ntp.sh should NOT skip connected clusters (NTP always needed)"
	else
		test_pass "day2-config-ntp.sh has int_connection check but doesn't exit (OK)"
	fi
else
	test_pass "day2-config-ntp.sh has no int_connection guard (NTP runs for all clusters)"
fi

# Test 6: Verify the user-facing message mentions 'connected cluster'
grep -q "connected cluster" scripts/day2.sh && \
	test_pass "day2.sh informs user about connected cluster status" || \
	test_fail "day2.sh missing informational message for connected clusters"

# Test 7: Verify int_connection=proxy is also handled (not just 'direct')
# The check is [ "$int_connection" ] which is true for any non-empty value
# (covers both 'direct' and 'proxy')
if grep 'if \[ "$int_connection" \]' scripts/day2.sh | grep -qv "direct\|proxy"; then
	test_pass "day2.sh uses generic [ \"\$int_connection\" ] check (handles both direct and proxy)"
else
	# The check doesn't hardcode 'direct' — it fires for ANY non-empty value
	grep -q '\[ "$int_connection" \]' scripts/day2.sh && \
		test_pass "day2.sh guard fires for any non-empty int_connection (covers direct + proxy)" || \
		test_fail "day2.sh guard is too specific or missing"
fi

# Test 8: Verify normalize-cluster-conf outputs int_connection when set
grep -q 'int_connection' scripts/include_all.sh && \
	test_pass "include_all.sh handles int_connection variable" || \
	test_fail "include_all.sh does not reference int_connection"

echo
echo "=== All day2 connected-cluster tests passed ==="
echo
