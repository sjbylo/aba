#!/bin/bash
# Test: download/install task ID mismatch race (ADR-008 Finding 5)
#
# Verifies that cli-download-all.sh skips downloading a tool when an
# install task for that tool is already running or completed.
# This prevents two processes from racing on the same tarball.
#
# Scenarios:
#   1. Install task RUNNING  → download should be SKIPPED
#   2. Install task COMPLETED → download should be SKIPPED
#   3. No install task        → download should PROCEED

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
# Uses run_once -A (active = running or completed), same as cli-download-all.sh

check_would_skip() {
	local inst_task="$1"
	run_once -A -i "$inst_task" 2>/dev/null
}

# ── Test 1: No install task → download should PROCEED ──
echo "Test 1: No install task exists"

if check_would_skip "$TASK_INST_OC_MIRROR"; then
	log_fail "Download was skipped but no install task exists"
else
	log_pass "Download proceeds when no install task exists"
fi

# ── Test 2: Install task COMPLETED → download should be SKIPPED ──
echo ""
echo "Test 2: Install task completed (run_once ran to completion)"

TASK_TEST_DONE="test:inst:done"
run_once -i "$TASK_TEST_DONE" -- true
run_once -q -w -i "$TASK_TEST_DONE"

if check_would_skip "$TASK_TEST_DONE"; then
	log_pass "Download skipped when install task completed"
else
	log_fail "Download NOT skipped despite install task being completed"
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

# ── Test 4: Install task FAILED → still skip (tarball may be partial) ──
echo ""
echo "Test 4: Install task failed (non-zero exit)"

TASK_TEST_FAIL="test:inst:fail"
run_once -i "$TASK_TEST_FAIL" -- false
run_once -q -w -i "$TASK_TEST_FAIL" || true

if check_would_skip "$TASK_TEST_FAIL"; then
	log_pass "Download skipped when install task failed (tarball may exist)"
else
	log_fail "Download NOT skipped despite install exit file existing"
fi

# ── Test 5: Full integration — run_once install + check skip ──
echo ""
echo "Test 5: Full run_once integration — start install, verify skip"

TASK_TEST_INST="test:install:widget"
TASK_TEST_DL="test:download:widget"

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

# Now check: would a download for this tool be skipped?
if check_would_skip "$TASK_TEST_INST"; then
	log_pass "Download correctly skipped while install is running"
else
	log_fail "Download NOT skipped while install is running"
fi

# Wait for install to finish
run_once -q -w -i "$TASK_TEST_INST"

# After completion: should still skip (exit file exists now)
if check_would_skip "$TASK_TEST_INST"; then
	log_pass "Download correctly skipped after install completed"
else
	log_fail "Download NOT skipped after install completed"
fi

# ── Test 6: Verify all TASK_INST_* variables resolve correctly ──
echo ""
echo "Test 6: All TASK_INST_* variables are defined"

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

# ── Test 7: TASK_DL_* and TASK_INST_* have different values ──
echo ""
echo "Test 7: Download and install task IDs are distinct"

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
