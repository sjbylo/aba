#!/bin/bash
# Test: TUI progress dialog — integration test using the demo/stub script
#
# Exercises:
#   1.  Progress dialog renders all steps (PLAN→START→DONE events)
#   2.  Completion dialog: "All steps completed" with step status list
#   3.  Output view: press "Output" button, verify pager opens
#   4.  Output pager: content visible, navigation hint present
#   5.  Return from output: press Q to quit pager, back to success dialog
#   6.  Done button: dismiss success dialog, return to menu
#   7.  Live output toggle: press Space during progress, verify live output
#   8.  Quit during progress: press Q/ESC, verify clean exit
#
# Uses the built-in progress demo script (devel/tui-progress-demo/) when
# available, falling back to a synthetic test stub.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Progress Integration Test ==="
echo "  Host: $_TUI_HOST"
echo ""

# Kill any stale sessions/processes from previous progress / TUI runs.
# A leftover abatui (e.g. Confirm Exit) trips the stray-process assert at end.
$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
$_TUI_SSH "pkill -9 -f aba-progress-wrapper 2>/dev/null; pkill -9 -f aba-progress-test 2>/dev/null; true"
$_TUI_SSH "pkill -9 -f abatui2 2>/dev/null; true"
sleep 0.5

tui_deploy_code
echo ""

# Create a quick-running progress test script on the remote host
# This script emits real PLAN/START/DONE events through the FIFO.
$_TUI_SSH "cat > /tmp/aba-progress-test.sh" <<'SCRIPT'
#!/bin/bash
cd ~/aba
source scripts/include_all.sh 2>/dev/null

# Emit progress events like a real ABA command
aba_progress "PLAN|step1|Install packages|1"
aba_progress "PLAN|step2|Download files|2"
aba_progress "PLAN|step3|Apply config|1"

aba_progress "START|step1"
sleep 1
echo "[ABA] Installing packages..."
echo "[ABA] Package installed: openshift-install"
aba_progress "DONE|step1"

aba_progress "START|step2"
sleep 1
echo "[ABA] Downloading mirror images..."
echo "[ABA] Downloaded: 15 of 15 images"
aba_progress "DONE|step2"

aba_progress "START|step3"
sleep 1
echo "[ABA] Applying configuration..."
echo "[ABA] Configuration applied successfully"
aba_progress "DONE|step3"

echo ""
echo "[ABA] All operations complete."
SCRIPT
$_TUI_SSH "chmod +x /tmp/aba-progress-test.sh"

# Create a failing variant for error path testing
$_TUI_SSH "cat > /tmp/aba-progress-test-fail.sh" <<'SCRIPT'
#!/bin/bash
cd ~/aba
source scripts/include_all.sh 2>/dev/null

aba_progress "PLAN|step1|Validate config|1"
aba_progress "PLAN|step2|Apply changes|1"

aba_progress "START|step1"
sleep 1
echo "[ABA] Validating..."
aba_progress "DONE|step1"

aba_progress "START|step2"
sleep 1
echo "[ABA] Applying changes..."
echo "[ABA] Error: connection refused"
aba_progress "ERROR|step2|Connection refused: registry.example.com:8443"
aba_progress "NEXT|Check that the mirror registry is running"
aba_progress "FAIL|step2"
exit 1
SCRIPT
$_TUI_SSH "chmod +x /tmp/aba-progress-test-fail.sh"

echo "  Test scripts deployed"

# ============================================================================
# Create a wrapper that calls _exec_with_progress directly
# ============================================================================
$_TUI_SSH "cat > /tmp/aba-progress-wrapper.sh" <<'WRAPPER'
#!/bin/bash
# Minimal TUI wrapper that sources the progress engine and runs a test command.
cd ~/aba
export ABA_ROOT="$HOME/aba"
export DIALOGRC="$HOME/aba/tui/v2/.dialogrc"

# dlg() closes ABA_TUI_FLOCK_FD — provide a dummy so {fd}>&- doesn't fail
exec 99>/dev/null
export ABA_TUI_FLOCK_FD=99

_TUI_TMP=$(mktemp)
source scripts/include_all.sh 2>/dev/null
source tui/v2/tui-lib.sh 2>/dev/null
source tui/v2/tui-progress.sh 2>/dev/null

_TUI_MODE="CONNO"
_cmd="$1"
_title="${2:-Test Progress}"

_exec_with_progress "$_cmd" "$_title"
_rc=$?
rm -f "$_TUI_TMP"
exit $_rc
WRAPPER
$_TUI_SSH "chmod +x /tmp/aba-progress-wrapper.sh"

# ============================================================================
# Test A: Successful progress — full lifecycle
# ============================================================================
echo ""
echo "--- A. Successful progress lifecycle ---"

# Launch in tmux
$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
$_TUI_SSH "tmux new-session -d -s $_TUI_SESSION -x $_TUI_WIDTH -y $_TUI_HEIGHT \
	'bash /tmp/aba-progress-wrapper.sh \"bash /tmp/aba-progress-test.sh\" \"Test Progress\"; sleep 30'"
sleep 3

# A1: Progress dialog should appear with step names
tui_assert_appears "Test Progress\|progress\|Install packages" "Progress dialog appeared" 10
tui_screenshot "pi-a1-progress"

# A2: Wait for completion (all steps done)
tui_assert_appears "All steps completed\|Succeeded\|Done\|Output" "Progress completed" 30
tui_screenshot "pi-a2-completed"

_scr=$(tui_capture)

# A3: Verify all steps show as Succeeded
if echo "$_scr" | grep -qi "Install packages.*Succeeded"; then
	echo "  ✓ PASS: Step 1 (Install packages) shows Succeeded"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Step 1 status not clearly visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_scr" | grep -qi "Download files.*Succeeded"; then
	echo "  ✓ PASS: Step 2 (Download files) shows Succeeded"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Step 2 status not clearly visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_scr" | grep -qi "Apply config.*Succeeded"; then
	echo "  ✓ PASS: Step 3 (Apply config) shows Succeeded"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Step 3 status not clearly visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# A4: Done and Output buttons present
tui_assert_contains "Done" "Done button present"
tui_assert_contains "Output" "Output button present"

# A5: Press Output to view the pager
tui_press_button "Output" 2>/dev/null || { tui_keys Tab; sleep 0.3; tui_keys Enter; }
sleep 2
tui_screenshot "pi-a5-output"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "ABA\|Installing\|Downloaded\|Configuration\|complete"; then
	echo "  ✓ PASS: Output pager shows command output"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Output pager content not visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# A6: Check for navigation hint (scroll instructions)
if echo "$_scr" | grep -qi "scroll\|PgUp\|PgDn\|press Q\|quit"; then
	echo "  ✓ PASS: Output pager shows navigation hint"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Navigation hint not visible (may be off-screen)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# A7: Test scrolling in pager (PgUp then PgDn)
tui_keys "g"  # go to top in less
sleep 1
tui_screenshot "pi-a7-top"
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Executing"; then
	echo "  ✓ PASS: Pager scroll to top shows command header"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Top of output not clearly showing command header"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# A8: Quit pager, return to success dialog
tui_keys "q"
sleep 2
tui_screenshot "pi-a8-back"
tui_assert_contains "Done\|All steps" "Back at success dialog after pager"

# A9: Dismiss with Done
tui_keys Enter
sleep 2

# ============================================================================
# Test B: Failed progress — error path
# ============================================================================
echo ""
echo "--- B. Failed progress error path ---"

$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
$_TUI_SSH "tmux new-session -d -s $_TUI_SESSION -x $_TUI_WIDTH -y $_TUI_HEIGHT \
	'bash /tmp/aba-progress-wrapper.sh \"bash /tmp/aba-progress-test-fail.sh\" \"Test Fail\"; sleep 30'"
sleep 3

# B1: Wait for error outcome
tui_assert_appears "Error\|Failed\|error\|failed\|View Output\|Retry" "Error dialog appeared" 20
tui_screenshot "pi-b1-error"

_scr=$(tui_capture)

# B2: Verify error details are shown
if echo "$_scr" | grep -qi "Connection refused\|Apply changes.*Failed\|Failed"; then
	echo "  ✓ PASS: Error details shown"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Specific error details not visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# B3: Verify "next steps" shown
if echo "$_scr" | grep -qi "mirror registry\|next step\|Check"; then
	echo "  ✓ PASS: Next steps suggestion shown"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Next steps not visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# B4: View Output and Retry buttons present
tui_assert_contains "View Output\|Output" "View Output button on error"
tui_assert_contains "Retry" "Retry button on error"

# B5: View Output is the Help button (rightmost) — NOT the default (Dismiss).
# Pager proof: navigation hint, Executing header, [ABA] lines, or connection refused.
# Reject still-on-Error-dialog (Dismiss/Retry row or title).
tui_press_button "View Output" 2>/dev/null || { tui_keys Tab Tab; sleep 0.3; tui_keys Enter; }
sleep 2
tui_screenshot "pi-b5-error-output"
_scr=$(tui_capture)
if echo "$_scr" | grep -qiE '<[[:space:]]*Dismiss[[:space:]]*>' && \
   echo "$_scr" | grep -qiE '<[[:space:]]*Retry[[:space:]]*>|<[[:space:]]*View Output'; then
	echo "  ✗ FAIL: Still on Error dialog — View Output did not open pager"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
elif echo "$_scr" | grep -qiE 'Press Q to quit|Executing:|connection refused|\[ABA\] (Error|Validating|Applying)|output\.log'; then
	echo "  ✓ PASS: Error output pager shows error details"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Error output content not clearly visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# B6: Quit pager
tui_keys "q"
sleep 2

# B7: Dismiss error (press OK/Cancel to exit, not Retry)
tui_press_button "OK" 2>/dev/null || tui_keys Escape
sleep 2

# ============================================================================
# Test C: Live output toggle during progress
# ============================================================================
echo ""
echo "--- C. Live output toggle during progress ---"

# Create a slower test script to allow pressing Space during execution
$_TUI_SSH "cat > /tmp/aba-progress-test-slow.sh" <<'SLOWSCRIPT'
#!/bin/bash
cd ~/aba
source scripts/include_all.sh 2>/dev/null

aba_progress "PLAN|step1|First step|1"
aba_progress "PLAN|step2|Second step (slow)|3"
aba_progress "PLAN|step3|Final step|1"

aba_progress "START|step1"
sleep 1
echo "[ABA] Step 1 running..."
aba_progress "DONE|step1"

aba_progress "START|step2"
echo "[ABA] Step 2 running (this takes a while)..."
sleep 8
echo "[ABA] Step 2 still going..."
sleep 2
echo "[ABA] Step 2 done."
aba_progress "DONE|step2"

aba_progress "START|step3"
sleep 1
echo "[ABA] Final step..."
aba_progress "DONE|step3"
echo "[ABA] All done."
SLOWSCRIPT
$_TUI_SSH "chmod +x /tmp/aba-progress-test-slow.sh"

$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
$_TUI_SSH "tmux new-session -d -s $_TUI_SESSION -x $_TUI_WIDTH -y $_TUI_HEIGHT \
	'bash /tmp/aba-progress-wrapper.sh \"bash /tmp/aba-progress-test-slow.sh\" \"Test Live\"; sleep 30'"
sleep 5

# C1: Verify progress is showing
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "First step\|Second step\|Progress\|Test Live"; then
	echo "  ✓ PASS: Progress dialog running"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Progress dialog state unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_screenshot "pi-c1-live-progress"

# C2: Press Space to switch to live output view (spam — dialog redraw races).
_live_ok=false
for _try in 1 2 3 4 5 6 7 8; do
	tui_keys Space
	sleep 0.4
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Live Output\|press Space to return"; then
		_live_ok=true
		break
	fi
done
tui_screenshot "pi-c2-live-output"
# Require Live Output header — bare "ABA" matches the backtitle false-PASS.
if [[ "$_live_ok" == "true" ]]; then
	echo "  ✓ PASS: Live output view opened"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Live output view unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# C3: Only Space returns from live output (Enter is ignored by design).
_back_ok=false
for _try in 1 2 3 4 5 6; do
	tui_keys Space
	sleep 0.5
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Live Output\|press Space to return"; then
		continue
	fi
	if echo "$_scr" | grep -qi "In Progress\|Quit (Q\|All steps completed\|Succeeded"; then
		_back_ok=true
		break
	fi
done
tui_screenshot "pi-c3-back-to-progress"
if [[ "$_back_ok" == "true" ]]; then
	echo "  ✓ PASS: Returned to progress/completion dialog"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Return from live output unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# C4: Wait for completion
tui_assert_appears "All steps completed\|Done\|Output" "Slow test completed" 30
tui_screenshot "pi-c4-slow-done"

# Dismiss
tui_keys Enter; sleep 2

# ============================================================================
# Test D: Quit during progress (ESC/Q) — real key press, not a code-review soft PASS
# ============================================================================
echo ""
echo "--- D. Quit during progress ---"

# Title must NOT contain "Quit" — that string is on the live dialog button
# and previously false-PASSed the acknowledgment assert.
$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
$_TUI_SSH "tmux new-session -d -s $_TUI_SESSION -x $_TUI_WIDTH -y $_TUI_HEIGHT \
	'bash /tmp/aba-progress-wrapper.sh \"bash /tmp/aba-progress-test-slow.sh\" \"Test Abort\"; sleep 30'"
sleep 4
_scr=$(tui_capture)
if ! echo "$_scr" | grep -qi "First step\|Second step\|Progress\|Test Abort\|In Progress"; then
	echo "  ✗ FAIL: Quit test — progress dialog did not start"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "pi-d1-no-progress"
else
	tui_screenshot "pi-d1-before-quit"
	# dialog redraw races steal single keypresses — spam q then Escape.
	_quit_ok=false
	for _try in 1 2 3 4 5 6 7 8; do
		tui_keys q
		sleep 0.35
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Stopped before all steps\|: Stopped\|Aborted" || \
		   ! echo "$_scr" | grep -qi "In Progress\|Test Abort"; then
			_quit_ok=true
			break
		fi
	done
	if [[ "$_quit_ok" != "true" ]]; then
		for _try in 1 2 3 4; do
			tui_keys Escape
			sleep 0.35
			_scr=$(tui_capture)
			if echo "$_scr" | grep -qi "Stopped before all steps\|: Stopped\|Aborted" || \
			   ! echo "$_scr" | grep -qi "In Progress\|Test Abort"; then
				_quit_ok=true
				break
			fi
		done
	fi
	tui_screenshot "pi-d2-after-quit"
	# Only post-quit outcomes — never match the live "Quit (Q/ESC)" button label.
	if [[ "$_quit_ok" == "true" ]]; then
		echo "  ✓ PASS: Quit during progress acknowledged"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Enter 2>/dev/null || true
		sleep 1
	else
		tui_screenshot "pi-d3-quit-failed"
		echo "  ✗ FAIL: Quit during progress had no effect"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

$_TUI_SSH "tmux kill-session -t $_TUI_SESSION 2>/dev/null; true"
sleep 1

# ============================================================================
# Cleanup
# ============================================================================
echo ""
echo "--- Cleanup ---"
$_TUI_SSH "rm -f /tmp/aba-progress-test.sh /tmp/aba-progress-test-fail.sh \
	/tmp/aba-progress-test-slow.sh /tmp/aba-progress-wrapper.sh" 2>/dev/null
# Kill tmux session first, then check for strays
tui_stop
$_TUI_SSH "pkill -9 -f abatui2 2>/dev/null; pkill -9 -f aba-progress- 2>/dev/null; true"
sleep 2
_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui|progress-wrapper' | grep -v grep" 2>/dev/null || true)
if [ -z "$_strays" ]; then
	echo "  ✓ PASS: No stray processes"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Stray processes after cleanup:"
	echo "$_strays" | sed 's/^/      /'
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	$_TUI_SSH "pkill -9 -f 'progress-wrapper\|progress-test\|abatui\|dialog --' 2>/dev/null; true"
	sleep 1
fi
tui_summary
