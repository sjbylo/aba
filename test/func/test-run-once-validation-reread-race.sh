#!/bin/bash
# Test: run_once validation re-read race condition (TOCTOU)
#
# Reproduces the bug where 3+ concurrent callers of run_once -w on
# the SAME completed task can get a spurious failure.
#
# The race window:
#   1. Process A reads exit_file at line 1612: exit_code=0
#   2. Process A enters validation (line 1694), acquires lock
#   3. Process A DELETES exit_file (line 1707)
#   4. Process C reads exit_file at line 1612: exit_code=0 (before delete)
#   5. Process C skips wait block (exit_file existed at line 1610)
#   6. Process C RE-READS exit_file at line 1676: FILE GONE → exit_code=1
#   7. Process C returns 1 → SPURIOUS FAILURE
#
# This is the race that causes "Failed to install oc-mirror:" when
# 3 parallel catalog downloads all call ensure_oc_mirror().

set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1

export DEBUG_ABA=
export INFO_ABA=
source scripts/include_all.sh

trap - ERR

PASS=0
FAIL=0
TASK_ID="test:validation-reread-race"
ITERATIONS=50
CONCURRENCY=5

log_pass() { echo -e "\033[0;32mPASS\033[0m: $1"; PASS=$((PASS + 1)); }
log_fail() { echo -e "\033[0;31mFAIL\033[0m: $1"; FAIL=$((FAIL + 1)); }
log_info() { echo -e "\033[0;33mINFO\033[0m: $1"; }

cleanup() {
    run_once -G 2>/dev/null || true
}
trap cleanup EXIT

echo "============================================================"
echo "Test: run_once validation re-read race (TOCTOU)"
echo "============================================================"
echo ""

# ============================================================
# Test 1: Single completed task, multiple concurrent waiters
# ============================================================

log_info "Test 1: $CONCURRENCY concurrent waiters on a completed task ($ITERATIONS iterations)"
log_info "This reproduces the 3-catalog ensure_oc_mirror() race"

failures=0
for i in $(seq 1 $ITERATIONS); do
    # Clean slate
    run_once -G 2>/dev/null || true

    # Create a completed task (fast command that succeeds)
    run_once -w -i "$TASK_ID" -- bash -c "sleep 0.05; echo done"

    # Verify task completed
    if ! run_once -e -i "$TASK_ID" >/dev/null 2>&1; then
        log_fail "Task didn't complete (iteration $i)"
        continue
    fi

    # Now launch N concurrent waiters — all should return 0
    pids=()
    results_dir=$(mktemp -d /tmp/validation-race-XXXXXX)

    for j in $(seq 1 $CONCURRENCY); do
        (
            # Each waiter calls run_once -w with the same task+command
            # This triggers validation, which deletes the exit file temporarily
            rc=0
            run_once -q -w -i "$TASK_ID" -- bash -c "sleep 0.05; echo done" || rc=$?
            echo "$rc" > "$results_dir/result-$j"
        ) &
        pids+=($!)
    done

    # Wait for all
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Check results — ALL should be 0
    iter_ok=true
    for j in $(seq 1 $CONCURRENCY); do
        result=$(cat "$results_dir/result-$j" 2>/dev/null || echo "missing")
        if [[ "$result" != "0" ]]; then
            iter_ok=false
            break
        fi
    done

    if ! $iter_ok; then
        failures=$((failures + 1))
    fi

    rm -rf "$results_dir"
done

if [[ $failures -eq 0 ]]; then
    log_pass "All $ITERATIONS iterations passed — no spurious failures"
else
    log_fail "$failures/$ITERATIONS iterations had spurious failures (race reproduced!)"
fi

# ============================================================
# Test 2: Focused test — simulate the exact ensure_oc_mirror pattern
# ============================================================

log_info "Test 2: Simulate ensure_oc_mirror() pattern (download wait + install wait)"

DL_TASK="test:reread:download"
INST_TASK="test:reread:install"
failures2=0

for i in $(seq 1 $ITERATIONS); do
    run_once -G 2>/dev/null || true

    # Pre-complete both tasks
    run_once -w -i "$DL_TASK" -- bash -c "echo downloaded"
    run_once -w -i "$INST_TASK" -- bash -c "echo installed"

    # Launch concurrent callers mimicking ensure_oc_mirror()
    pids=()
    results_dir=$(mktemp -d /tmp/ensure-race-XXXXXX)

    for j in $(seq 1 $CONCURRENCY); do
        (
            rc=0
            # Mimic ensure_oc_mirror: wait for download, then wait for install
            run_once -q -w -i "$DL_TASK" -- bash -c "echo downloaded" || true
            run_once -q -w -i "$INST_TASK" -- bash -c "echo installed" || rc=$?
            echo "$rc" > "$results_dir/result-$j"
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    iter_ok=true
    for j in $(seq 1 $CONCURRENCY); do
        result=$(cat "$results_dir/result-$j" 2>/dev/null || echo "missing")
        if [[ "$result" != "0" ]]; then
            iter_ok=false
            break
        fi
    done

    if ! $iter_ok; then
        failures2=$((failures2 + 1))
    fi

    rm -rf "$results_dir"
done

if [[ $failures2 -eq 0 ]]; then
    log_pass "All $ITERATIONS iterations passed — ensure_oc_mirror pattern safe"
else
    log_fail "$failures2/$ITERATIONS iterations had spurious failures (race reproduced!)"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================"
echo -e "Results: \033[0;32m${PASS} passed\033[0m, \033[0;31m${FAIL} failed\033[0m"
echo "========================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
