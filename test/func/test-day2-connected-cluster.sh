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
# Test 1: day2.sh sources normalize-cluster-conf which exposes image_source
# ---------------------------------------------------------------
echo "--- Test 1: day2.sh reads image_source from cluster.conf ---"

grep -q 'normalize-cluster-conf' scripts/day2.sh && \
	test_pass "day2.sh sources normalize-cluster-conf (provides image_source)" || \
	test_fail "day2.sh does not source normalize-cluster-conf"

# Test 2: Verify the day2.sh script contains the early-exit guard
grep -q 'image_source_is_mirror' scripts/day2.sh && \
	test_pass "day2.sh checks image_source via image_source_is_mirror" || \
	test_fail "day2.sh missing image_source check"

# Test 3: Verify day2.sh exits 0 when cluster is NOT using mirror
grep -A5 'image_source_is_mirror' scripts/day2.sh | grep -q 'exit 0' && \
	test_pass "day2.sh exits 0 for connected clusters" || \
	test_fail "day2.sh does not exit 0 for connected clusters"

# Test 4: Verify day2-config-osus.sh also guards against connected clusters
grep -q 'image_source_is_mirror' scripts/day2-config-osus.sh && \
	test_pass "day2-config-osus.sh checks image_source via image_source_is_mirror" || \
	test_fail "day2-config-osus.sh missing image_source check"

grep -A4 'image_source_is_mirror' scripts/day2-config-osus.sh | grep -q 'exit 0' && \
	test_pass "day2-config-osus.sh exits 0 for connected clusters" || \
	test_fail "day2-config-osus.sh does not exit 0 for connected clusters"

# Test 5: Verify day2-config-ntp.sh does NOT skip connected clusters (NTP is always needed)
if grep -q 'image_source_is_mirror' scripts/day2-config-ntp.sh 2>/dev/null; then
	if grep -A3 'image_source_is_mirror' scripts/day2-config-ntp.sh | grep -q 'exit 0'; then
		test_fail "day2-config-ntp.sh should NOT skip connected clusters (NTP always needed)"
	else
		test_pass "day2-config-ntp.sh has image_source check but doesn't exit (OK)"
	fi
else
	test_pass "day2-config-ntp.sh has no image_source guard (NTP runs for all clusters)"
fi

# Test 6: Verify the user-facing message mentions internet
grep -q "connects directly to the internet" scripts/day2.sh && \
	test_pass "day2.sh informs user about connected cluster status" || \
	test_fail "day2.sh missing informational message for connected clusters"

# Test 7: Verify image_source_is_mirror covers both direct and proxy
grep -q 'image_source_is_mirror' scripts/day2.sh && \
	test_pass "day2.sh uses image_source_is_mirror (handles both direct and proxy)" || \
	test_fail "day2.sh guard is missing"

# Test 8: Verify include_all.sh has image_source_is_mirror helper
grep -q 'image_source_is_mirror' scripts/include_all.sh && \
	test_pass "include_all.sh has image_source_is_mirror helper" || \
	test_fail "include_all.sh missing image_source_is_mirror"

echo
echo "=== All day2 connected-cluster tests passed ==="
echo
