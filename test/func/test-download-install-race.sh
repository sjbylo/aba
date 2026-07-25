#!/bin/bash
# Test: download/install task race condition (ADR-008 Finding 5)
#
# Verifies that cli-download-all.sh only skips downloading a tool when an
# install task for that tool is CURRENTLY RUNNING (lock held).
# A previously completed install (possibly for a different version) must NOT
# block a new download — only an actively running install races on the tarball.
#
# Scenarios:
#   1. No install task        → download should PROCEED
#   2. Install task COMPLETED → download should PROCEED (no race)
#   3. Install task RUNNING   → download should be SKIPPED (race risk)
#   4. Install task FAILED    → download should PROCEED (no race)
#   5. Version switch: old install done, new download needed → PROCEED

set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

trap - ERR

PASS=0
FAIL=0
export RUN_ONCE_DIR="$HOME/.aba/runner-test-dl-inst-race"

cleanup() {
	rm -rf "$RUN_ONCE_DIR"
}
trap cleanup EXIT
cleanup
mkdir -p "$RUN_ONCE_DIR"

log_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
log_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "======================================================="
echo "Test: download/install task race condition (ADR-008 H)"
echo "======================================================="
echo ""

# --- Helper: check if cli-download-all.sh would skip a tool ---
# Matches the FIXED logic: skip only if active AND NOT completed (= running)
check_would_skip() {
	local inst_task="$1"
	run_once -A -i "$inst_task" 2>/dev/null && ! run_once -p -i "$inst_task" 2>/dev/null
}

# ── Test 1: No install task → download should PROCEED ──
echo "Test 1: No install task exists"

if check_would_skip "$TASK_INST_OC_MIRROR"; then
	log_fail "Download was skipped but no install task exists"
else
	log_pass "Download proceeds when no install task exists"
fi

# ── Test 2: Install task COMPLETED → download should PROCEED ──
echo ""
echo "Test 2: Install task completed — download should PROCEED (no race)"

TASK_TEST_DONE="test:inst:done"
run_once -i "$TASK_TEST_DONE" -- true
run_once -q -w -i "$TASK_TEST_DONE"

if check_would_skip "$TASK_TEST_DONE"; then
	log_fail "Download skipped despite install being completed (no race risk)"
else
	log_pass "Download proceeds when install task previously completed"
fi

# ── Test 3: Install task RUNNING (lock held) → download should be SKIPPED ──
echo ""
echo "Test 3: Install task running (started via run_once)"

TASK_TEST_SLOW="test:inst:slow"
run_once -i "$TASK_TEST_SLOW" -- sleep 10

sleep 0.3  # give it time to acquire lock

if check_would_skip "$TASK_TEST_SLOW"; then
	log_pass "Download skipped when install task is running"
else
	log_fail "Download NOT skipped despite install task running"
fi

# Clean up the slow task
run_once -r -i "$TASK_TEST_SLOW"

# ── Test 4: Install task FAILED → download should PROCEED ──
echo ""
echo "Test 4: Install task failed — download should PROCEED (no race)"

TASK_TEST_FAIL="test:inst:fail"
run_once -i "$TASK_TEST_FAIL" -- false
run_once -q -w -i "$TASK_TEST_FAIL" || true

if check_would_skip "$TASK_TEST_FAIL"; then
	log_fail "Download skipped despite install having failed (no race risk)"
else
	log_pass "Download proceeds when install task previously failed"
fi

# ── Test 5: Full integration — running install blocks, completed does not ──
echo ""
echo "Test 5: Full run_once integration — running blocks, completed does not"

TASK_TEST_INST="test:install:widget"

# Start a slow "install" task in background
run_once -i "$TASK_TEST_INST" -- sleep 5

# Give it time to acquire lock
sleep 0.3

# Verify the install is running (active but not yet completed)
if run_once -A -i "$TASK_TEST_INST" 2>/dev/null && ! run_once -p -i "$TASK_TEST_INST" 2>/dev/null; then
	log_pass "Install task is running (active but not completed)"
else
	log_fail "Install task not in running state — test setup issue"
fi

# While running: download should be skipped
if check_would_skip "$TASK_TEST_INST"; then
	log_pass "Download correctly skipped while install is running"
else
	log_fail "Download NOT skipped while install is running"
fi

# Wait for install to finish
run_once -q -w -i "$TASK_TEST_INST"

# After completion: download should PROCEED (no more race)
if check_would_skip "$TASK_TEST_INST"; then
	log_fail "Download still skipped after install completed (should proceed)"
else
	log_pass "Download proceeds after install completed"
fi

# ── Test 6: Version switch scenario ──
echo ""
echo "Test 6: Version switch — old install done, new version download needed"

TASK_OLD_INST="test:install:oc-old-ver"

# Simulate old install completed
run_once -i "$TASK_OLD_INST" -- true
run_once -q -w -i "$TASK_OLD_INST"

# Verify it completed
if run_once -p -i "$TASK_OLD_INST" 2>/dev/null; then
	log_pass "Old install task is completed (simulating version switch)"
else
	log_fail "Old install task setup failed"
fi

# A new download for a different version should NOT be blocked
if check_would_skip "$TASK_OLD_INST"; then
	log_fail "New version download blocked by old completed install"
else
	log_pass "New version download proceeds despite old install being done"
fi

# ── Test 7: Verify all TASK_INST_* variables resolve correctly ──
echo ""
echo "Test 7: All TASK_INST_* variables are defined"

all_defined=true
for var in TASK_INST_OC_MIRROR TASK_INST_OC TASK_INST_OPENSHIFT_INSTALL \
           TASK_INST_GOVC TASK_INST_BUTANE TASK_INST_QUAY_REG; do
	if [[ -z "${!var:-}" ]]; then
		log_fail "$var is not defined"
		all_defined=false
	fi
done
if $all_defined; then
	log_pass "All TASK_INST_* variables are defined"
fi

# ── Test 8: TASK_DL_* and TASK_INST_* have different values ──
echo ""
echo "Test 8: Download and install task IDs are distinct"

distinct=true
for pair in \
	"TASK_DL_OC_MIRROR:TASK_INST_OC_MIRROR" \
	"TASK_DL_GOVC:TASK_INST_GOVC" \
	"TASK_DL_BUTANE:TASK_INST_BUTANE" \
	"TASK_DL_QUAY_REG:TASK_INST_QUAY_REG"; do
	dl_var="${pair%%:*}"
	inst_var="${pair##*:}"
	if [[ "${!dl_var}" == "${!inst_var}" ]]; then
		log_fail "$dl_var and $inst_var have same value: ${!dl_var}"
		distinct=false
	fi
done
if $distinct; then
	log_pass "All DL/INST task ID pairs are distinct"
fi

# ── Summary ──
echo ""
echo "======================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "======================================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
