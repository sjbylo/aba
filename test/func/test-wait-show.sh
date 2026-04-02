#!/bin/bash
# Test: aba_wait_show() from scripts/include_all.sh
#
# Manual output check (TTY vs non-TTY):
#   TTY:    ./test/func/test-wait-show.sh
#   Log:    ./test/func/test-wait-show.sh 2>&1 | cat
#   script: script -q /dev/null ./test/func/test-wait-show.sh  (forces non-TTY for stdout)

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }

# shellcheck source=/dev/null
source scripts/include_all.sh

echo
echo "=== Testing: aba_wait_show (include_all.sh) ==="
echo

# 1) Syntax: function exists
grep -q '^aba_wait_show()' scripts/include_all.sh && test_pass "aba_wait_show defined" || test_fail "aba_wait_show missing"

# 2) Immediate success (no progress lines)
if aba_wait_show "immediate" 1 10 "true"; then
	test_pass "returns 0 when check succeeds on first try"
else
	test_fail "expected 0 from true"
fi

# 3) Immediate timeout (max 0, check always false)
if ! aba_wait_show "timeout0" 1 0 "false"; then
	test_pass "returns 1 when max_sec is 0 and check fails"
else
	test_fail "expected 1 from max=0"
fi

# 4) Timeout after wall clock
if ! aba_wait_show "wall" 1 3 "false"; then
	test_pass "returns 1 after deadline (~3s)"
else
	test_fail "expected timeout"
fi

# 5) Success before deadline (counter in current shell)
WAIT_COUNT=0
if aba_wait_show "flip" 1 15 "WAIT_COUNT=\$((WAIT_COUNT+1)); [ \"\$WAIT_COUNT\" -ge 5 ]"; then
	test_pass "returns 0 when check succeeds before max_sec"
else
	test_fail "expected success before timeout"
fi

# 6) Invalid args
if aba_wait_show "bad" x 10 "true" 2>/dev/null; then
	test_fail "expected non-zero for bad interval"
else
	test_pass "returns 2 for non-numeric interval"
fi

echo
echo "All automated checks passed."
echo "Manual: run in a real terminal vs. pipe to cat to compare TTY vs log-style output."
echo
