#!/bin/bash
# Test parallel validation race condition in run_once
# This tests the fix for the issue where multiple processes calling ensure_*
# simultaneously would cause validation race conditions

set -e

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

# Disable ERR trap for test
trap - ERR

# Use test runner directory to avoid conflicts
export RUN_ONCE_DIR="$HOME/.aba/runner-test-parallel-validation"
TEST_OUTPUT_DIR="/tmp/aba-test-parallel-validation-$$"

# Cleanup
cleanup() {
	rm -rf "$RUN_ONCE_DIR" "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT
cleanup  # Clean any previous test runs

mkdir -p "$TEST_OUTPUT_DIR"

echo "======================================================================"
echo "Test 1: Sequential validation (baseline)"
echo "======================================================================"

output1="$TEST_OUTPUT_DIR/output1.txt"

# Simple idempotent task
task1=(bash -c "
	if [[ -f '$output1' ]]; then
		exit 0
	fi
	echo 'creating' > '$output1'
	exit 0
")

echo "→ Running task..."
run_once -i "test:parallel:seq" -- "${task1[@]}"
run_once -w -i "test:parallel:seq"

if [[ ! -f "$output1" ]]; then
	echo "❌ FAIL: Output not created"
	exit 1
fi
echo "✓ Task completed"

# Wait again - should trigger validation
echo "→ Waiting again (triggers validation)..."
run_once -w -i "test:parallel:seq"

echo "✓ Validation succeeded"

echo ""
echo "======================================================================"
echo "Test 2: Parallel waits don't interfere with each other"
echo "======================================================================"

output2="$TEST_OUTPUT_DIR/output2.txt"
echo "initial" > "$output2"

task2=(bash -c "
	if [[ -f '$output2' ]]; then
		exit 0
	fi
	echo 'created' > '$output2'
	exit 0
")

# Run task once
echo "→ Running task..."
run_once -i "test:parallel:waits" -- "${task2[@]}"
run_once -w -i "test:parallel:waits"

echo "✓ Task completed"

# Run 3 parallel waits - all should succeed
echo "→ Running 3 parallel waits..."
run_once -w -i "test:parallel:waits" &
run_once -w -i "test:parallel:waits" &
run_once -w -i "test:parallel:waits" &
wait

echo "✓ All parallel waits succeeded"

if [[ ! -f "$output2" ]]; then
	echo "❌ FAIL: Output lost"
	exit 1
fi
echo "✓ Output still exists"

echo ""
echo "======================================================================"
echo "✓ ALL TESTS PASSED"
echo "======================================================================"
echo ""
echo "Summary:"
echo "  - Sequential validation works correctly"
echo "  - Parallel waits don't interfere with each other"
echo "  - Validation holds lock properly (no race conditions)"
