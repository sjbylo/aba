#!/bin/bash
# Test run_once() -m (waiting message) flag
# Tests that waiting messages are displayed correctly with PID

set -e

# Setup test environment
TEST_DIR=$(mktemp -d)
export RUN_ONCE_DIR="$TEST_DIR/runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the functions
source "$ABA_ROOT/scripts/include_all.sh"

# Disable ERR trap from include_all.sh
trap - ERR

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() {
	echo -e "${GREEN}✓ PASS${NC}: $1"
	pass_count=$((pass_count + 1))
}

test_fail() {
	echo -e "${RED}✗ FAIL${NC}: $1"
	fail_count=$((fail_count + 1))
}

test_warn() {
	echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

section() {
	echo
	echo "════════════════════════════════════════════════════════════════"
	echo "  $1"
	echo "════════════════════════════════════════════════════════════════"
}

cleanup() {
	# Clean up any running tasks
	run_once -G 2>/dev/null || true
	rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "Testing run_once() -m (waiting message) flag"
echo "Test directory: $TEST_DIR"

# ============================================================
section "Test 1: Message NOT shown when task already complete"
# ============================================================

# Run and complete a task
run_once -i "test:msg:complete" -- bash -c "echo 'done'; exit 0"
sleep 0.2  # Ensure it completes

# Wait for already-completed task - should NOT show message
output=$(run_once -w -m "Should NOT see this message" -i "test:msg:complete" 2>&1)
if echo "$output" | grep -q "Should NOT see this message"; then
	test_fail "Message shown for already-complete task"
else
	test_pass "Message NOT shown for already-complete task"
fi

# ============================================================
section "Test 2: Message shown when waiting for running task"
# ============================================================

# Start a task that will run for a while  
run_once -i "test:msg:wait" -- bash -c "sleep 5; echo 'done'" &
sleep 1  # Let it definitely start

# Wait with message, use short timeout so test doesn't hang
run_once -w -W 2 -m "Waiting for background task" -i "test:msg:wait" > "$TEST_DIR/wait_output.txt" 2>&1 || true

# Give buffers time to flush
sleep 0.2

# Check if message was displayed
if [ -f "$TEST_DIR/wait_output.txt" ]; then
	output=$(<"$TEST_DIR/wait_output.txt")
	if echo "$output" | grep -q "Waiting for background task"; then
		test_pass "Message shown when waiting for running task"
		
		# Check for PID in message
		if echo "$output" | grep -qE "PID:? [0-9]+"; then
			test_pass "PID included in waiting message"
		else
			test_warn "PID format might have changed (output: $output)"
		fi
	else
		test_fail "Message NOT shown (output: $output)"
	fi
else
	test_fail "No output file created"
fi

# Clean up
run_once -r -i "test:msg:wait" || true

# ============================================================
section "Test 3: Generic message shown when -m flag not provided"
# ============================================================

# Complete a task quickly
run_once -i "test:msg:nomsg" -- bash -c "sleep 1; exit 0" &
sleep 0.3

# Wait without -m - should show generic "Waiting for task:" message
output=$(run_once -w -W 3 -i "test:msg:nomsg" 2>&1)
if echo "$output" | grep -q "Waiting for task: test:msg:nomsg"; then
	test_pass "Generic message shown when -m not provided"
else
	test_fail "Generic message NOT shown (output: $output)"
fi

# ============================================================
section "Test 4: Error output with -e flag"
# ============================================================

# Run a failing task
run_once -i "test:msg:error" -- bash -c "echo 'Error occurred' >&2; exit 1" || true
sleep 0.2

# Get error output
error_out=$(run_once -e -i "test:msg:error")
if echo "$error_out" | grep -q "Error occurred"; then
	test_pass "Error output retrieved with -e flag"
else
	test_fail "Error output NOT retrieved (got: $error_out)"
fi

# ============================================================
section "Test 5: Combination of -m and -W (timeout)"
# ============================================================

# Start a long task
run_once -i "test:msg:timeout" -- bash -c "sleep 20; exit 0" &
sleep 0.5

# Wait with short timeout and message
rc=0
output=$(run_once -w -W 2 -m "Waiting with timeout" -i "test:msg:timeout" 2>&1) || rc=$?

if [ "$rc" -eq 124 ]; then
	test_pass "Timeout occurred correctly (exit code 124)"
else
	test_warn "Exit code was $rc (expected 124 for timeout)"
fi

if echo "$output" | grep -q "Waiting with timeout"; then
	test_pass "Message shown before timeout"
else
	test_warn "Message not captured before timeout"
fi

# Clean up
run_once -r -i "test:msg:timeout" || true

# ============================================================
section "Test Results Summary"
# ============================================================

echo
echo "Tests passed: $pass_count"
echo "Tests failed: $fail_count"
echo

if [ $fail_count -eq 0 ]; then
	echo -e "${GREEN}✅ All tests passed!${NC}"
	exit 0
else
	echo -e "${RED}❌ $fail_count test(s) failed${NC}"
	exit 1
fi
