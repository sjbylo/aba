#!/bin/bash
# Test: TTL expiry window race between start (background) and wait (foreground)
#
# Reproduces the bug where:
#   1. Task completes and is cached (exit_file exists)
#   2. TTL expires, another run_once -i call cleans up the ENTIRE task directory
#      (rm -rf via _kill_id), then re-creates it and starts fresh
#   3. run_once -w (without command) finds no exit_file, no lock held,
#      no cmd.sh (destroyed by _kill_id) -> ERROR
#
# The fix: always provide a command to run_once -w so it can start the task.

set -euo pipefail

cd "$(dirname "$0")/../.."
export DEBUG_ABA=0
export ABA_ROOT="$(pwd)"

source scripts/include_all.sh

export RUN_ONCE_DIR="/tmp/test-run-once-ttl-race-$$"
rm -rf "$RUN_ONCE_DIR"
mkdir -p "$RUN_ONCE_DIR"

PASSED=0
FAILED=0

pass() { echo "  ✓ PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  ✗ FAIL: $1"; FAILED=$((FAILED + 1)); }

cleanup() {
	rm -rf "$RUN_ONCE_DIR" /tmp/test-race-*-$$
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Reproduce the original bug
#   Simulate what _kill_id does during TTL expiry: rm -rf the task directory,
#   then call run_once -w without a command.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 1: wait without command after directory wipe (original bug) ==="

TASK_ID="test:race:1"
ARTIFACT="/tmp/test-race-1-$$"

run_once -w -i "$TASK_ID" -- bash -c "echo done > $ARTIFACT"
[ -f "$ARTIFACT" ] || { fail "initial run didn't create artifact"; exit 1; }

echo "  Simulating TTL-expiry cleanup (rm -rf task directory)..."
rm -rf "$RUN_ONCE_DIR/$TASK_ID"
mkdir -p "$RUN_ONCE_DIR/$TASK_ID"
rm -f "$ARTIFACT"

if run_once -w -q -i "$TASK_ID" 2>/dev/null; then
	fail "wait without command should have failed after directory wipe"
else
	pass "wait without command correctly fails after directory wipe (rc=$?)"
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Same scenario but WITH a command (the fix)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 2: wait WITH command after directory wipe (the fix) ==="

TASK_ID="test:race:2"
ARTIFACT="/tmp/test-race-2-$$"

run_once -w -i "$TASK_ID" -- bash -c "echo original > $ARTIFACT"
[ -f "$ARTIFACT" ] || { fail "initial run didn't create artifact"; exit 1; }

echo "  Simulating TTL-expiry cleanup..."
rm -rf "$RUN_ONCE_DIR/$TASK_ID"
mkdir -p "$RUN_ONCE_DIR/$TASK_ID"
rm -f "$ARTIFACT"

if run_once -w -i "$TASK_ID" -- bash -c "echo recovered > $ARTIFACT"; then
	if [ -f "$ARTIFACT" ] && grep -q "recovered" "$ARTIFACT"; then
		pass "wait WITH command re-creates artifact after directory wipe"
	else
		fail "wait returned success but artifact missing or wrong"
	fi
else
	fail "wait WITH command should have succeeded"
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Real TTL expiry via run_once -t (end-to-end)
#   Uses a 1-second TTL so we can observe the full cycle.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 3: End-to-end TTL expiry and recovery with command ==="

TASK_ID="test:race:3"
ARTIFACT="/tmp/test-race-3-$$"

run_once -w -i "$TASK_ID" -t 1 -- bash -c "echo v1 > $ARTIFACT"
[ -f "$ARTIFACT" ] || { fail "initial run didn't create artifact"; exit 1; }

echo "  Waiting for TTL to expire (2s)..."
sleep 2

rm -f "$ARTIFACT"

# TTL expired. run_once -i -t will wipe and restart. Then -w should find it.
run_once -i "$TASK_ID" -t 1 -- bash -c "echo v2 > $ARTIFACT"
sleep 1

if run_once -w -i "$TASK_ID" -t 1 -- bash -c "echo v3 > $ARTIFACT"; then
	if [ -f "$ARTIFACT" ]; then
		pass "End-to-end TTL: wait with command succeeds after expiry (content=$(cat "$ARTIFACT"))"
	else
		fail "Artifact missing after end-to-end TTL test"
	fi
else
	fail "End-to-end TTL wait should have succeeded"
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Catalog download pattern (3 tasks, parallel start, sequential wait)
#   Simulates the exact pattern from download-catalogs-start.sh and
#   download-catalogs-wait.sh that triggered the original bug.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 4: Catalog-style parallel start + sequential wait ==="

CATALOGS=(redhat certified community)

for c in "${CATALOGS[@]}"; do
	run_once -i "test:race:cat:$c" -t 1 -- bash -c "sleep 0.3; echo $c > /tmp/test-race-cat-$c-$$"
done

echo "  Waiting for TTL to expire (2s)..."
sleep 2

echo "  Re-starting catalogs (simulating catalogs-download after TTL)..."
for c in "${CATALOGS[@]}"; do
	rm -f "/tmp/test-race-cat-$c-$$"
	run_once -i "test:race:cat:$c" -t 1 -- bash -c "sleep 0.3; echo $c-v2 > /tmp/test-race-cat-$c-$$"
done

echo "  Waiting for all catalogs (simulating catalogs-wait with command)..."
all_ok=1
for c in "${CATALOGS[@]}"; do
	if ! run_once -w -i "test:race:cat:$c" -t 1 -- \
		bash -c "echo $c-v3 > /tmp/test-race-cat-$c-$$"; then
		fail "Catalog wait failed for $c"
		all_ok=""
	fi
done

if [ -n "$all_ok" ]; then
	pass "Catalog pattern: all 3 waits succeeded after TTL expiry"
fi

for c in "${CATALOGS[@]}"; do
	rm -f "/tmp/test-race-cat-$c-$$"
done

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Background start + immediate foreground wait (narrow race)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 5: Background start + immediate wait (narrow race) ==="

TASK_ID="test:race:narrow"
ARTIFACT="/tmp/test-race-narrow-$$"
rm -f "$ARTIFACT"

run_once -i "$TASK_ID" -- bash -c "sleep 1; echo done > $ARTIFACT"

# Wait without command -- run_once reloads from saved cmd.sh
if run_once -w -i "$TASK_ID"; then
	if [ -f "$ARTIFACT" ]; then
		pass "Narrow race: wait completed (content=$(cat "$ARTIFACT"))"
	else
		fail "Narrow race: wait returned success but no artifact"
	fi
else
	fail "Narrow race: wait should have succeeded"
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Self-healing after artifact deletion
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 6: Self-healing re-runs command when validation fails ==="

TASK_ID="test:race:heal"
ARTIFACT="/tmp/test-race-heal-$$"
rm -f "$ARTIFACT"

run_once -w -i "$TASK_ID" -- bash -c "echo original > $ARTIFACT; [ -f $ARTIFACT ]"
[ -f "$ARTIFACT" ] || { fail "initial run didn't create artifact"; exit 1; }

echo "  Deleting artifact to trigger validation failure..."
rm -f "$ARTIFACT"

# Wait with SAME command -- self-healing should re-run and re-create
if run_once -w -i "$TASK_ID" -- bash -c "echo healed > $ARTIFACT; [ -f $ARTIFACT ]"; then
	if [ -f "$ARTIFACT" ]; then
		pass "Self-healing: re-ran command and re-created artifact (content=$(cat "$ARTIFACT"))"
	else
		fail "Self-healing returned success but artifact missing"
	fi
else
	fail "Self-healing should have succeeded"
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: TTL expiry preserves cmd.sh (surgical _kill_id)
#   After the fix, _kill_id removes only runtime state (pid/lock/exit) and
#   rotates logs, but preserves cmd.sh/cmd/cwd. The wait-mode reload path
#   sources cmd.sh and re-executes the task.
#
#   Flow: start task with TTL -> wait for TTL to expire -> call run_once -w
#   with TTL (triggers TTL cleanup) -> wait mode reloads cmd.sh -> succeeds
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 7: TTL expiry preserves cmd.sh (surgical _kill_id) ==="

TASK_ID="test:race:ttl-clobber"
ARTIFACT="/tmp/test-race-ttl-clobber-$$"
rm -f "$ARTIFACT"

# Run a task with short TTL so cmd.sh gets saved
run_once -w -i "$TASK_ID" -t 1 -- bash -c "echo v1 > $ARTIFACT"
[ -f "$ARTIFACT" ] || { fail "initial run didn't create artifact"; exit 1; }

# Verify cmd.sh was saved
[ -f "$RUN_ONCE_DIR/$TASK_ID/cmd.sh" ] || { fail "cmd.sh not saved after initial run"; exit 1; }
echo "  cmd.sh exists after initial run: OK"

echo "  Waiting for TTL to expire (2s)..."
sleep 2

# Now call run_once -w (wait mode) with TTL but WITHOUT a command.
# The TTL check at the top of run_once fires: _kill_id -> rm -rf -> mkdir.
# Then wait mode: no exit_file, lock free, no command => should fail.
rm -f "$ARTIFACT"

if run_once -w -q -i "$TASK_ID" -t 1 2>/dev/null; then
	if [ -f "$RUN_ONCE_DIR/$TASK_ID/cmd.sh" ]; then
		pass "TTL expiry: cmd.sh survived, wait reloaded it and succeeded"
	else
		fail "TTL expiry: wait succeeded but cmd.sh is missing (unexpected)"
	fi
else
	if [ ! -f "$RUN_ONCE_DIR/$TASK_ID/cmd.sh" ]; then
		fail "TTL expiry: cmd.sh destroyed (surgical _kill_id not working)"
	else
		fail "TTL expiry: cmd.sh exists but wait failed (reload not working)"
	fi
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Signal-killed recovery preserves cmd.sh (surgical cleanup)
#   The signal recovery path (exit codes 128-165) now does surgical cleanup
#   instead of rm -rf, preserving cmd.sh for wait-mode reload.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Test 8: Signal-killed recovery preserves cmd.sh (surgical cleanup) ==="

TASK_ID="test:race:signal-clobber"
ARTIFACT="/tmp/test-race-signal-clobber-$$"
rm -f "$ARTIFACT"

# Run a task so cmd.sh gets saved
run_once -w -i "$TASK_ID" -- bash -c "echo v1 > $ARTIFACT"
[ -f "$ARTIFACT" ] || { fail "initial run didn't create artifact"; exit 1; }
[ -f "$RUN_ONCE_DIR/$TASK_ID/cmd.sh" ] || { fail "cmd.sh not saved"; exit 1; }
echo "  cmd.sh exists after initial run: OK"

# Simulate signal kill: write exit code 137 (SIGKILL) to exit file
echo "137" > "$RUN_ONCE_DIR/$TASK_ID/exit"
echo "  Simulated signal kill (exit=137)"

# Now call run_once -w -- the signal recovery path does surgical cleanup
rm -f "$ARTIFACT"
if run_once -w -q -i "$TASK_ID" 2>/dev/null; then
	if [ -f "$RUN_ONCE_DIR/$TASK_ID/cmd.sh" ]; then
		pass "Signal recovery: cmd.sh survived, wait reloaded it and succeeded"
	else
		fail "Signal recovery: wait succeeded but cmd.sh is missing (unexpected)"
	fi
else
	if [ ! -f "$RUN_ONCE_DIR/$TASK_ID/cmd.sh" ]; then
		fail "Signal recovery: cmd.sh destroyed (surgical cleanup not working)"
	else
		fail "Signal recovery: cmd.sh exists but wait failed (reload not working)"
	fi
fi

rm -f "$ARTIFACT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=================================================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=================================================================="

[ "$FAILED" -eq 0 ] || exit 1
