#!/bin/bash
# Test runner - runs all functional tests and reports results
# Usage: test/func/run-all-tests.sh [--unit|--integration|--all]

cd "$(dirname "$0")/../.."

mode="${1:---all}"

# Acquire lock to prevent multiple test runs
TEST_LOCK_FILE="$HOME/.aba/test-runner.lock"
mkdir -p "$HOME/.aba"

exec 200>"$TEST_LOCK_FILE"
if ! flock -n 200; then
	echo "Error: Another test run is already in progress." >&2
	echo "Wait for it to complete, or remove: $TEST_LOCK_FILE" >&2
	exit 1
fi
# Lock automatically released when script exits

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

run_test() {
	local test_file="$1"
	local test_name=$(basename "$test_file" .sh)
	
	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "Running: $test_name"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	
	if "$test_file"; then
		echo -e "${GREEN}✓ PASSED${NC}: $test_name"
		return 0
	else
		echo -e "${RED}✗ FAILED${NC}: $test_name"
		return 1
	fi
}

# Unit tests (fast, no downloads)
unit_tests=(
	test/func/test-no-aba-root-in-registry-scripts.sh
	test/func/test-run-once-task-consistency.sh
	test/func/test-run-once-failed-cleanup.sh
	test/func/test-symlinks-exist.sh
	test/func/test-aba-root-only-in-aba-sh.sh
)

# Integration tests (slow, may download)
integration_tests=(
	test/func/test-aba-root-cleanup.sh
	test/func/test-bundle-tar-output.sh
	test/func/test-mirror-save-workflow.sh
)

passed=0
failed=0
skipped=0

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          ABA Functional Test Suite                        ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Working directory: $PWD"
echo "Test mode: $mode"

# Run unit tests
if [ "$mode" = "--unit" ] || [ "$mode" = "--all" ]; then
	echo ""
	echo "┌────────────────────────────────────────────────────────┐"
	echo "│  UNIT TESTS (fast)                                     │"
	echo "└────────────────────────────────────────────────────────┘"
	
	for test in "${unit_tests[@]}"; do
		if [ -f "$test" ]; then
			if run_test "$test"; then
				((passed++))
			else
				((failed++))
			fi
		else
			echo -e "${YELLOW}⊘ SKIPPED${NC}: $test (not found)"
			((skipped++))
		fi
	done
fi

# Run integration tests
if [ "$mode" = "--integration" ] || [ "$mode" = "--all" ]; then
	echo ""
	echo "┌────────────────────────────────────────────────────────┐"
	echo "│  INTEGRATION TESTS (may take several minutes)         │"
	echo "└────────────────────────────────────────────────────────┘"
	
	for test in "${integration_tests[@]}"; do
		if [ -f "$test" ]; then
			if run_test "$test"; then
				((passed++))
			else
				((failed++))
			fi
		else
			echo -e "${YELLOW}⊘ SKIPPED${NC}: $test (not found)"
			((skipped++))
		fi
	done
fi

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    TEST SUMMARY                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $passed"
echo -e "  ${RED}Failed${NC}:  $failed"
echo -e "  ${YELLOW}Skipped${NC}: $skipped"
echo ""

if [ $failed -eq 0 ]; then
	echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${GREEN}║          ✓ ALL TESTS PASSED                                ║${NC}"
	echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
	exit 0
else
	echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
	echo -e "${RED}║          ✗ SOME TESTS FAILED                               ║${NC}"
	echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
	exit 1
fi

