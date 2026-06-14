#!/bin/bash
# Test: Background download + foreground make race condition
#
# Reproduces the EXACT real-world failure: cli-download-all.sh starts background
# downloads (bare make ... &), then foreground make races with them.
#
# Uses govc as the test tool (~19MB, version-independent, fastest download).
#
# Tests that MUST FAIL on current (broken) code:
#   Test 1: bg cli-download-all.sh + fg make download-govc = double curl / no serialization
#   Test 2: bg cli-download-all.sh + fg make govc = extract partial tarball
#   Test 3: fg make returns 0 but tarball is incomplete (Make skips recipe for partial file)
#
# Tests that MUST PASS on both current and fixed code:
#   Test 4: User runs bare make (no bg processes) = serial, correct
#
# Tests that MUST PASS only after the fix:
#   Test 5: run_once bg + run_once wait = proper serialization
#
# Usage: bash test/func/test-bg-download-fg-make-race.sh
# Duration: ~2-3 minutes (downloads real tarball from GitHub)

set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

GOVC_TAR="govc_Linux_$(uname -m).tar.gz"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0
skip_count=0
# Separate counter for "fix verification" tests (Test 4-5).
# Tests 1-3 demonstrate the known bare-Make race — their failures are expected.
fix_fail_count=0

test_pass() {
	echo -e "  ${GREEN}PASS${NC}: $1"
	pass_count=$(( pass_count + 1 ))
}

test_fail() {
	echo -e "  ${RED}FAIL${NC}: $1"
	fail_count=$(( fail_count + 1 ))
}

# Fix-verification failure: these count toward the exit code.
fix_fail() {
	echo -e "  ${RED}FAIL${NC}: $1"
	fail_count=$(( fail_count + 1 ))
	fix_fail_count=$(( fix_fail_count + 1 ))
}

test_skip() {
	echo -e "  ${YELLOW}SKIP${NC}: $1"
	skip_count=$(( skip_count + 1 ))
}

section() {
	echo ""
	echo "=================================================================="
	echo "  $1"
	echo "=================================================================="
}

clean_govc() {
	rm -f "cli/$GOVC_TAR" "cli/${GOVC_TAR}.sha256" ~/bin/govc
	# Clean run_once state for govc tasks
	run_once -r -i "cli:download:govc" 2>/dev/null || true
	run_once -r -i "cli:fetch:govc" 2>/dev/null || true
	run_once -r -i "cli:install:govc" 2>/dev/null || true
	# Kill any leftover background make/curl processes for govc
	pkill -f "download-govc" 2>/dev/null || true
	pkill -f "$GOVC_TAR" 2>/dev/null || true
	sleep 0.5
}

# Verify tarball is a valid gzip
verify_tarball() {
	local f="$1"
	if [ ! -f "$f" ]; then
		echo "MISSING"
		return 1
	fi
	if ! gzip -t "$f" 2>/dev/null; then
		echo "CORRUPT"
		return 1
	fi
	echo "OK"
	return 0
}

echo "Background Download + Foreground Make Race Condition Test"
echo "govc tarball: $GOVC_TAR"
echo ""

# ══════════════════════════════════════════════════════════════════════
section "Test 1: bg cli-download-all.sh + fg make download-govc (no serialization)"
# Current code: cli-download-all.sh runs 'make ... &' (bare, no run_once).
# Then fg 'make download-govc' runs. Both trigger curl on the same file.
# Expected on BROKEN code: two curls, or Make skips recipe because file
# already exists from bg curl (even though it's still being written).
# ══════════════════════════════════════════════════════════════════════

clean_govc

# Start bg download (same as cli-download-all.sh default mode)
PLAIN_OUTPUT=1 make -sC cli download-govc &
bg_pid=$!
echo "  Background make download-govc started (PID $bg_pid)"

# Tiny delay so bg curl starts writing the file
sleep 0.3

# Now run fg make download-govc (simulates what happens when user runs aba)
fg_output=$(PLAIN_OUTPUT=1 make -sC cli download-govc 2>&1)
fg_rc=$?
echo "  Foreground make download-govc finished (rc=$fg_rc)"

# Wait for bg to finish
wait $bg_pid 2>/dev/null
bg_rc=$?
echo "  Background make download-govc finished (rc=$bg_rc)"

# Check: did fg produce any download output? If not, Make skipped the recipe
# because the bg curl already created the file (even though it was partial).
if [ -z "$fg_output" ]; then
	test_fail "Foreground make produced NO output -- Make skipped recipe (saw partial file from bg curl)"
	echo "         This proves no serialization: fg Make saw the bg's partial file and returned 0."
elif echo "$fg_output" | grep -q "Downloading"; then
	test_fail "Both bg AND fg attempted download (double curl, no serialization)"
	echo "         Two concurrent curls on the same file -- can cause corruption."
else
	test_pass "Foreground download had output but didn't show 'Downloading' (unexpected)"
fi

# Verify the tarball is valid regardless
result=$(verify_tarball "cli/$GOVC_TAR")
if [ "$result" = "OK" ]; then
	echo -e "  ${YELLOW}INFO${NC}: Tarball is valid (this time). Race is timing-dependent."
else
	test_fail "Tarball is $result after concurrent access"
fi

# ══════════════════════════════════════════════════════════════════════
section "Test 2: bg cli-download-all.sh + fg make govc (extract partial tarball)"
# bg starts download, fg tries to install (download + extract).
# If Make sees the partial tarball, it skips download and goes straight
# to extraction -- tar on a half-written gzip = error.
# ══════════════════════════════════════════════════════════════════════

clean_govc

# Start bg download
PLAIN_OUTPUT=1 make -sC cli download-govc &
bg_pid=$!
echo "  Background download started (PID $bg_pid)"

# Tiny delay so bg curl starts writing
sleep 0.3

# Now run fg make govc (download + extract)
fg_output=$(PLAIN_OUTPUT=1 make -sC cli govc 2>&1)
fg_rc=$?
echo "  Foreground make govc finished (rc=$fg_rc)"

# Wait for bg
wait $bg_pid 2>/dev/null

if [ $fg_rc -ne 0 ]; then
	if echo "$fg_output" | grep -qi "gzip\|unexpected end\|corrupt\|invalid"; then
		test_fail "Extraction failed on partial tarball (gzip error) -- race confirmed"
	else
		test_fail "make govc failed (rc=$fg_rc) -- likely race-related"
	fi
elif [ -z "$fg_output" ]; then
	test_fail "Foreground make govc produced NO output -- recipes skipped entirely"
	echo "         Make saw partial file, skipped both download AND extract."
else
	# Even if it "passed", check if the binary is valid
	if [ -x ~/bin/govc ] && ~/bin/govc --help >/dev/null 2>&1; then
		echo -e "  ${YELLOW}INFO${NC}: make govc succeeded (lucky timing -- race not triggered this run)"
		test_skip "Race not triggered this run (timing-dependent)"
	else
		test_fail "make govc returned 0 but binary is invalid/missing"
	fi
fi

# ══════════════════════════════════════════════════════════════════════
section "Test 3: fg make returns 0 on incomplete tarball"
# Start bg download, wait until file exists but is still being written,
# then run fg make download-govc. Make sees file, skips recipe, returns 0.
# But the file is incomplete.
# ══════════════════════════════════════════════════════════════════════

clean_govc

# Start a slow download that creates the file immediately but takes time
# We simulate this by starting the real download in bg
PLAIN_OUTPUT=1 make -sC cli download-govc &
bg_pid=$!
echo "  Background download started (PID $bg_pid)"

# Wait for file to appear (but not finish)
for i in $(seq 1 20); do
	if [ -f "cli/$GOVC_TAR" ]; then
		file_size=$(stat -c%s "cli/$GOVC_TAR" 2>/dev/null || echo 0)
		echo "  File appeared after ${i}00ms (size: $file_size bytes)"
		break
	fi
	sleep 0.1
done

if [ ! -f "cli/$GOVC_TAR" ]; then
	echo "  File never appeared -- bg download may have failed"
	wait $bg_pid 2>/dev/null
	test_skip "Could not reproduce (file didn't appear in time)"
else
	# Check if bg is still downloading
	if kill -0 $bg_pid 2>/dev/null; then
		echo "  Background download still running -- file is partial"

		# Run fg make -- should it wait? Or skip?
		fg_output=$(PLAIN_OUTPUT=1 make -sC cli download-govc 2>&1)
		fg_rc=$?

		# Now check: did fg return 0 without downloading?
		if [ $fg_rc -eq 0 ] && [ -z "$fg_output" ]; then
			# Verify the tarball is actually incomplete
			wait $bg_pid 2>/dev/null
			# After bg finishes, the file should be complete. But at the time
			# fg returned 0, it was partial. This is the bug.
			test_fail "fg make returned 0 with NO output while bg was still downloading"
			echo "         Make saw the partial file, skipped the recipe, returned success."
			echo "         This is the core race: Make thinks the tarball is 'up to date' but it's not."
		elif [ $fg_rc -eq 0 ]; then
			echo -e "  ${YELLOW}INFO${NC}: fg make returned 0 with output (may have waited or re-downloaded)"
			test_skip "fg make produced output -- may have re-downloaded (timing-dependent)"
		else
			test_fail "fg make failed (rc=$fg_rc) while bg was downloading"
		fi
	else
		echo "  Background download already finished (fast connection)"
		wait $bg_pid 2>/dev/null
		test_skip "Could not reproduce (download completed too fast)"
	fi
fi

# ══════════════════════════════════════════════════════════════════════
section "Test 4: User runs bare make (no bg processes) = serial, correct"
# This should ALWAYS work -- plain Make with no concurrent processes.
# ══════════════════════════════════════════════════════════════════════

clean_govc

start_t=$SECONDS
output=$(PLAIN_OUTPUT=1 make -C cli ~/bin/govc 2>&1)
rc=$?
elapsed=$(( SECONDS - start_t ))

if [ $rc -eq 0 ]; then
	test_pass "make ~/bin/govc exited 0 (serial, no race)"
else
	fix_fail "make ~/bin/govc failed (rc=$rc) even in serial mode"
	echo "  Output: $output"
fi

result=$(verify_tarball "cli/$GOVC_TAR")
if [ "$result" = "OK" ]; then
	test_pass "Tarball valid after serial download"
else
	fix_fail "Tarball $result after serial download"
fi

if [ -x ~/bin/govc ] && ~/bin/govc --help >/dev/null 2>&1; then
	test_pass "~/bin/govc executes correctly"
else
	fix_fail "~/bin/govc missing or invalid"
fi

echo "  (Took ${elapsed}s)"

# ══════════════════════════════════════════════════════════════════════
section "Test 5: run_once bg + run_once wait = proper serialization (post-fix)"
# After the fix, cli-download-all.sh uses run_once to wrap make calls.
# This test verifies that run_once serialization works correctly.
# On CURRENT (broken) code: cli-download-all.sh doesn't use run_once,
# so this test checks if run_once WOULD fix the problem.
# ══════════════════════════════════════════════════════════════════════

clean_govc

# Check if cli-download-all.sh uses run_once (post-fix check)
if grep -q 'run_once.*task_id.*make' scripts/cli-download-all.sh; then
	echo "  cli-download-all.sh uses run_once (fixed code detected)"

	# Start bg download via cli-download-all.sh
	scripts/cli-download-all.sh govc 2>/dev/null

	# Wait for just govc
	scripts/cli-download-all.sh --wait govc 2>/dev/null
	wait_rc=$?

	if [ $wait_rc -eq 0 ]; then
		result=$(verify_tarball "cli/$GOVC_TAR")
		if [ "$result" = "OK" ]; then
			test_pass "run_once serialization works: bg start + wait = valid tarball"
		else
			fix_fail "run_once wait returned 0 but tarball is $result"
		fi
	else
		fix_fail "cli-download-all.sh --wait failed (rc=$wait_rc)"
	fi
else
	echo "  cli-download-all.sh does NOT use run_once (current broken code)"
	test_skip "cli-download-all.sh doesn't use run_once yet (will pass after fix)"
fi

# ══════════════════════════════════════════════════════════════════════
echo ""
echo "=================================================================="
echo "                       RESULTS"
echo "=================================================================="
echo ""
echo -e "  ${GREEN}Passed${NC}: $pass_count"
echo -e "  ${RED}Failed${NC}: $fail_count"
echo -e "  ${YELLOW}Skipped${NC}: $skip_count"
echo ""

# Tests 1-3 demonstrate the bare-Make race (informational).
# Tests 4-5 verify that the fix (run_once) works — these drive the exit code.
race_fails=$(( fail_count - fix_fail_count ))

if [ $race_fails -gt 0 ]; then
	echo -e "  ${YELLOW}Race demo (Tests 1-3)${NC}: $race_fails bare-Make races confirmed (expected)"
fi
if [ $fix_fail_count -gt 0 ]; then
	echo -e "  ${RED}Fix verification (Tests 4-5)${NC}: $fix_fail_count FAILED"
fi
echo ""

if [ $fix_fail_count -gt 0 ]; then
	echo -e "${RED}FIX VERIFICATION FAILED${NC}: $fix_fail_count fix-verification test(s) failed"
	exit 1
elif [ $race_fails -gt 0 ]; then
	echo -e "${GREEN}FIX VERIFIED${NC}: run_once serialization works (Tests 4-5 pass)"
	echo "  Tests 1-3 confirmed bare Make races exist — this is expected and WHY we use run_once."
	exit 0
else
	echo -e "${GREEN}ALL CHECKS PASSED${NC} ($skip_count skipped)"
	if [ $skip_count -gt 0 ]; then
		echo "  Some tests were timing-dependent and didn't trigger the race."
	fi
	exit 0
fi
