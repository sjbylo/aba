#!/bin/bash
# Test: CLI download wait integration
#
# Verifies the cli/Makefile .wait-downloads mechanism that prevents
# background downloads (started by aba.sh) from racing with foreground
# make install extractions.
#
# Tests:
#   1. make install waits for background downloads (no corruption after reset)
#   2. Idempotent make install produces no extraction output
#   3. cli-download-all.sh --wait is silent when all downloads complete
#   4. run_once -p (peek) correctly reports pending vs complete vs running

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

trap - ERR

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() {
	echo -e "${GREEN}  PASS${NC}: $1"
	pass_count=$((pass_count + 1))
}

test_fail() {
	echo -e "${RED}  FAIL${NC}: $1"
	fail_count=$((fail_count + 1))
}

section() {
	echo ""
	echo "=================================================================="
	echo "  $1"
	echo "=================================================================="
}

section "Test 1: reset -f then install completes without corruption"

# After reset, background downloads race with foreground make.
# .wait-downloads must prevent double-download and corrupt tarballs.
aba --dir cli reset -f 2>&1 >/dev/null
output=$(aba --dir cli install 2>&1)

if echo "$output" | grep -q 'invalid!!'; then
	test_fail "Checksum failure detected — download race not prevented"
elif echo "$output" | grep -q 'unexpected end of file'; then
	test_fail "Corrupt tarball — download race not prevented"
elif echo "$output" | grep -qi 'error'; then
	test_fail "Error during install: $(echo "$output" | grep -i error | head -1)"
else
	test_pass "reset -f then install completed without corruption"
fi

# Verify all expected binaries exist
for bin in oc openshift-install oc-mirror butane; do
	if [ -x ~/bin/$bin ]; then
		test_pass "~/bin/$bin exists and is executable"
	else
		test_fail "~/bin/$bin missing or not executable after install"
	fi
done

section "Test 2: Idempotent install produces no extraction output"

output=$(make -C cli install 2>&1)

if echo "$output" | grep -q 'Extracting'; then
	test_fail "Idempotent run re-extracted binaries: $(echo "$output" | grep Extracting)"
else
	test_pass "Idempotent install did not re-extract anything"
fi

section "Test 3: cli-download-all.sh --wait is silent when all downloads complete"

output=$(scripts/cli-download-all.sh --wait 2>&1)

if echo "$output" | grep -q '\[ABA\] Ensuring'; then
	test_fail "--wait shows message even though all downloads are complete"
else
	test_pass "--wait is silent when all downloads are complete"
fi

section "Test 4: run_once -p (peek) reports correct status"

export RUN_ONCE_DIR="$HOME/.aba/runner-test-cli-wait-$$"
mkdir -p "$RUN_ONCE_DIR"
cleanup_test_runner() {
	rm -rf "$RUN_ONCE_DIR"
}
trap cleanup_test_runner EXIT

# 4a: nonexistent task → peek returns 1
if run_once -p -i "cli:download:fake-tool" 2>/dev/null; then
	test_fail "peek returned 0 for nonexistent task (should be 1)"
else
	test_pass "peek returns 1 for nonexistent/pending task"
fi

# 4b: completed task → peek returns 0
run_once -w -i "cli:download:fake-complete" -- bash -c "true"
if run_once -p -i "cli:download:fake-complete" 2>/dev/null; then
	test_pass "peek returns 0 for completed task"
else
	test_fail "peek returned 1 for completed task (should be 0)"
fi

# 4c: still-running task → peek returns 1
run_once -i "cli:download:fake-slow" -- bash -c "sleep 10"
sleep 0.2
if run_once -p -i "cli:download:fake-slow" 2>/dev/null; then
	test_fail "peek returned 0 for still-running task (should be 1)"
else
	test_pass "peek returns 1 for still-running task"
fi

run_once -G 2>/dev/null || true
unset RUN_ONCE_DIR
trap - EXIT
cleanup_test_runner

echo ""
echo "=================================================================="
echo "                       RESULTS"
echo "=================================================================="
echo ""
echo -e "  ${GREEN}Passed${NC}: $pass_count"
echo -e "  ${RED}Failed${NC}: $fail_count"
echo ""

if [ $fail_count -eq 0 ]; then
	echo -e "${GREEN}ALL TESTS PASSED${NC}"
	exit 0
else
	echo -e "${RED}SOME TESTS FAILED${NC}"
	exit 1
fi
