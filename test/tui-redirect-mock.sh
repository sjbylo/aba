#!/bin/bash
# Mock TUI to validate blanket stdout/stderr redirect with dialog.
# Tests that stray output goes to log, dialogs render, selections are captured.
#
# The trick: dialog renders its UI to stderr (ncurses). We redirect stderr
# to a log, but give dialog access to the terminal via FD 3. Dialog uses
# --output-fd to send selections to a separate FD (4), not stderr.

set -u

LOG_FILE="/tmp/tui-redirect-mock.log"
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

> "$LOG_FILE"

echo "=== TUI redirect mock ==="
echo "Log file: $LOG_FILE"
echo ""

# ─── Blanket redirect ───
exec 3>/dev/tty                  # FD 3 = terminal (for dialog UI rendering)
exec 1>>"$LOG_FILE"             # All stdout → log
exec 2>>"$LOG_FILE"             # All stderr → log

# dialog wrapper: renders UI to terminal (FD 3), captures selection to TMP_FILE
# Mimics how the real dlg() wrapper would work.
mock_dlg() {
	# Open FD 4 for dialog result output
	exec 4>"$TMP_FILE"
	dialog --no-shadow --output-fd 4 "$@" 2>&3
	local rc=$?
	exec 4>&-
	return $rc
}

# dialog wrapper for non-capturing calls (msgbox, infobox)
mock_dlg_simple() {
	dialog --no-shadow "$@" 2>&3
}

# ─── Test 1: stray output should NOT appear on screen ───
echo "TEST 1: This echo should go to log, not screen"
echo "TEST 1: This stderr should go to log too" >&2

# ─── Test 2: dialog --msgbox should render on screen ───
mock_dlg_simple --title " Test 2: msgbox " \
	--msgbox "\nIf you can read this, dialog rendering works.\n\nStray output above? That's a bug." 0 0

# ─── Test 3: dialog --menu with selection capture ───
mock_dlg --title " Test 3: menu selection " \
	--menu "\nPick one:" 0 0 0 \
	"A" "Alpha" \
	"B" "Bravo" \
	"C" "Charlie"
selection=$(cat "$TMP_FILE")

# ─── Test 4: stray output between dialogs ───
echo "TEST 4: More stray output between dialogs"
echo "TEST 4: stderr noise" >&2
source /dev/stdin <<< 'echo "TEST 4: sourced script output"'

# ─── Test 5: show the selection worked ───
mock_dlg_simple --title " Test 5: selection result " \
	--msgbox "\nYou selected: [${selection:-NOTHING}]\n\nIf you see a letter, selection capture works." 0 0

# ─── Test 6: _exec_in_terminal style (needs real terminal) ───
{
	clear
	echo "═══════════════════════════════════════════"
	echo "  Test 6: terminal-mode execution"
	echo "═══════════════════════════════════════════"
	echo ""
	echo "  This simulates _exec_in_terminal."
	echo "  You should see this on screen."
	echo ""
	echo "  Running a command..."
	ls /tmp/*.log 2>&1 | head -5
	echo ""
	read -rp "  Press ENTER to continue... "
} 1>&3 2>&3

# ─── Test 7: piped command through dialog --progressbox ───
{
	echo "Line 1: simulating aba command output"
	sleep 0.5
	echo "Line 2: processing..."
	sleep 0.5
	echo "Line 3: done!"
} | dialog --no-shadow --title " Test 7: progressbox " --progressbox 12 60 2>&3

# ─── Test 8: final stray output ───
echo "TEST 8: final stray echo — should be in log only"

# ─── Results dialog ───
mock_dlg_simple --title " All tests complete " \
	--msgbox "\nAll 8 tests ran.\n\nCheck the log for captured output:\n  $LOG_FILE\n\nIf you only saw dialogs (no stray text),\nthe blanket redirect works." 0 0

# ─── Restore terminal for final summary ───
exec 1>&3 2>&3

echo ""
echo "=== Log file contents ==="
echo ""
cat "$LOG_FILE" | grep "^TEST"
echo ""
echo "=== Expected: TEST 1, 4, 8 lines above (captured in log, not on screen) ==="
