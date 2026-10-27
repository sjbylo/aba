#!/bin/bash
# Test: TUI cluster install wizard page navigation
# Exercises all 4 wizard pages (Basics, Network, Interfaces, VM Resources)
# plus the review page — without executing the install.
# Non-destructive: always cancels before executing.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Cluster Wizard Page Test ==="
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
# 1. Enter cluster install flow
# ============================================================================
echo ""
echo "--- 1. Enter cluster install ---"
tui_select_item "Install Cluster"
sleep 3
tui_screenshot "cp-01-entry"

# Handle gates: "Mirror Required", "Cluster Already Installed"
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Mirror Required\|No mirror.*installed\|mirror.*required"; then
	echo "  ✓ PASS: Mirror Required gate appeared (mirror not installed)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Press "Back" — can't proceed without mirror in CONNO mode
	tui_press_button "Back" 2>/dev/null || tui_keys Escape
	sleep 1
	echo "  ~ SKIP: Cluster wizard pages require an installed mirror in CONNO mode"
	echo "  ~ SKIP: Run this test on a host with an installed mirror, or in DIRECT mode"
	echo ""
	echo "--- Cleanup ---"
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
	exit 0
fi

if echo "$_scr" | grep -qi "already installed\|Cluster Already"; then
	echo "  ✓ PASS: Cluster already installed dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# Press "New Cluster" to create a new one
	tui_press_button "New Cluster" 2>/dev/null || tui_keys Enter
	sleep 2
fi

# Platform config gate (may ask to configure VMware/KVM)
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Platform.*not configured\|vmware.conf\|kvm.conf\|Configure.*Platform"; then
	echo "  ✓ PASS: Platform config gate appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	# The platform config form may appear — cancel it
	tui_keys Escape; sleep 1
	tui_keys Escape; sleep 1
fi

# ============================================================================
# 2. Page 1: Basics
# ============================================================================
echo ""
echo "--- 2. Page 1: Basics ---"
# Wait for the basics page to appear
sleep 3
tui_screenshot "cp-02-basics"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Cluster Name\|cluster type\|Domain\|Workers"; then
	echo "  ✓ PASS: Basics page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check basics page fields
	tui_assert_contains "Cluster Name\|Name" "Cluster Name field"
	tui_assert_contains "Domain\|domain" "Domain field"
	tui_assert_contains "Cluster type\|Type\|sno\|compact\|standard" "Cluster type field"

	# Check for platform info
	if echo "$_scr" | grep -qi "vmw\|VMware\|kvm\|Bare Metal"; then
		echo "  ✓ PASS: Platform info visible"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Discover page items
	echo "  Basics page items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Check for Next button
	_btns=$(tui_buttons)
	if echo "$_btns" | grep -qi "Next"; then
		echo "  ✓ PASS: Next button present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Press Next to go to Page 2
	tui_press_button "Next" 2>/dev/null || { tui_keys Tab; sleep 0.3; tui_keys Enter; }
	sleep 3
else
	echo "  ✗ FAIL: Basics page not visible"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_stop; tui_summary; exit 1
fi

# ============================================================================
# 3. Page 2: Network
# ============================================================================
echo ""
echo "--- 3. Page 2: Network ---"
tui_screenshot "cp-03-network"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Network\|CIDR\|Subnet\|DNS\|Gateway\|API VIP\|Starting IP"; then
	echo "  ✓ PASS: Network page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check network page fields
	tui_assert_contains "Subnet\|CIDR\|Machine Network" "Subnet/CIDR field"
	tui_assert_contains "DNS" "DNS field"
	tui_assert_contains "Gateway\|Next hop\|next_hop" "Gateway field"

	# Check for VIP fields (only for compact/standard, not SNO)
	if echo "$_scr" | grep -qi "API VIP\|api_vip"; then
		echo "  ✓ PASS: API VIP field present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "Ingress VIP\|ingress_vip"; then
		echo "  ✓ PASS: Ingress VIP field present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Discover page items
	echo "  Network page items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Press Next to go to Page 3
	tui_press_button "Next" 2>/dev/null || { tui_keys Tab; sleep 0.3; tui_keys Enter; }
	sleep 2
else
	echo "  ~ NOTE: Network page unclear (may have auto-skipped)"
fi

# ============================================================================
# 4. Page 3: Interfaces
# ============================================================================
echo ""
echo "--- 4. Page 3: Interfaces ---"
tui_screenshot "cp-04-iface"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Interface\|Port\|MAC\|NIC\|ens\|enp"; then
	echo "  ✓ PASS: Interfaces page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check interface fields
	tui_assert_contains "NIC\|Port\|Interface\|ens\|enp" "NIC/Port field"

	# Check for MAC address fields
	if echo "$_scr" | grep -qi "MAC"; then
		echo "  ✓ PASS: MAC address field present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Discover page items
	echo "  Interfaces page items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Press Next to go to Page 4 (VM resources, if virt platform)
	tui_press_button "Next" 2>/dev/null || { tui_keys Tab; sleep 0.3; tui_keys Enter; }
	sleep 2
else
	echo "  ~ NOTE: Interfaces page unclear"
fi

# ============================================================================
# 5. Page 4: VM Resources (only for VMware/KVM)
# ============================================================================
echo ""
echo "--- 5. Page 4: VM Resources ---"
tui_screenshot "cp-05-vm"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "VM Resources\|CPU\|Memory\|Disk\|vCPU\|RAM"; then
	echo "  ✓ PASS: VM Resources page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check VM resource fields
	tui_assert_contains "CPU\|vCPU" "CPU field"
	tui_assert_contains "Memory\|RAM\|MiB\|GiB" "Memory field"
	tui_assert_contains "Disk\|Storage\|GB" "Disk field"

	# Check for master/worker separation
	if echo "$_scr" | grep -qi "Master\|master\|Control"; then
		echo "  ✓ PASS: Master resources section present"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Discover page items
	echo "  VM Resources page items:"
	tui_menu_items | while IFS=$'\t' read -r key label; do
		echo "    [$key] $label"
	done

	# Press Next to go to review
	tui_press_button "Next" 2>/dev/null || { tui_keys Tab; sleep 0.3; tui_keys Enter; }
	sleep 2
elif echo "$_scr" | grep -qi "Review\|Summary\|Install\|Confirm"; then
	echo "  ~ SKIP: VM Resources page (bare metal skips this page)"
fi

# ============================================================================
# 6. Page 5: Review page
# ============================================================================
echo ""
echo "--- 6. Review page ---"
tui_screenshot "cp-06-review"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Review\|Summary\|Install\|Confirm\|cluster.conf"; then
	echo "  ✓ PASS: Review page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Check review contains key config items
	if echo "$_scr" | grep -qi "cluster_name\|Cluster Name\|Name:"; then
		echo "  ✓ PASS: Review shows cluster name"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	if echo "$_scr" | grep -qi "domain\|Domain"; then
		echo "  ✓ PASS: Review shows domain"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi

	# Check for Back and Install buttons
	_btns=$(tui_buttons)
	echo "  Review buttons: $_btns"

	# Press Back or Cancel — do NOT press Install
	if echo "$_btns" | grep -qi "Back"; then
		echo "  ✓ PASS: Back button available on review"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_press_button "Back"
		sleep 1
	else
		tui_keys Escape; sleep 1
	fi
else
	echo "  ~ NOTE: Review page not visible (may depend on wizard state)"
fi

# ============================================================================
# 7. Navigate back through pages (test Back button)
# ============================================================================
echo ""
echo "--- 7. Back navigation ---"
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "VM Resources\|Interface\|Network\|Basics\|Cluster"; then
	echo "  ✓ PASS: Back navigation returned to a wizard page"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# Cancel out of the wizard entirely — need enough Escapes for all wizard pages
# plus any confirmation dialogs
for _i in 1 2 3 4 5 6 7 8; do
	tui_keys Escape; sleep 0.5
	# Dismiss any "Cancel wizard?" confirmation
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Actions"; then
		break
	fi
	if echo "$_scr" | grep -qi "cancel\|discard\|sure\|abort"; then
		tui_keys Enter; sleep 0.5
	fi
done
sleep 1

# ============================================================================
# 8. Verify we're back at main menu
# ============================================================================
echo ""
echo "--- 8. Return to main menu ---"
tui_back_to "Actions" 10
tui_assert_contains "Actions" "Back at main menu after wizard cancel"

# ============================================================================
# 9. Cleanup
# ============================================================================
echo ""
echo "--- 9. Cleanup ---"
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
