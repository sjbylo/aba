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

# Check failed tasks were cleared (exit file removed, identity preserved)
if [[ ! -f "$RUN_ONCE_DIR/test:fail1/exit" ]]; then
	echo "✓ Failed task cleared: test:fail1 (exit file removed)"
else
	echo "✗ FAIL: Failed task exit file still exists: test:fail1"
	exit 1
fi

if [[ ! -f "$RUN_ONCE_DIR/test:fail2/exit" ]]; then
	echo "✓ Failed task cleared: test:fail2 (exit file removed)"
else
	echo "✗ FAIL: Failed task exit file still exists: test:fail2"
	exit 1
fi

# Count active tasks (those with exit files -- should be 2 successful ones)
active_count=0
for d in "$RUN_ONCE_DIR"/test:*/; do
	[[ -f "$d/exit" ]] && active_count=$((active_count + 1))
done
if [[ $active_count -eq 2 ]]; then
	echo "✓ Correct number of active tasks: 2 (only successful tasks have exit files)"
else
	echo "✗ FAIL: Expected 2 active tasks, found $active_count"
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
echo "Test 6: Zombie task cleanup (no exit file, lock free)"
echo "----------------------------------------------"

# Create a zombie: task directory with files but no exit file and no running process
mkdir -p "$RUN_ONCE_DIR/test:zombie"
echo "sleep 999" > "$RUN_ONCE_DIR/test:zombie/cmd"
touch "$RUN_ONCE_DIR/test:zombie/lock"
touch "$RUN_ONCE_DIR/test:zombie/log.out"
touch "$RUN_ONCE_DIR/test:zombie/log.err"
echo "99999" > "$RUN_ONCE_DIR/test:zombie/pid"

# Verify zombie state: no exit file
if [[ ! -f "$RUN_ONCE_DIR/test:zombie/exit" ]]; then
	echo "✓ Zombie created (no exit file)"
else
	echo "✗ FAIL: Exit file should not exist"
	exit 1
fi

# Run -F (should clean the zombie)
if run_once -F; then
	echo "✓ run_once -F succeeded"
else
	echo "✗ FAIL: run_once -F returned non-zero"
	exit 1
fi

# Verify zombie runtime state was cleaned (pid/lock removed)
if [[ ! -f "$RUN_ONCE_DIR/test:zombie/pid" && ! -f "$RUN_ONCE_DIR/test:zombie/lock" ]]; then
	echo "✓ Zombie task runtime state cleaned by -F"
else
	echo "✗ FAIL: Zombie task runtime files still exist after -F"
	ls "$RUN_ONCE_DIR/test:zombie/"
	exit 1
fi

echo ""

##############################################################
echo "Test 7: Zombie cleanup does not affect tasks with held lock"
echo "----------------------------------------------"

# Create a task directory with no exit file but simulate a held lock
mkdir -p "$RUN_ONCE_DIR/test:locked-zombie"
touch "$RUN_ONCE_DIR/test:locked-zombie/cmd"
touch "$RUN_ONCE_DIR/test:locked-zombie/lock"
touch "$RUN_ONCE_DIR/test:locked-zombie/log.out"
touch "$RUN_ONCE_DIR/test:locked-zombie/log.err"

# Hold the lock in a background process (close FD 9 in sleep so kill releases the lock)
(
	exec 9>>"$RUN_ONCE_DIR/test:locked-zombie/lock"
	flock -x 9
	read -t 5 <> <(:) 9>&-
) &
LOCK_PID=$!
sleep 0.3  # Give it time to acquire the lock

# Run -F (should NOT clean this one — lock is held)
run_once -F

if [[ -d "$RUN_ONCE_DIR/test:locked-zombie" ]]; then
	echo "✓ Task with held lock preserved by -F (not a zombie)"
else
	echo "✗ FAIL: Task with held lock was incorrectly cleaned"
	kill $LOCK_PID 2>/dev/null
	exit 1
fi

# Release the lock by killing the holder
kill $LOCK_PID 2>/dev/null
wait $LOCK_PID 2>/dev/null || true
sleep 0.3

# Now -F should clean it (lock is free, no exit file)
run_once -F

if [[ ! -f "$RUN_ONCE_DIR/test:locked-zombie/pid" && ! -f "$RUN_ONCE_DIR/test:locked-zombie/lock" ]]; then
	echo "✓ Task runtime state cleaned after lock released"
else
	echo "✗ FAIL: Task runtime files should have been cleaned after lock release"
	exit 1
fi

echo ""

##############################################################
echo "Test 8: Error message shown on task failure (non-quiet mode)"
echo "----------------------------------------------"

set +e
output=$(run_once -w -i "test:errmsg" -- bash -c 'echo "curl: (22) 503 error" >&2; exit 1' 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
	echo "✓ Task failed as expected (exit $rc)"
else
	echo "✗ FAIL: Task should have failed"
	exit 1
fi

if echo "$output" | grep -q "re-run.*install.*task cache"; then
	echo "✓ Recovery hint shown in output"
else
	echo "✗ FAIL: Recovery hint not found in output"
	echo "  Got: $output"
	exit 1
fi

if echo "$output" | grep -q "503 error"; then
	echo "✓ Stderr content shown in output"
else
	echo "✗ FAIL: Stderr content not found in output"
	echo "  Got: $output"
	exit 1
fi

run_once -r -i "test:errmsg" 2>/dev/null

echo ""

##############################################################
echo "Test 9: Error message suppressed in quiet mode"
echo "----------------------------------------------"

set +e
output=$(run_once -q -w -i "test:errmsg-quiet" -- bash -c 'echo "quiet error" >&2; exit 1' 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
	echo "✓ Task failed as expected (exit $rc)"
else
	echo "✗ FAIL: Task should have failed"
	exit 1
fi

if echo "$output" | grep -q "re-run.*install.*task cache"; then
	echo "✗ FAIL: Recovery hint should be suppressed in quiet mode"
	exit 1
else
	echo "✓ Recovery hint correctly suppressed in quiet mode"
fi

run_once -r -i "test:errmsg-quiet" 2>/dev/null

echo ""

##############################################################
echo "Test 10: Child-only kill — outer subshell handles it"
echo "----------------------------------------------"

# Start a real task
run_once -i "test:child-kill" -- sleep 300
sleep 0.5

INNER_PID=$(cat "$RUN_ONCE_DIR/test:child-kill/pid")
echo "  Inner PID: $INNER_PID"

# Kill only the child; allow time for outer subshell to process wait + write exit file
kill -9 "$INNER_PID" 2>/dev/null
sleep 2

# Outer subshell should have written exit file with signal code
if [[ -f "$RUN_ONCE_DIR/test:child-kill/exit" ]]; then
	exit_code=$(cat "$RUN_ONCE_DIR/test:child-kill/exit")
	echo "✓ Exit file written by outer subshell (exit code: $exit_code)"
else
	echo "✗ FAIL: No exit file — outer subshell didn't catch child death"
	exit 1
fi

# Lock should be free (outer subshell exited)
if ( exec 9>>"$RUN_ONCE_DIR/test:child-kill/lock" && flock -n 9 ); then
	echo "✓ Lock released (outer subshell exited cleanly)"
else
	echo "✗ FAIL: Lock still held"
	exit 1
fi

# -F should clean it (non-zero exit)
run_once -F
if [[ ! -f "$RUN_ONCE_DIR/test:child-kill/exit" ]]; then
	echo "✓ Task cleared by -F (exit file removed)"
else
	echo "✗ FAIL: Task exit file not cleaned"
	exit 1
fi

echo ""

##############################################################
echo "Test 11: Outer-only kill — lock releases immediately"
echo "----------------------------------------------"

# Start a real task
run_once -i "test:outer-kill" -- sleep 300
sleep 0.5

INNER_PID=$(cat "$RUN_ONCE_DIR/test:outer-kill/pid")
OUTER_PID=$(ps -o ppid= -p "$INNER_PID" 2>/dev/null | tr -d ' ')
echo "  Inner PID: $INNER_PID, Outer PID: $OUTER_PID"

# Kill ONLY the outer subshell
kill -9 "$OUTER_PID" 2>/dev/null
sleep 1

# The inner process should still be running (setsid)
if kill -0 "$INNER_PID" 2>/dev/null; then
	echo "✓ Inner process still running (setsid)"
else
	echo "  Info: Inner process already exited"
fi

# KEY TEST: Is the lock free? (Should be free if child doesn't hold it)
if ( exec 9>>"$RUN_ONCE_DIR/test:outer-kill/lock" && flock -n 9 ); then
	echo "✓ Lock is FREE — zombie detected immediately"
	lock_free=true
else
	echo "✗ Lock is HELD — orphaned child holds the lock (delayed zombie)"
	lock_free=false
fi

# No exit file should exist (outer was killed before writing it)
if [[ ! -f "$RUN_ONCE_DIR/test:outer-kill/exit" ]]; then
	echo "✓ No exit file (outer killed before writing)"
else
	echo "  Info: Exit file exists (outer may have written before dying)"
fi

# -F should clean zombie if lock is free
run_once -F
if [[ ! -f "$RUN_ONCE_DIR/test:outer-kill/pid" ]]; then
	echo "✓ Zombie runtime state cleaned by -F"
else
	if [[ "$lock_free" == true ]]; then
		echo "✗ FAIL: Lock was free but -F didn't clean it"
		exit 1
	else
		echo "✗ FAIL: Lock held by orphan — zombie persists until child finishes"
		# Clean up manually
		kill -9 "$INNER_PID" 2>/dev/null
		sleep 0.5
		run_once -F
		exit 1
	fi
fi

# Kill orphaned inner if still running
kill -9 "$INNER_PID" 2>/dev/null || true

echo ""

##############################################################
echo "Test 12: Both killed — zombie cleaned on next -F"
echo "----------------------------------------------"

# Start a real task
run_once -i "test:both-kill" -- sleep 300
sleep 0.5

INNER_PID=$(cat "$RUN_ONCE_DIR/test:both-kill/pid")
OUTER_PID=$(ps -o ppid= -p "$INNER_PID" 2>/dev/null | tr -d ' ')
echo "  Inner PID: $INNER_PID, Outer PID: $OUTER_PID"

# Kill both (simulating machine crash)
kill -9 "$OUTER_PID" 2>/dev/null
sleep 0.3
kill -9 "$INNER_PID" 2>/dev/null
sleep 0.5

# Should be zombie state
if [[ ! -f "$RUN_ONCE_DIR/test:both-kill/exit" ]]; then
	echo "✓ No exit file (zombie state)"
else
	echo "  Info: Exit file exists"
fi

if ( exec 9>>"$RUN_ONCE_DIR/test:both-kill/lock" && flock -n 9 ); then
	echo "✓ Lock is free"
else
	echo "✗ FAIL: Lock still held after both killed"
	exit 1
fi

# -F should clean it
run_once -F
if [[ ! -f "$RUN_ONCE_DIR/test:both-kill/pid" && ! -f "$RUN_ONCE_DIR/test:both-kill/lock" ]]; then
	echo "✓ Zombie runtime state cleaned by -F"
else
	echo "✗ FAIL: Zombie runtime files not cleaned"
	exit 1
fi

# Verify task can be re-run
set +e
run_once -w -i "test:both-kill" -- echo "recovered after crash"
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
	echo "✓ Task re-runs successfully after cleanup"
else
	echo "✗ FAIL: Task failed to re-run (rc=$rc)"
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
echo "  - Zombie tasks (no exit file, lock free) are cleaned"
echo "  - Tasks with held locks are not touched (not zombies)"
echo "  - Error messages show stderr + recovery hint on failure"
echo "  - Quiet mode suppresses recovery hint"
echo "  - Child-only kill: outer subshell catches it and writes exit file"
echo "  - Outer-only kill: lock releases immediately, zombie detected"
echo "  - Both killed: zombie cleaned on next -F, task re-runs"
