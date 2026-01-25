#!/bin/bash
# Test script for run_once -t (TTL) option

set -euo pipefail

cd "$(dirname "$0")/../.."  # Change to ABA root
export DEBUG_ABA=0
export ABA_ROOT="$(pwd)"

source scripts/include_all.sh

# Use a test directory
export RUN_ONCE_DIR="/tmp/test-run-once-ttl"
rm -rf "$RUN_ONCE_DIR"
mkdir -p "$RUN_ONCE_DIR"

TEST_OUTPUT="/tmp/test-run-once-output.txt"
rm -f "$TEST_OUTPUT"

echo "=== Test 1: First run should execute ==="
run_once -i "test:ttl:task1" -t 5 -- bash -c "echo 'First run' >> $TEST_OUTPUT; date"
sleep 1
cat "$TEST_OUTPUT"
echo "Expected: 'First run'"
echo ""

echo "=== Test 2: Second run (within TTL) should skip ==="
run_once -i "test:ttl:task1" -t 5 -- bash -c "echo 'Second run' >> $TEST_OUTPUT; date"
sleep 1
cat "$TEST_OUTPUT"
echo "Expected: Only 'First run' (not 'Second run')"
echo ""

echo "=== Test 3: Wait for TTL to expire (5 seconds) ==="
echo "Waiting 6 seconds..."
sleep 6

echo "=== Test 4: After TTL expires, should execute again ==="
run_once -i "test:ttl:task1" -t 5 -- bash -c "echo 'Third run (after TTL)' >> $TEST_OUTPUT; date"
sleep 1
cat "$TEST_OUTPUT"
echo "Expected: 'First run' AND 'Third run (after TTL)'"
echo ""

echo "=== Test 5: Verify exit file timestamps ==="
ls -la "$RUN_ONCE_DIR"
echo ""

echo "=== Test 6: Test with -w (wait mode) and TTL ==="
run_once -w -i "test:ttl:task2" -t 3 -- bash -c "echo 'Task 2 first' >> $TEST_OUTPUT; sleep 1"
cat "$TEST_OUTPUT"
echo "Waiting 4 seconds for TTL..."
sleep 4
run_once -w -i "test:ttl:task2" -t 3 -- bash -c "echo 'Task 2 after TTL' >> $TEST_OUTPUT; sleep 1"
cat "$TEST_OUTPUT"
echo "Expected: Both 'Task 2 first' AND 'Task 2 after TTL'"
echo ""

echo "=== Test 7: Peek mode should work correctly ==="
if run_once -p -i "test:ttl:task2"; then
    echo "✓ Peek returned 0 (task exists)"
else
    echo "✗ Peek returned 1 (task doesn't exist)"
fi
echo ""

echo "=== All tests complete ==="
echo "Logs in: $RUN_ONCE_DIR"
echo "Output in: $TEST_OUTPUT"

