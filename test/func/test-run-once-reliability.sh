#!/bin/bash
# Test run_once() reliability and crash recovery
# Tests kill scenarios, stale locks, cleanup, and performance
# Note: Not using set -e because we're testing failure scenarios
#set -e
#set -o pipefail  # Disabled - may interfere with run_once output redirection

# Setup test environment
TEST_DIR=$(mktemp -d)
export RUN_ONCE_DIR="$TEST_DIR/runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the functions
source "$ABA_ROOT/scripts/include_all.sh"

# Disable the ERR trap from include_all.sh (interferes with our testing)
trap - ERR

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

# Test result tracking
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

# Cleanup
cleanup() {
	echo
	echo "Cleaning up test environment..."
	run_once -G 2>/dev/null || true
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT

section "Test 1: Basic Functionality"

# Test 1.1: Simple task execution
run_once -i "test:simple" -- bash -c "echo 'test output' && sleep 0.1"
sleep 0.2
if run_once -w -i "test:simple"; then
	test_pass "Simple task execution and wait"
else
	test_fail "Simple task execution and wait"
fi

# Test 1.2: Directory structure
if [[ -d "$RUN_ONCE_DIR/test:simple" ]]; then
	test_pass "Task directory created"
else
	test_fail "Task directory not created"
fi

if [[ -f "$RUN_ONCE_DIR/test:simple/exit" ]] && \
   [[ -f "$RUN_ONCE_DIR/test:simple/log" ]] && \
   [[ -f "$RUN_ONCE_DIR/test:simple/lock" ]]; then
	test_pass "Task files (exit, log, lock) exist"
else
	test_fail "Task files missing"
fi

# Test 1.3: Exit code capture
exit_code=$(cat "$RUN_ONCE_DIR/test:simple/exit")
if [[ "$exit_code" == "0" ]]; then
	test_pass "Exit code captured correctly (0)"
else
	test_fail "Exit code incorrect: $exit_code"
fi

# Test 1.4: Log output capture
log_content=$(cat "$RUN_ONCE_DIR/test:simple/log")
if [[ "$log_content" == "test output" ]]; then
	test_pass "Log output captured correctly"
else
	test_fail "Log output incorrect: $log_content"
fi

section "Test 2: Idempotency (Cached Results)"

# Start a task and verify it doesn't run twice
start_time=$(date +%s)
run_once -i "test:cached" -- bash -c "date +%s > /tmp/test-cached-time && sleep 0.1"
run_once -w -i "test:cached"
first_run=$(cat /tmp/test-cached-time)

# Try to run again - should use cached result
run_once -i "test:cached" -- bash -c "date +%s > /tmp/test-cached-time && sleep 0.1"
run_once -w -i "test:cached"
second_run=$(cat /tmp/test-cached-time)

if [[ "$first_run" == "$second_run" ]]; then
	test_pass "Task result cached (not re-executed)"
else
	test_fail "Task re-executed when it should use cache"
fi
rm -f /tmp/test-cached-time

section "Test 3: Kill Scenarios (Crash Recovery)"

# Test 3.1: Kill task while running (simulates crash)
echo "Starting long-running task and killing it..."
run_once -i "test:kill" -- bash -c "sleep 10 && echo 'should not appear'"
sleep 0.5

# Get PID and kill the process
if [[ -f "$RUN_ONCE_DIR/test:kill/pid" ]]; then
	task_pid=$(cat "$RUN_ONCE_DIR/test:kill/pid")
	if kill -0 "$task_pid" 2>/dev/null; then
		kill -9 "$task_pid" 2>/dev/null || true
		sleep 0.2
		if ! kill -0 "$task_pid" 2>/dev/null; then
			test_pass "Task process killed successfully"
		else
			test_fail "Task process still running after kill -9"
		fi
	else
		test_fail "Task PID not running"
	fi
else
	test_fail "Task PID file not found"
fi

# Test 3.2: Verify auto-recovery from killed task (exit 137)
echo "Testing auto-recovery from killed task (signal termination)..."
# Wait for the subshell to detect kill and write exit code 137
sleep 1

# Check that exit code is 137 (SIGKILL)
exit_code=$(cat "$RUN_ONCE_DIR/test:kill/exit" 2>/dev/null || echo "none")
if [[ "$exit_code" == "137" ]]; then
	test_pass "Exit code 137 (SIGKILL) captured correctly"
else
	test_fail "Exit code incorrect: expected 137, got $exit_code"
fi

# Now try to recover - should auto-restart
if run_once -w -i "test:kill" -- bash -c "echo 'recovered' && sleep 0.1"; then
	# Check if the new task actually ran
	log_content=$(cat "$RUN_ONCE_DIR/test:kill/log" 2>/dev/null || echo "")
	if [[ "$log_content" == *"recovered"* ]]; then
		test_pass "Auto-recovery from SIGKILL successful"
		# Verify final exit code is 0 (not 137)
		final_exit=$(cat "$RUN_ONCE_DIR/test:kill/exit" 2>/dev/null || echo "none")
		if [[ "$final_exit" == "0" ]]; then
			test_pass "Final exit code is 0 after recovery"
		else
			test_fail "Final exit code incorrect: expected 0, got $final_exit"
		fi
	else
		test_fail "Task re-executed but output unexpected: $log_content"
	fi
else
	test_fail "Failed to recover from killed task"
fi

# Test 3.3: Legitimate failures should be CACHED (not retried)
echo "Testing that legitimate failures are cached..."
run_once -w -i "test:legitimate-fail" -- bash -c "echo 'attempt1' && exit 42"
first_exit=$?
first_log=$(cat "$RUN_ONCE_DIR/test:legitimate-fail/log" 2>/dev/null || echo "")

if [[ "$first_exit" == "42" ]]; then
	test_pass "Legitimate failure exit code 42 captured"
else
	test_fail "Expected exit 42, got $first_exit"
fi

# Try to run again with different command - should use cached failure
run_once -w -i "test:legitimate-fail" -- bash -c "echo 'attempt2' && exit 99"
second_exit=$?
second_log=$(cat "$RUN_ONCE_DIR/test:legitimate-fail/log" 2>/dev/null || echo "")

if [[ "$second_exit" == "42" ]] && [[ "$second_log" == "$first_log" ]] && [[ "$second_log" == *"attempt1"* ]]; then
	test_pass "Legitimate failure cached (not re-executed)"
else
	test_fail "Failure should be cached: exit=$second_exit, log=$second_log"
fi

# Test 3.4: SIGTERM (kill without -9) should also trigger recovery
echo "Testing auto-recovery from SIGTERM..."
run_once -i "test:sigterm" -- bash -c "sleep 10"
sleep 0.5
sigterm_pid=$(cat "$RUN_ONCE_DIR/test:sigterm/pid")
kill "$sigterm_pid" 2>/dev/null || true  # Normal kill (SIGTERM)
sleep 0.5

# Should have exit code 143 (128 + 15 for SIGTERM)
sigterm_exit=$(cat "$RUN_ONCE_DIR/test:sigterm/exit" 2>/dev/null || echo "none")
if [[ "$sigterm_exit" == "143" ]]; then
	test_pass "Exit code 143 (SIGTERM) captured correctly"
else
	test_warn "SIGTERM exit code unexpected: expected 143, got $sigterm_exit"
fi

# Try to recover
if run_once -w -i "test:sigterm" -- bash -c "echo 'recovered-sigterm'"; then
	log_content=$(cat "$RUN_ONCE_DIR/test:sigterm/log" 2>/dev/null || echo "")
	if [[ "$log_content" == *"recovered-sigterm"* ]]; then
		test_pass "Auto-recovery from SIGTERM successful"
	else
		test_fail "SIGTERM recovery failed, log: $log_content"
	fi
else
	test_fail "Failed to recover from SIGTERM"
fi

section "Test 4: Concurrent Execution"

# Test 4.1: Multiple waiters for same task
echo "Testing multiple concurrent waiters..."
run_once -i "test:concurrent" -- bash -c "sleep 1 && echo 'done'"
sleep 0.1

# Start 5 waiters simultaneously
pids=()
for i in {1..5}; do
	run_once -w -i "test:concurrent" &
	pids+=($!)
done

# Wait for all waiters
all_success=true
for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		all_success=false
	fi
done

if $all_success; then
	test_pass "Multiple concurrent waiters handled correctly"
else
	test_fail "Some waiters failed"
fi

section "Test 5: TTL (Time-To-Live) Expiration"

# Test 5.1: Task result expires after TTL
run_once -i "test:ttl" -- bash -c "echo 'old' && date +%s > /tmp/test-ttl-time"
run_once -w -i "test:ttl"
first_time=$(cat /tmp/test-ttl-time)

# Modify exit file timestamp to be old
exit_file="$RUN_ONCE_DIR/test:ttl/exit"
touch -t 202301010000 "$exit_file" 2>/dev/null || touch -d "2023-01-01" "$exit_file"

# Run with TTL of 1 second (should be expired)
sleep 1
run_once -i "test:ttl" -t 1 -- bash -c "echo 'new' && date +%s > /tmp/test-ttl-time"
run_once -w -i "test:ttl" -t 1
second_time=$(cat /tmp/test-ttl-time)

if [[ "$first_time" != "$second_time" ]]; then
	test_pass "TTL expiration triggered re-execution"
else
	test_fail "TTL expiration did not trigger re-execution"
fi
rm -f /tmp/test-ttl-time

section "Test 6: Performance Tests"

# Test 6.1: Parallel execution speed
echo "Testing parallel execution of 10 tasks..."
start=$(date +%s%N)
for i in {1..10}; do
	run_once -i "test:perf:$i" -- bash -c "sleep 0.2"
done

# Wait for all
for i in {1..10}; do
	run_once -w -i "test:perf:$i"
done
end=$(date +%s%N)

elapsed=$(( (end - start) / 1000000 )) # Convert to milliseconds
echo "  Elapsed time: ${elapsed}ms"

if [[ $elapsed -lt 500 ]]; then
	test_pass "Parallel execution fast (< 500ms for 10x 200ms tasks)"
else
	test_warn "Parallel execution slower than expected: ${elapsed}ms"
fi

# Test 6.2: Cached result speed
echo "Testing cached result speed..."
run_once -i "test:cache-speed" -- bash -c "sleep 0.5"
run_once -w -i "test:cache-speed"

start=$(date +%s%N)
for i in {1..10}; do
	run_once -w -i "test:cache-speed"
done
end=$(date +%s%N)

elapsed=$(( (end - start) / 1000000 ))
echo "  Elapsed time for 10 cached lookups: ${elapsed}ms"

if [[ $elapsed -lt 100 ]]; then
	test_pass "Cached result lookups fast (< 100ms for 10 lookups)"
else
	test_warn "Cached lookups slower than expected: ${elapsed}ms"
fi

section "Test 7: Cleanup Functions"

# Test 7.1: Individual task reset
run_once -i "test:reset" -- bash -c "echo 'before reset'"
run_once -w -i "test:reset"

if [[ -d "$RUN_ONCE_DIR/test:reset" ]]; then
	test_pass "Task directory exists before reset"
else
	test_fail "Task directory missing before reset"
fi

run_once -r -i "test:reset"

if [[ ! -d "$RUN_ONCE_DIR/test:reset" ]]; then
	test_pass "Task directory removed after reset"
else
	test_fail "Task directory still exists after reset"
fi

# Test 7.2: Global cleanup
run_once -i "test:cleanup1" -- bash -c "echo 'test1'"
run_once -i "test:cleanup2" -- bash -c "echo 'test2'"
run_once -w -i "test:cleanup1"
run_once -w -i "test:cleanup2"

task_count=$(find "$RUN_ONCE_DIR" -maxdepth 1 -type d | wc -l)
if [[ $task_count -gt 2 ]]; then
	test_pass "Multiple task directories exist before global cleanup"
else
	test_warn "Expected more task directories before cleanup"
fi

run_once -G

task_count_after=$(find "$RUN_ONCE_DIR" -maxdepth 1 -type d | wc -l)
if [[ $task_count_after -le 1 ]]; then
	test_pass "All task directories removed after global cleanup"
else
	test_fail "Some task directories remain after global cleanup: $task_count_after"
fi

section "Test 8: Error Handling"

# Test 8.1: Task with non-zero exit code
run_once -i "test:error" -- bash -c "echo 'error output' && exit 42" || true
if ! run_once -w -i "test:error"; then
	exit_code=$(cat "$RUN_ONCE_DIR/test:error/exit")
	if [[ "$exit_code" == "42" ]]; then
		test_pass "Non-zero exit code captured and propagated correctly"
	else
		test_fail "Exit code incorrect: expected 42, got $exit_code"
	fi
else
	test_fail "Task should have failed but reported success"
fi

section "Test Results Summary"

echo
echo "════════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}Passed${NC}: $pass_count"
echo -e "  ${RED}Failed${NC}: $fail_count"
echo "════════════════════════════════════════════════════════════════"

if [[ $fail_count -eq 0 ]]; then
	echo -e "${GREEN}All tests passed!${NC}"
	exit 0
else
	echo -e "${RED}Some tests failed!${NC}"
	exit 1
fi

