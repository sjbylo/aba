#!/bin/bash
# Test: run_once wait-mode start race condition
#
# Reproduces the bug where multiple concurrent processes calling
# run_once -w -i <same-task> -- <command> can race on the lock
# in the wait-mode "start" path (lines 1624-1632 of include_all.sh).
#
# The race window:
#   1. Process A: flock -n 9 succeeds (probe lock acquired)
#   2. Process A: exec 9>&-  <-- RELEASES lock
#   3. Process B: flock -n 9 succeeds (slips through the gap!)
#   4. Process B: exec 9>&-  <-- RELEASES lock
#   5. Process A: _start_task "true" -> re-acquires lock, starts task
#   6. Process B: _start_task "true" -> can't get lock, returns 0
#   7. Process B: wait $! -> returns immediately ($! is unset)
#   8. Process B: reads exit_file -> doesn't exist -> exit_code=1 -> FALSE FAILURE
#
# This is the exact scenario that causes "Failed to install oc-mirror:"
# with no error details during aba bundle tests.

set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

# Disable ERR trap for test
trap - ERR

PASS=0
FAIL=0
export RUN_ONCE_DIR="$HOME/.aba/runner-test-wait-start-race"
TEST_OUTPUT_DIR="/tmp/aba-test-wait-start-race-$$"

cleanup() {
	rm -rf "$RUN_ONCE_DIR" "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT
cleanup
mkdir -p "$RUN_ONCE_DIR" "$TEST_OUTPUT_DIR"

log_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
log_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

TASK_ID="test:wait-start-race"

echo "============================================"
echo "Test: run_once wait-mode start race condition"
echo "============================================"
echo ""

# -------------------------------------------------------------------
# Test 1: Single caller - baseline (should always work)
# -------------------------------------------------------------------
echo "--- Test 1: Single caller baseline ---"
rm -rf "$RUN_ONCE_DIR/$TASK_ID"

if run_once -w -i "$TASK_ID" -- sleep 0.1; then
	log_pass "Single caller succeeds"
else
	log_fail "Single caller failed (unexpected)"
fi

# -------------------------------------------------------------------
# Test 2: Multiple concurrent callers for the SAME task
#          This is the race condition scenario.
#          3 subshells simultaneously call run_once -w -i for the
#          same task. All should succeed (either start or wait).
# -------------------------------------------------------------------
echo ""
echo "--- Test 2: 3 concurrent callers (the race scenario) ---"

# Run this test multiple times to increase chance of hitting the race
ITERATIONS=10
RACE_FAILURES=0

for iter in $(seq 1 $ITERATIONS); do
	# Reset task state
	rm -rf "$RUN_ONCE_DIR/$TASK_ID"

	# The command sleeps 1s to ensure the race window is exercisable
	# (a very fast command would close the window before others arrive)
	CMD="sleep 1"

	# Launch 3 concurrent callers, just like 3 catalog download processes
	for i in 1 2 3; do
		(
			# Each subprocess calls run_once -w -i with the SAME task
			rc=0
			run_once -q -w -i "$TASK_ID" -- $CMD || rc=$?
			echo "$rc" > "$TEST_OUTPUT_DIR/iter${iter}_proc${i}.rc"
		) &
	done

	# Wait for all 3 to complete
	wait

	# Check results: ALL 3 should have rc=0
	all_ok=true
	for i in 1 2 3; do
		rc_file="$TEST_OUTPUT_DIR/iter${iter}_proc${i}.rc"
		if [[ -f "$rc_file" ]]; then
			rc=$(cat "$rc_file")
			if [[ "$rc" != "0" ]]; then
				all_ok=false
				RACE_FAILURES=$((RACE_FAILURES + 1))
				echo "    Iteration $iter: Process $i got rc=$rc (FALSE FAILURE - race hit!)"
				break
			fi
		else
			all_ok=false
			RACE_FAILURES=$((RACE_FAILURES + 1))
			echo "    Iteration $iter: Process $i rc file missing"
			break
		fi
	done
done

if [[ $RACE_FAILURES -eq 0 ]]; then
	log_pass "All $ITERATIONS iterations: 3 concurrent callers all succeeded"
else
	log_fail "$RACE_FAILURES/$ITERATIONS iterations had false failures (RACE CONDITION CONFIRMED)"
fi

# -------------------------------------------------------------------
# Test 3: Simulate the exact catalog/oc-mirror scenario
#          3 "catalog" processes each call ensure-like wrapper
# -------------------------------------------------------------------
echo ""
echo "--- Test 3: Simulated catalog/ensure_oc_mirror scenario ---"

TASK_ID2="test:ensure-race"
ITERATIONS2=10
RACE_FAILURES2=0

for iter in $(seq 1 $ITERATIONS2); do
	rm -rf "$RUN_ONCE_DIR/$TASK_ID2"

	# Simulate ensure_oc_mirror: run_once -w -i with a real command
	for i in 1 2 3; do
		(
			rc=0
			# This mirrors ensure_oc_mirror() exactly:
			# run_once -w -m "msg" -i "$TASK" -- command
			run_once -q -w -m "Installing test tool" -i "$TASK_ID2" -- bash -c 'sleep 0.5; echo done' || rc=$?
			echo "$rc" > "$TEST_OUTPUT_DIR/t3_iter${iter}_proc${i}.rc"
		) &
	done
	wait

	for i in 1 2 3; do
		rc_file="$TEST_OUTPUT_DIR/t3_iter${iter}_proc${i}.rc"
		if [[ -f "$rc_file" ]]; then
			rc=$(cat "$rc_file")
			if [[ "$rc" != "0" ]]; then
				RACE_FAILURES2=$((RACE_FAILURES2 + 1))
				echo "    Iteration $iter: Process $i got rc=$rc (FALSE FAILURE)"
				break
			fi
		else
			RACE_FAILURES2=$((RACE_FAILURES2 + 1))
			break
		fi
	done
done

if [[ $RACE_FAILURES2 -eq 0 ]]; then
	log_pass "All $ITERATIONS2 iterations: simulated ensure scenario succeeded"
else
	log_fail "$RACE_FAILURES2/$ITERATIONS2 iterations had false failures (RACE CONDITION CONFIRMED)"
fi

# -------------------------------------------------------------------
# Test 4: Stress test with 5 concurrent callers, 20 iterations
# -------------------------------------------------------------------
echo ""
echo "--- Test 4: Stress test (5 callers x 20 iterations) ---"

TASK_ID3="test:stress-race"
ITERATIONS3=20
RACE_FAILURES3=0
NUM_PROCS=5

for iter in $(seq 1 $ITERATIONS3); do
	rm -rf "$RUN_ONCE_DIR/$TASK_ID3"

	for i in $(seq 1 $NUM_PROCS); do
		(
			rc=0
			run_once -q -w -i "$TASK_ID3" -- sleep 0.5 || rc=$?
			echo "$rc" > "$TEST_OUTPUT_DIR/t4_iter${iter}_proc${i}.rc"
		) &
	done
	wait

	for i in $(seq 1 $NUM_PROCS); do
		rc_file="$TEST_OUTPUT_DIR/t4_iter${iter}_proc${i}.rc"
		if [[ -f "$rc_file" ]]; then
			rc=$(cat "$rc_file")
			if [[ "$rc" != "0" ]]; then
				RACE_FAILURES3=$((RACE_FAILURES3 + 1))
				echo "    Iteration $iter: Process $i got rc=$rc"
				break
			fi
		else
			RACE_FAILURES3=$((RACE_FAILURES3 + 1))
			break
		fi
	done
done

if [[ $RACE_FAILURES3 -eq 0 ]]; then
	log_pass "All $ITERATIONS3 stress iterations passed"
else
	log_fail "$RACE_FAILURES3/$ITERATIONS3 stress iterations had false failures (RACE CONDITION)"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
	echo ""
	echo "RACE CONDITION BUG CONFIRMED."
	echo "The run_once wait-mode start path has a lock gap"
	echo "between the probe flock and _start_task re-acquisition."
	exit 1
else
	echo ""
	echo "No race detected (may need more iterations or the bug is fixed)."
	exit 0
fi
