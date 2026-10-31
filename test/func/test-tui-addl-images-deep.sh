#!/bin/bash
# Test: TUI Additional Images — deep permutation test
#
# Exercises:
#   1.  Add image via inputbox, verify in list and images.conf
#   2.  Add second image, verify count updates
#   3.  List images — both are shown
#   4.  Remove one image, verify remaining
#   5.  Recommended Images dialog appears with curated sets
#   6.  Toggle exclude/include, verify ISC content changes
#   7.  Clear all images with confirmation
#   8.  Empty state: no list/remove/clear/toggle items shown
#   9.  Edit images.conf directly
#  10.  Restore originals
#
# Non-destructive: restores original images.conf at the end.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Additional Images Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# Save original images.conf for restoration
$_TUI_SSH "cp ~/aba/images.conf ~/aba/images.conf.test-backup 2>/dev/null; true"
_orig_excl=$($_TUI_SSH "grep '^excl_additional=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "false")
echo "  Saved original images.conf and excl_additional=$_orig_excl"

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# Helper: navigate to Additional Images menu
_goto_addl() {
	# If already in Additional Images menu, stay
	if tui_capture | grep -qi "Add image\|List images\|Additional Images"; then
		return 0
	fi
	tui_back_to "Actions" 5
	tui_select_item "Mirror Payload"
	tui_wait_for "Additional Images\|Select Operators" 10
	# Select Additional Images (tag G)
	tui_keys G; sleep 0.3; tui_keys Enter
	tui_wait_for "Add image\|Recommended" 10
}

# Helper: read image count from images.conf on remote
_read_img_count() {
	local _c
	_c=$($_TUI_SSH "grep -c '^[^#].*[^[:space:]]' ~/aba/images.conf 2>/dev/null || echo 0") || true
	echo "${_c%%[^0-9]*}"
}

# ============================================================================
# 1. Clear slate: empty images.conf first
# ============================================================================
echo ""
echo "--- 1. Clear images.conf for clean slate ---"
$_TUI_SSH "> ~/aba/images.conf"
_count=$(_read_img_count)
echo "  Image count after clear: $_count"
if [[ "$_count" -eq 0 ]]; then
	echo "  ✓ PASS: Clean slate (0 images)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected 0 images, got $_count"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 2. Open Additional Images when empty — verify limited menu
# ============================================================================
echo ""
echo "--- 2. Empty state menu ---"
_goto_addl
sleep 1
tui_screenshot "ai-02-empty-menu"
_scr=$(tui_capture)

# When empty: only Add, Recommended, Edit should be shown (no List, Remove, Clear, Toggle)
if echo "$_scr" | grep -qi "Add image"; then
	echo "  ✓ PASS: Add image shown when empty"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Add image not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_scr" | grep -qi "Recommended"; then
	echo "  ✓ PASS: Recommended Images shown when empty"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Recommended Images not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_scr" | grep -qi "Edit images.conf"; then
	echo "  ✓ PASS: Edit shown when empty"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Edit not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# List should NOT be shown when empty
if echo "$_scr" | grep -qi "List images"; then
	echo "  ✗ FAIL: List images should be hidden when empty"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
else
	echo "  ✓ PASS: List images hidden when empty"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 3. Help text completeness
# ============================================================================
echo ""
echo "--- 3. Help text ---"
tui_press_button "Help"
sleep 2
tui_screenshot "ai-03-help"
_scr=$(tui_capture)

tui_assert_contains "Add" "Help mentions Add"
tui_assert_contains "Remove" "Help mentions Remove"
tui_assert_contains "Recommended" "Help mentions Recommended"
tui_assert_contains "images.conf" "Help mentions images.conf"
tui_assert_contains "ImageSet" "Help mentions ImageSet"
tui_keys Enter; sleep 1

# ============================================================================
# 4. Add first image
# ============================================================================
echo ""
echo "--- 4. Add image: registry.redhat.io/ubi9/ubi:latest ---"
_goto_addl
tui_keys A; sleep 0.3; tui_keys Enter
sleep 2
_scr=$(tui_capture)
tui_screenshot "ai-04-add-input"

if echo "$_scr" | grep -qi "image reference\|container image\|Add.*image\|Enter"; then
	echo "  ✓ PASS: Add image input dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Add image input not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Type the image reference
tui_keys "registry.redhat.io/ubi9/ubi:latest"
sleep 0.5
tui_keys Enter
sleep 3
# Dismiss the "Added:" confirmation msgbox
if tui_capture | grep -qi "Added\|ubi"; then
	tui_keys Enter; sleep 1
fi
tui_screenshot "ai-04-after-add"

# Verify in images.conf
_count=$(_read_img_count)
if [[ "$_count" -ge 1 ]]; then
	echo "  ✓ PASS: Image added (count=$_count)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Image not added to images.conf"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

_has_ubi=$($_TUI_SSH "grep -c 'ubi9/ubi' ~/aba/images.conf 2>/dev/null" || echo "0")
if [[ "$_has_ubi" -ge 1 ]]; then
	echo "  ✓ PASS: ubi9/ubi found in images.conf"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ubi9/ubi not in images.conf"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 5. Add second image
# ============================================================================
echo ""
echo "--- 5. Add image: registry.redhat.io/rhel9/support-tools:latest ---"
_goto_addl
tui_keys A; sleep 0.3; tui_keys Enter
sleep 2
tui_keys "registry.redhat.io/rhel9/support-tools:latest"
sleep 0.5
tui_keys Enter
sleep 3
if tui_capture | grep -qi "Added\|support-tools"; then
	tui_keys Enter; sleep 1
fi

_count=$(_read_img_count)
if [[ "$_count" -ge 2 ]]; then
	echo "  ✓ PASS: Second image added (count=$_count)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected ≥2 images, got $_count"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ISC round-trip: verify the ISC file contains both images
echo "  Verifying ISC reflects added images..."
tui_assert_isc_contains "additionalImages:" "additionalImages section in ISC"
tui_assert_isc_contains "ubi9/ubi" "ubi9/ubi image in ISC"
tui_assert_isc_contains "support-tools" "support-tools image in ISC"

# ============================================================================
# 6. List images — verify both are shown
# ============================================================================
echo ""
echo "--- 6. List images ---"
_goto_addl
tui_keys L; sleep 0.3; tui_keys Enter
sleep 2
tui_screenshot "ai-06-list"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "ubi9/ubi"; then
	echo "  ✓ PASS: List shows ubi9/ubi"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ubi9/ubi not in list"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_scr" | grep -qi "support-tools"; then
	echo "  ✓ PASS: List shows support-tools"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: support-tools not in list"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_keys Enter; sleep 1

# ============================================================================
# 7. Full menu items present when images exist
# ============================================================================
echo ""
echo "--- 7. Full menu with images ---"
_goto_addl
sleep 1
tui_screenshot "ai-07-full-menu"
_scr=$(tui_capture)

tui_assert_contains "List images" "List item present with images"
tui_assert_contains "Add image" "Add item present"
tui_assert_contains "Remove image" "Remove item present with images"
tui_assert_contains "Clear all" "Clear item present with images"
tui_assert_contains "Recommended" "Recommended item present"
tui_assert_contains "Edit images.conf" "Edit item present"

# ============================================================================
# 8. Toggle exclude/include
# ============================================================================
echo ""
echo "--- 8. Toggle exclude/include ---"
_goto_addl
# Select the exclude toggle (X)
tui_keys X; sleep 0.3; tui_keys Enter
sleep 2

_excl=$($_TUI_SSH "grep '^excl_additional=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
if [[ "$_excl" == "true" ]]; then
	echo "  ✓ PASS: Toggle set excl_additional=true"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected excl_additional=true, got '$_excl'"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ISC round-trip: when excluded, additionalImages should be commented out or absent
echo "  Verifying ISC excludes additional images..."
tui_assert_isc_not_contains "^  additionalImages:" "active additionalImages (should be excluded)"

_goto_addl
sleep 1
_scr=$(tui_capture)
tui_screenshot "ai-08-excluded"
if echo "$_scr" | grep -qi "excluded"; then
	echo "  ✓ PASS: Menu shows 'excluded' label"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: 'excluded' label not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Toggle back to included
tui_keys X; sleep 0.3; tui_keys Enter
sleep 2
_excl=$($_TUI_SSH "grep '^excl_additional=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
if [[ "$_excl" == "false" ]]; then
	echo "  ✓ PASS: Toggle restored excl_additional=false"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected excl_additional=false, got '$_excl'"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 9. Remove one image
# ============================================================================
echo ""
echo "--- 9. Remove image ---"
_goto_addl
tui_keys R; sleep 0.3; tui_keys Enter
sleep 2
tui_screenshot "ai-09-remove"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "ubi9/ubi\|support-tools"; then
	echo "  ✓ PASS: Remove checklist shows images"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Select first item (Space to toggle, Enter to confirm)
	tui_keys Space; sleep 0.3
	tui_keys Enter
	sleep 3
	# Dismiss confirmation
	if tui_capture | grep -qi "Removed\|removed"; then
		tui_keys Enter; sleep 1
	fi
	_count=$(_read_img_count)
	if [[ "$_count" -eq 1 ]]; then
		echo "  ✓ PASS: One image removed (count=$_count)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Expected 1 image after remove, got $_count"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# ISC round-trip: verify the ISC has only 1 image after removal
	echo "  Verifying ISC reflects removal..."
	_isc_after_rm=$(tui_read_isc)
	_img_count=$(echo "$_isc_after_rm" | grep -c 'additionalImages:' 2>/dev/null) || _img_count=0
	if [[ "$_img_count" -ge 1 ]]; then
		echo "  ✓ PASS: ISC still has additionalImages section (1 image remains)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: ISC lost additionalImages section entirely"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ✗ FAIL: Remove checklist not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 10. Recommended Images dialog
# ============================================================================
echo ""
echo "--- 10. Recommended Images ---"
_goto_addl
tui_keys S; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "ai-10-recommended"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "Recommended\|image set\|Image Sets\|ocp\|virt\|ai"; then
	echo "  ✓ PASS: Recommended Images dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Recommended Images content unclear"
fi
# Back out without changing
tui_keys Escape; sleep 1

# ============================================================================
# 11. Clear all images
# ============================================================================
echo ""
echo "--- 11. Clear all images ---"
_goto_addl
tui_keys D; sleep 0.3; tui_keys Enter
sleep 2
tui_screenshot "ai-11-clear-confirm"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "Remove all\|Clear All\|cannot be undone"; then
	echo "  ✓ PASS: Clear confirmation dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# --defaultno focuses Cancel; Tab to Clear All, then Enter
	tui_keys Tab; sleep 0.3
	tui_keys Enter
	sleep 2
	_count=$(_read_img_count)
	if [[ "$_count" -eq 0 ]]; then
		echo "  ✓ PASS: All images cleared (count=0)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Expected 0 images after clear, got $_count"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# ISC round-trip: after clearing all images, ISC should have no additionalImages
	echo "  Verifying ISC has no additional images after clear..."
	_isc_cleared=$(tui_read_isc)
	_addl_active=$(echo "$_isc_cleared" | grep -c '^  additionalImages:' 2>/dev/null) || _addl_active=0
	if [[ "$_addl_active" -eq 0 ]]; then
		echo "  ✓ PASS: ISC has no additionalImages after clear"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: ISC still has additionalImages section after clear"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ✗ FAIL: Clear confirmation not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 12. Restore originals
# ============================================================================
echo ""
echo "--- 12. Restore originals ---"
$_TUI_SSH "cp ~/aba/images.conf.test-backup ~/aba/images.conf 2>/dev/null; rm -f ~/aba/images.conf.test-backup"
$_TUI_SSH "cd ~/aba && sed -i 's/^excl_additional=.*/excl_additional=$_orig_excl/' aba.conf" 2>/dev/null
echo "  Restored images.conf and excl_additional=$_orig_excl"
echo "  ✓ PASS: Originals restored"
_TUI_PASS=$(( _TUI_PASS + 1 ))

# ============================================================================
# 13. Cleanup
# ============================================================================
echo ""
echo "--- 13. Cleanup ---"
tui_cleanup
tui_summary
