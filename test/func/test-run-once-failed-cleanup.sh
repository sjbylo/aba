#!/bin/bash
# Test run_once -F (global failed task cleanup)
# Verifies that only failed tasks are cleaned up at startup

set -e

# Setup test environment
TEST_DIR=$(mktemp -d)
export RUN_ONCE_DIR="$TEST_DIR/runner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source the functions
source "$ABA_ROOT/scripts/include_all.sh"

# Disable the ERR trap from include_all.sh (interferes with our testing)
trap - ERR

# Cleanup on exit
cleanup() {
	rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

echo "=== Testing run_once -F (Failed Task Cleanup) ==="
echo ""

##############################################################
echo "Test 1: Create successful and failed tasks"
echo "----------------------------------------------"

# Create successful task
if run_once -w -i "test:success1" -- bash -c "echo 'success'; exit 0"; then
	echo "✓ Created successful task: test:success1"
else
	echo "✗ FAIL: Failed to create successful task"
	exit 1
fi

# Create another successful task
if run_once -w -i "test:success2" -- bash -c "echo 'success'; exit 0"; then
	echo "✓ Created successful task: test:success2"
else
	echo "✗ FAIL: Failed to create successful task"
	exit 1
fi

# Create failed task (disable error trap temporarily)
set +e
run_once -w -i "test:fail1" -- bash -c "echo 'failure'; exit 1"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
	echo "✓ Created failed task: test:fail1 (exit code: $rc)"
else
	echo "✗ FAIL: Task should have failed but succeeded"
	exit 1
fi

# Create another failed task
set +e
run_once -w -i "test:fail2" -- bash -c "echo 'failure'; exit 42"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
	echo "✓ Created failed task: test:fail2 (exit code: $rc)"
else
	echo "✗ FAIL: Task should have failed but succeeded"
	exit 1
fi

# Verify all 4 tasks exist
task_count=$(ls -1d "$RUN_ONCE_DIR"/test:* 2>/dev/null | wc -l)
if [[ $task_count -eq 4 ]]; then
	echo "✓ All 4 tasks created (2 successful, 2 failed)"
else
	echo "✗ FAIL: Expected 4 tasks, found $task_count"
	exit 1
fi

echo ""

##############################################################
echo "Test 2: Run 'run_once -F' to clean failed tasks"
echo "----------------------------------------------"

# Run global failed clean
if run_once -F; then
	echo "✓ Executed: run_once -F"
else
	echo "✗ FAIL: run_once -F returned non-zero"
	exit 1
fi

echo ""

##############################################################
echo "Test 3: Verify only failed tasks were deleted"
echo "----------------------------------------------"

# Check successful tasks still exist
if [[ -d "$RUN_ONCE_DIR/test:success1" ]]; then
	echo "✓ Successful task still exists: test:success1"
else
	echo "✗ FAIL: Successful task was incorrectly deleted: test:success1"
	exit 1
fi

if [[ -d "$RUN_ONCE_DIR/test:success2" ]]; then
	echo "✓ Successful task still exists: test:success2"
else
	echo "✗ FAIL: Successful task was incorrectly deleted: test:success2"
	exit 1
fi

# Check failed tasks were deleted
if [[ ! -d "$RUN_ONCE_DIR/test:fail1" ]]; then
	echo "✓ Failed task deleted: test:fail1"
else
	echo "✗ FAIL: Failed task still exists: test:fail1"
	exit 1
fi

if [[ ! -d "$RUN_ONCE_DIR/test:fail2" ]]; then
	echo "✓ Failed task deleted: test:fail2"
else
	echo "✗ FAIL: Failed task still exists: test:fail2"
	exit 1
fi

# Count remaining tasks (should be 2)
remaining_count=$(ls -1d "$RUN_ONCE_DIR"/test:* 2>/dev/null | wc -l)
if [[ $remaining_count -eq 2 ]]; then
	echo "✓ Correct number of tasks remain: 2 (only successful tasks)"
else
	echo "✗ FAIL: Expected 2 remaining tasks, found $remaining_count"
	exit 1
fi

echo ""

##############################################################
echo "Test 4: Verify failed task cleanup is idempotent"
echo "----------------------------------------------"

# Run -F again (should be safe, no errors)
if run_once -F; then
	echo "✓ Second run_once -F succeeded (idempotent)"
else
	echo "✗ FAIL: Second run_once -F failed"
	exit 1
fi

# Verify successful tasks still exist
if [[ -d "$RUN_ONCE_DIR/test:success1" ]] && [[ -d "$RUN_ONCE_DIR/test:success2" ]]; then
	echo "✓ Successful tasks still intact after second cleanup"
else
	echo "✗ FAIL: Successful tasks affected by second cleanup"
	exit 1
fi

echo ""

##############################################################
echo "Test 5: Test with running task"
echo "----------------------------------------------"

# Start a background task that will succeed
run_once -i "test:running" -- bash -c "sleep 0.5; echo 'done'; exit 0" &
sleep 0.1  # Give it time to start

# Run -F while task is running (should not affect running task)
if run_once -F; then
	echo "✓ run_once -F succeeded with running task present"
else
	echo "✗ FAIL: run_once -F failed with running task"
	exit 1
fi

# Wait for running task to complete
sleep 0.6

# Verify it completed successfully
if run_once -w -i "test:running"; then
	echo "✓ Running task completed successfully after -F cleanup"
else
	echo "✗ FAIL: Running task was affected by -F cleanup"
	exit 1
fi

echo ""

##############################################################
echo "=== All Tests Complete ==="
echo ""
echo "✓ Failed task cleanup tests passed!"
echo ""
echo "Summary:"
echo "  - run_once -F deletes only failed tasks"
echo "  - Successful tasks are preserved"
echo "  - Cleanup is idempotent (safe to run multiple times)"
echo "  - Running tasks are not affected"
