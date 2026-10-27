#!/bin/bash
# Test: TUI mirror config form and platform config forms
# Exercises: Install Mirror menu (local/remote choice), mirror config fields,
# VMware config form, platform settings, all non-destructive (cancel out).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Mirror Config & Platform Test ==="
echo "  Host: $_TUI_HOST"
echo ""

_ssh_cfg="$HOME/.aba/ssh.conf"
scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter  # past splash
tui_assert_appears "Actions" "Main menu" 10

# ============================================================================
# 1. Install Mirror menu (local/remote choice)
# ============================================================================
echo ""
echo "--- 1. Install Mirror menu ---"
tui_select_item "Install Mirror"
sleep 2

# Mirror is already installed on conno, so we should see "reinstall?" dialog
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "already installed\|reinstall\|Uninstall"; then
	echo "  ✓ PASS: Mirror reinstall confirmation appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Press No/Cancel to skip reinstall
	tui_press_button "No" 2>/dev/null || tui_keys Escape
	sleep 1
	tui_screenshot "mc-01-reinstall"
else
	# No mirror installed — should see local/remote choice
	tui_screenshot "mc-01-choice"
	tui_assert_contains "locally\|Install locally" "Local install option"
	tui_assert_contains "remote\|remote host" "Remote install option"

	# Check help
	tui_press_button "Help"
	sleep 2
	tui_assert_contains "mirror registry" "Mirror help mentions registry"
	tui_assert_contains "Local\|local" "Mirror help mentions local"
	tui_assert_contains "Remote\|remote\|SSH" "Mirror help mentions remote"
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
			echo "  ✓ PASS: Local mirror config form appeared"
			_TUI_PASS=$(( _TUI_PASS + 1 ))

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
			echo "  ~ NOTE: Config form not visible"
		fi
	fi

	# Cancel back to main menu
	tui_keys Escape; sleep 1
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
	echo "  ✓ PASS: Platform selection dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
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
		echo "  ✓ PASS: VMware config form appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

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
			echo "  ✓ PASS: vCenter URL populated"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ~ NOTE: vCenter URL not populated (vmware.conf may be template)"
		fi

		# Cancel out without changing anything
		tui_keys Escape; sleep 1
	else
		echo "  ~ NOTE: VMware form not visible — may have gone to a different platform"
		tui_keys Escape; sleep 1
	fi
else
	echo "  ~ NOTE: Platform dialog not visible"
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
	echo "  ~ SKIP: Mirror management items (mirror not installed on this host)"
fi

# Check mode switch items
tui_assert_contains "Switch.*Connected\|Switch.*direct" "Switch to Connected mode item"
tui_assert_contains "Switch.*Disconnected" "Switch to Disconnected mode item"

# Check danger zone
tui_assert_contains "Clean ABA\|remove config" "Clean ABA item"

# Check Advanced help
tui_press_button "Help"
sleep 2
tui_screenshot "mc-03b-advanced-help"
tui_assert_contains "Platform Settings" "Advanced help mentions Platform Settings"
tui_assert_contains "Uninstall Mirror\|Uninstall" "Advanced help mentions Uninstall"
tui_assert_contains "Stop Mirror\|Stop" "Advanced help mentions Stop"
tui_assert_contains "Switch Mode\|Switch" "Advanced help mentions Switch Mode"
tui_assert_contains "Clean ABA\|Refresh\|Clean" "Advanced help mentions Clean"
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
	echo "  ✓ PASS: Feedback dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: Feedback screen unclear"
fi
tui_keys Escape; sleep 1
tui_keys Enter; sleep 1

# ============================================================================
# 5. Cleanup
# ============================================================================
echo ""
echo "--- 5. Cleanup ---"
tui_back_to "Actions" 5
for i in 1 2 3 4 5; do tui_keys Escape; sleep 1; done
sleep 2
if $_TUI_SSH "tmux has-session -t $_TUI_SESSION 2>/dev/null"; then
	tui_keys Enter; sleep 1; tui_keys Escape; sleep 1; tui_keys Enter; sleep 2
fi
_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui' | grep -v grep" 2>/dev/null || true)
if [ -z "$_strays" ]; then
	echo "  ✓ PASS: No stray processes"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Stray processes"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	$_TUI_SSH "pkill -f abatui 2>/dev/null; pkill -f 'dialog --' 2>/dev/null; true"
fi

tui_stop 2>/dev/null
tui_summary
