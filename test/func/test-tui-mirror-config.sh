#!/bin/bash
# Test: TUI mirror config form and platform config forms
# Exercises: Install Mirror menu (local/remote choice), mirror config fields,
# VMware config form, platform settings, all non-destructive (cancel out).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh
trap 'tui_mirror_restore_service || true' EXIT

echo "=== TUI Mirror Config & Platform Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# ============================================================================
# 1. Install Mirror menu (local/remote choice)
# ============================================================================
echo ""
echo "--- 1. Install Mirror / Registry menu ---"
# In CONNO mode the item is "Install Mirror", in DISCO mode it's "Install Registry"
_mirror_found=false
if tui_select_item "Install Mirror" 2>/dev/null; then
	_mirror_found=true
elif tui_select_item "Install Registry" 2>/dev/null; then
	_mirror_found=true
fi
sleep 2

if ! $_mirror_found; then
	echo "  ✗ FAIL: Neither 'Install Mirror' nor 'Install Registry' found"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
else
	tui_pass "Mirror/Registry menu item found"
fi

# An installed registry shows Reinstall. Yes removes the service and keeps
# the data dir, then the config form is tested. The service is installed again.
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "already installed\|reinstall\|Uninstall"; then
	tui_pass "Mirror reinstall confirmation appeared" "$_scr"
	echo "  Uninstalling mirror so the config form opens (data dir kept)"
	_TUI_MIRROR_SERVICE_DOWN=yes
	tui_confirm_yes
	if ! tui_wait_mirror_install_choice "mc-uninstall"; then
		echo "  ✗ FAIL: mirror uninstall did not reach the install form"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		_scr=""
	else
		tui_pass "Install form opened after uninstall" "$(tui_capture)"
		_scr=$(tui_capture)
	fi
fi
if echo "$_scr" | grep -qi "locally\|remote\|local.*remote\|Install.*where"; then
	# No mirror yet (fresh host / after wipe) — install dialog is correct
	tui_pass "Install dialog appeared (mirror not yet installed)" "$_scr"
	tui_screenshot "mc-01-choice"
	tui_assert_contains "locally\|Install locally\|local" "Local install option"
	tui_assert_contains "remote\|remote host" "Remote install option"

	# Check help
	tui_press_button "Help"
	sleep 2
	tui_assert_contains "mirror.*registry\|registry\|Registry" "Mirror help mentions registry"
	tui_assert_contains "Local\|local\|locally" "Mirror help mentions local"
	tui_assert_contains "Remote\|remote\|SSH\|ssh" "Mirror help mentions remote"
	tui_screenshot "mc-01b-help"
	tui_keys Enter; sleep 1

	# Select "Install locally" to see config form
	echo ""
	echo "--- 1a. Local mirror config form ---"
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "locally\|local"; then
		# Select the local option
		tui_keys Enter
		sleep 2
		tui_screenshot "mc-01c-local-form"

		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Mirror Configuration\|Hostname\|Port"; then
			tui_pass "Local mirror config form appeared" "$_scr"
			tui_assert_title "Install Mirror\|Mirror Configuration" "Mirror config dialog title"

			# Verify config form fields
			tui_assert_contains "Hostname" "Hostname field"
			tui_assert_contains "Port" "Port field"
			tui_assert_contains "Username" "Username field"
			tui_assert_contains "Password" "Password field"
			tui_assert_contains "Image path" "Image path field"
			tui_assert_contains "Vendor" "Vendor field"
			tui_assert_contains "Data dir" "Data dir field"

			# Cancel out
			tui_keys Escape; sleep 1
		else
			echo "  ✗ FAIL: Config form not visible"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	fi

	# Cancel back to main menu
	tui_keys Escape; sleep 1
else
	echo "  ✗ FAIL: mirror install screen not recognized"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "mc-01-unknown"
fi
if ! tui_mirror_restore_service; then
	echo "  ✗ FAIL: mirror service was not installed again"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 2. VMware Platform Config form
# ============================================================================
echo ""
echo "--- 2. VMware Platform Config ---"
tui_back_to "Actions" 5
tui_select_item "Advanced"
tui_assert_appears "Advanced\|Platform Settings" "Advanced menu" 10

# Select Platform Settings
tui_select_item "Platform Settings"
sleep 2
tui_screenshot "mc-02-platform-select"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Bare Metal\|VMware\|KVM"; then
	tui_pass "Platform selection dialog appeared" "$_scr"
	tui_assert_contains "Bare Metal" "Bare Metal option"
	tui_assert_contains "VMware" "VMware option"
	tui_assert_contains "KVM" "KVM option"

	# Select VMware to see config form
	echo ""
	echo "--- 2a. VMware config form fields ---"
	# VMware should be highlighted (current platform)
	# Navigate to VMware and press Enter
	tui_keys Enter  # Select whatever is highlighted
	sleep 2
	tui_screenshot "mc-02a-vmw-form"

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "VMware.*Configuration\|ESXi\|vCenter"; then
		tui_pass "VMware config form appeared" "$_scr"

		# Verify VMware form fields
		tui_assert_contains "vCenter.*URL\|ESXi.*URL" "vCenter/ESXi URL field"
		tui_assert_contains "Username" "Username field"
		tui_assert_contains "Password" "Password field"
		tui_assert_contains "Datastore" "Datastore field"
		tui_assert_contains "Network" "Network field"
		tui_assert_contains "Datacenter" "Datacenter field"
		tui_assert_contains "Cluster" "Cluster field"
		tui_assert_contains "VM Folder\|Folder" "VM Folder field"
		tui_assert_contains "TLS verify\|Skip TLS" "TLS verify toggle"
		tui_assert_contains "Test Connection" "Test Connection item"

		# Check that values are populated (vmware.conf exists on conno)
		if echo "$_scr" | grep -qi "URL:.*[a-z0-9]"; then
			tui_pass "vCenter URL populated" "$_scr"
		else
			echo "  ✗ FAIL: vCenter URL not populated (vmware.conf may be template)"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi

		# Cancel out without changing anything
		tui_keys Escape; sleep 1
	else
		echo "  ✗ FAIL: VMware form not visible — may have gone to a different platform"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_keys Escape; sleep 1
	fi
else
	echo "  ✗ FAIL: Platform dialog not visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 3. Advanced menu items check
# ============================================================================
echo ""
echo "--- 3. Advanced menu items ---"
tui_back_to "Actions" 5
tui_select_item "Advanced"
tui_assert_appears "Advanced" "Advanced menu" 10
tui_screenshot "mc-03-advanced"

# Check for mirror management items (only if mirror is installed)
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Stop.*Registry\|Start.*Registry\|Uninstall.*Registry"; then
	tui_assert_contains "Stop.*Registry" "Stop Mirror Registry item"
	tui_assert_contains "Start.*Registry" "Start Mirror Registry item"
	tui_assert_contains "Uninstall.*Registry" "Uninstall Mirror Registry item"
else
	# Fresh wipe / never installed — Advanced still valid without stop/start/uninstall
	tui_pass "Mirror management items absent (mirror not installed yet)" "$_scr"
fi

# Check mode switch items (labels vary by current mode)
tui_assert_contains "Switch.*Connected\|Switch.*direct\|Switch.*Partially" "Switch mode item 1"
tui_assert_contains "Switch.*Disconnected\|Switch.*Connected\|Switch.*direct" "Switch mode item 2"

# Check danger zone (CONNO: "Clean ABA", DISCO: "Refresh Cluster")
tui_assert_contains "Clean ABA\|remove config\|Refresh Cluster\|Refresh" "Danger zone item"

# Check Advanced help
tui_press_button "Help"
sleep 2
tui_screenshot "mc-03b-advanced-help"
tui_assert_contains "Platform Settings" "Advanced help mentions Platform Settings"
tui_assert_contains "Uninstall Mirror\|Uninstall" "Advanced help mentions Uninstall"
tui_assert_contains "Stop Mirror\|Stop" "Advanced help mentions Stop"
tui_assert_contains "Switch Mode\|Switch" "Advanced help mentions Switch Mode"
tui_assert_contains "Clean ABA\|Refresh\|Clean\|reset" "Advanced help mentions cleanup"
tui_keys Enter; sleep 1

# Cancel out
tui_keys Escape; sleep 1

# ============================================================================
# 4. Feedback dialog
# ============================================================================
echo ""
echo "--- 4. Feedback dialog ---"
tui_back_to "Actions" 5
tui_select_item "Feedback"
sleep 2
tui_screenshot "mc-04-feedback"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Feedback\|github\|discussion\|bug\|issue"; then
	tui_pass "Feedback dialog appeared" "$_scr"
else
	echo "  ✗ FAIL: Feedback screen unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_keys Escape; sleep 1
tui_keys Enter; sleep 1

# ============================================================================
# 5. Cleanup
# ============================================================================
echo ""
echo "--- 5. Cleanup ---"
tui_cleanup
tui_summary
