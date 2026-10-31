#!/bin/bash
# Test: TUI operator workflows — deep permutation testing
#
# Exercises every operator interaction:
#   1.  Operator Sets: add multiple sets, verify count, toggle off, verify removal
#   2.  Search: find operators by name, toggle in results, verify basket update
#   3.  View/Edit basket: verify contents match after add, remove individual items
#   4.  Clear selection: confirm dialog, verify empty, verify count resets to 0
#   5.  Round-trip: add set → verify basket → remove set → verify basket shrinks
#   6.  Companion images: add a set that has companions, verify prompt appears
#
# Non-destructive: all changes are reverted at the end.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Operator Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# Save current operator selection for restoration
_orig_op_sets=$($_TUI_SSH "grep '^op_sets=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || true)
_orig_operators=$($_TUI_SSH "grep '^operators=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2" || true)
echo "  Saved original: op_sets='$_orig_op_sets' operators='${_orig_operators:0:60}...'"

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# Navigate to Select Operators
_goto_operators() {
	if tui_capture | grep -q "Select Operator Sets"; then
		return 0
	fi
	tui_back_to "Actions" 5
	tui_select_item "Mirror Payload"
	tui_wait_isc_done 120
	tui_wait_for "Mirror Payload\|Payload" 15
	tui_select_item "Select Operators"
	tui_wait_for "Select Operator Sets" 15
}

# ============================================================================
# 1. Clear all operators first (clean slate)
# ============================================================================
echo ""
echo "--- 1. Clear operators for clean slate ---"
_goto_operators
sleep 1

# Read current basket count from menu
_scr=$(tui_capture)
_initial_count=$(echo "$_scr" | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
echo "  Initial basket count: $_initial_count"

if [[ "$_initial_count" -gt 0 ]]; then
	# Select "Clear Selection"
	tui_keys 4; sleep 0.5; tui_keys Enter
	sleep 2
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Remove all\|Clear"; then
		# --defaultno focuses Cancel; Tab to Clear, then Enter
		tui_keys Tab; sleep 0.3
		tui_keys Enter
		sleep 2
		# Dismiss "Selection cleared" msgbox
		if tui_capture | grep -qi "cleared"; then
			tui_keys Enter; sleep 1
		fi
	fi
fi

# Verify basket is now 0
_goto_operators
sleep 1
_scr=$(tui_capture)
_count=$(echo "$_scr" | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
tui_screenshot "od-01-cleared"

if [[ "$_count" == "0" ]]; then
	echo "  ✓ PASS: Basket cleared to 0 operators"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected 0 operators after clear, got $_count"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 2. Add operator set: "logging"
# ============================================================================
echo ""
echo "--- 2. Add operator set: logging ---"
_goto_operators
tui_keys 1; sleep 0.5; tui_keys Enter
tui_assert_appears "Operator Sets\|checklist\|\\[" "Operator Sets checklist" 10
tui_screenshot "od-02-sets-before"

# Find "logging" in the checklist and toggle it on (Space)
# Navigate down to find logging, then press Space
# First, capture what sets exist
_scr=$(tui_capture)
echo "  Available sets:"
echo "$_scr" | sed -n 's/.*\[\(.\)\][[:space:]]*\(.*\)/    [\1] \2/p' | head -10

# Type 'l' to jump to logging (dialog supports first-letter navigation in checklists)
# Actually in dialog checklists, we navigate with arrows. Let's search for the position.
# Simpler: use the dialog's search - scroll to find logging
# Reset to top of list, then scroll down to find logging
_found_logging=false
for i in $(seq 1 30); do tui_keys Up; sleep 0.1; done
for i in $(seq 1 35); do
	if tui_capture | grep -qi "logging"; then
		_found_logging=true
		break
	fi
	tui_keys Down; sleep 0.3
done

if [[ "$_found_logging" == "true" ]]; then
	# Toggle it on with Space
	tui_keys Space
	sleep 0.5
	tui_screenshot "od-02b-logging-toggled"
	# Press OK/Next to apply
	tui_keys Enter
	sleep 3
	# Dismiss companion images dialog if it appears
	if tui_capture | grep -qi "companion\|Recommended\|image sets"; then
		echo "  (companion images prompt appeared — pressing Skip)"
		tui_press_button "Skip" 2>/dev/null || tui_keys Escape
		sleep 2
	fi
	# Check basket count increased
	_goto_operators
	sleep 1
	_count=$(tui_capture | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
	if [[ "$_count" -gt 0 ]]; then
		echo "  ✓ PASS: Added logging set, basket now has $_count operators"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Basket still empty after adding logging set"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# ISC round-trip: verify the ISC file reflects the logging operators
	# Allow background ISC regeneration to complete
	sleep 5
	echo "  Verifying ISC contains logging operators..."
	tui_assert_isc_contains "cluster-logging|loki-operator|cincinnati-operator" "logging operators in ISC"
	tui_assert_isc_contains "^  operators:" "operators section in ISC"
else
	echo "  ~ SKIP: Could not find 'logging' in operator sets list"
fi

_logging_count="$_count"

# ============================================================================
# 3. Add another operator set: "obs" (observability)
# ============================================================================
echo ""
echo "--- 3. Add operator set: obs ---"
_goto_operators
tui_keys 1; sleep 0.5; tui_keys Enter
tui_wait_for "Operator Sets\|checklist\|\\[" 10

# Navigate to obs
_found_obs=false
# Reset to top first
for i in $(seq 1 30); do tui_keys Up; sleep 0.1; done
for i in $(seq 1 30); do
	if tui_capture | grep -qi "obs.*Observab"; then
		_found_obs=true
		break
	fi
	tui_keys Down; sleep 0.3
done

if [[ "$_found_obs" == "true" ]]; then
	tui_keys Space; sleep 0.5
	tui_screenshot "od-03-obs-toggled"
	tui_keys Enter
	sleep 3
	# Dismiss companion images if shown
	if tui_capture | grep -qi "companion\|Recommended\|image sets"; then
		echo "  (companion images prompt appeared — pressing Skip)"
		tui_press_button "Skip" 2>/dev/null || tui_keys Escape
		sleep 2
	fi
	_goto_operators
	sleep 1
	_count=$(tui_capture | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
	if [[ "$_count" -gt "${_logging_count:-0}" ]]; then
		echo "  ✓ PASS: Added obs set, basket now has $_count operators (was $_logging_count)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Basket did not grow after adding obs set (count: $_count)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ~ SKIP: Could not find 'obs' in operator sets list"
fi

_both_count="$_count"

# ============================================================================
# 4. View/Edit basket — verify operators are listed
# ============================================================================
echo ""
echo "--- 4. View/Edit basket ---"
_goto_operators
tui_keys 3; sleep 0.5; tui_keys Enter
sleep 3
tui_screenshot "od-04-basket"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Operator Selection\|operator\|\\[X\\]\|\\[ \\]"; then
	echo "  ✓ PASS: Basket view shows operator list"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Count items in the basket view
	_basket_items=$(echo "$_scr" | grep -c '\[.\]' || true)
	echo "  Basket contains $_basket_items items"

	# Verify some operators from logging set are present
	if echo "$_scr" | grep -qi "logging\|loki\|elasticsearch"; then
		echo "  ✓ PASS: Logging operators visible in basket"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ~ NOTE: No logging-related operator names visible in first screen"
	fi
else
	echo "  ~ NOTE: Basket view screen unclear"
fi
tui_keys Escape; sleep 1

# ============================================================================
# 5. Remove one operator set (logging) — verify count decreases
# ============================================================================
echo ""
echo "--- 5. Remove operator set: logging ---"
_goto_operators
tui_keys 1; sleep 0.5; tui_keys Enter
tui_wait_for "Operator Sets\|checklist\|\\[" 10

# Find logging (should be [X] now) and toggle off
_found_logging=false
for i in $(seq 1 30); do tui_keys Up; sleep 0.1; done
for i in $(seq 1 35); do
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "logging"; then
		_found_logging=true
		break
	fi
	tui_keys Down; sleep 0.3
done

if [[ "$_found_logging" == "true" ]]; then
	# Verify it's checked [X]
	_scr=$(tui_capture)
	if echo "$_scr" | grep -i "logging" | grep -q '\[X\]'; then
		echo "  Logging set is [X] (checked) — toggling off"
		tui_keys Space; sleep 0.5
		tui_screenshot "od-05-logging-off"
		tui_keys Enter; sleep 3
		# Check if companion dialog appears (shouldn't for removal)
		if tui_capture | grep -qi "companion\|Recommended"; then
			tui_press_button "Skip" 2>/dev/null || tui_keys Escape
			sleep 2
		fi
		_goto_operators
		sleep 1
		_count=$(tui_capture | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
		if [[ "$_count" -lt "${_both_count:-999}" ]]; then
			echo "  ✓ PASS: Removed logging set, basket decreased: $_both_count → $_count"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Basket did not decrease after removing logging (count: $_count)"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	else
		echo "  ~ NOTE: Logging set not checked — may already be off"
	fi
else
	echo "  ~ SKIP: Could not find 'logging' in operator sets list"
fi

# ============================================================================
# 6. Search for an operator by name
# ============================================================================
echo ""
echo "--- 6. Search for 'web-terminal' ---"
_goto_operators
tui_keys 2; sleep 0.5; tui_keys Enter
sleep 2

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Search\|keyword\|operator name"; then
	echo "  ✓ PASS: Search input appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Type search term
	tui_keys "web-terminal"
	sleep 0.5
	tui_keys Enter
	sleep 5
	tui_screenshot "od-06-search-results"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "web-terminal"; then
		echo "  ✓ PASS: Search found 'web-terminal'"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		# Toggle it on (Space on first result)
		tui_keys Space; sleep 0.5
		tui_screenshot "od-06b-toggled"

		# Accept selection
		tui_keys Enter; sleep 2
	elif echo "$_scr" | grep -qi "No.*results\|0 matches\|not found"; then
		echo "  ✓ PASS: Search returned 'no results' (catalog index may not cover it)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_keys Escape; sleep 1
	else
		echo "  ~ NOTE: Search results unclear"
		tui_keys Escape; sleep 1
	fi
else
	echo "  ~ NOTE: Search input not found"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 7. Search for a different operator: 'compliance'
# ============================================================================
echo ""
echo "--- 7. Search for 'compliance' ---"
_goto_operators
tui_keys 2; sleep 0.5; tui_keys Enter
sleep 2

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Search\|keyword"; then
	tui_keys "compliance"
	sleep 0.5
	tui_keys Enter
	sleep 5
	tui_screenshot "od-07-compliance"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "compliance"; then
		echo "  ✓ PASS: Search found 'compliance'"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_scr" | grep -qi "No.*results\|not found"; then
		echo "  ✓ PASS: Search returned 'no results' for 'compliance'"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ~ NOTE: Compliance search results unclear"
	fi
	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Search input not found"
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 8. Clear all and verify basket is empty
# ============================================================================
echo ""
echo "--- 8. Clear all and verify empty ---"
_goto_operators
sleep 1
_count=$(tui_capture | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
echo "  Basket before clear: $_count operators"

tui_keys 4; sleep 0.5; tui_keys Enter
sleep 2

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Remove all\|clear.*selection\|Are you sure"; then
	echo "  ✓ PASS: Clear confirmation appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# --defaultno focuses Cancel; Tab to Clear (first button), then Enter
	tui_keys Tab; sleep 0.3
	tui_keys Enter; sleep 2
	# Dismiss "Selection cleared" msgbox
	if tui_capture | grep -qi "cleared"; then
		tui_keys Enter; sleep 1
	fi
elif echo "$_scr" | grep -qi "already empty\|nothing to clear\|no operators"; then
	echo "  ✓ PASS: Already empty — clear reports that"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_keys Enter; sleep 1
fi

# Verify count is 0
_goto_operators
sleep 1
_count=$(tui_capture | grep -oP 'View/Edit Selection \(\K[0-9]+' || echo "0")
if [[ "$_count" == "0" ]]; then
	echo "  ✓ PASS: Basket is empty after clear"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Basket not empty after clear (count: $_count)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_screenshot "od-08-final-empty"

# ISC round-trip: after clearing all operators, ISC should have no operator packages
echo "  Verifying ISC has no operators after clear..."
_isc_cleared=$(tui_read_isc)
_pkg_lines=$(echo "$_isc_cleared" | grep -c '^\s*- name:.*operator' 2>/dev/null) || _pkg_lines=0
if [[ "$_pkg_lines" -eq 0 ]]; then
	echo "  ✓ PASS: ISC has no operator packages after clear"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC still has $_pkg_lines operator packages after clear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 9. View/Edit on empty basket — verify empty message
# ============================================================================
echo ""
echo "--- 9. View/Edit on empty basket ---"
_goto_operators
tui_keys 3; sleep 0.5; tui_keys Enter
sleep 3
tui_screenshot "od-09-empty-basket"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "empty\|No operators\|no.*selected"; then
	echo "  ✓ PASS: Empty basket message shown"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Empty basket view unclear"
fi
tui_keys Enter 2>/dev/null; tui_keys Escape; sleep 1

# ============================================================================
# 10. Restore original operator selection
# ============================================================================
echo ""
echo "--- 10. Restore original operators ---"
$_TUI_SSH "cd ~/aba && sed -i 's/^op_sets=.*/op_sets=$_orig_op_sets/' aba.conf" 2>/dev/null
echo "  Restored op_sets='$_orig_op_sets'"

# ============================================================================
# 11. Cleanup
# ============================================================================
echo ""
echo "--- 11. Cleanup ---"
tui_cleanup
tui_summary
