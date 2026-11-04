#!/bin/bash
# Test: TUI cluster workflow — wizard pages, review, install, monitor
# Creates a throwaway cluster via the TUI wizard on VMware.
# DESTRUCTIVE: creates VMs and installs a real cluster.
# Prereqs: mirror installed + synced, vmware.conf, pull-secret.
#
# Uses cluster name "sno" by default (must have DNS A records).
# Set TUI_CLUSTER_NAME to override — see throwaway-cluster skill IP table:
#   sno sno2 sno3 sno4 compact compact2 standard ocp
# Lab defaults (DNS/NTP/GW/network/ports) come from tui_lab_* helpers.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"

# Resolve starting_ip / API / APPS from throwaway-cluster skill and verify DNS.
tui_lab_resolve_cluster "$_CLUSTER" || exit 1

echo "=== TUI Cluster Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER (type=$_lab_type starting=$_lab_starting_ip api=$_lab_api_ip)"
echo ""

tui_deploy_code
tui_pre_cleanup
echo ""

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# Pre-test cleanup: ALWAYS delete via TUI first (aba delete fallback).
# Never rm -rf the cluster dir before delete — that orphans VMs.
tui_delete_cluster "$_CLUSTER"

# Wait for node0 (starting_ip) to be free after delete.
echo "  Pre-cleanup: ensuring starting IP $_lab_starting_ip is free..."
if ! tui_ensure_ip_free "$_lab_starting_ip"; then
	echo "  ERROR: IP $_lab_starting_ip still in use after TUI/aba delete — cannot proceed"
	tui_stop
	tui_summary
	exit 1
fi

# ============================================================================
# 1. Open cluster install wizard
# ============================================================================
echo ""
echo "--- 1. Cluster wizard page 1: Basics ---"
tui_select_item "Install Cluster"
sleep 1
tui_screenshot "cl-01-start"

# The wizard auto-detects existing cluster "sno" which is installed.
# It should offer "New Cluster". Accept that.
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "already installed\|New Cluster"; then
	echo "  Detected existing cluster prompt"
	tui_keys Enter  # select "New Cluster"
	sleep 2
fi

# Page 1: Basics — should show cluster name, type, platform
tui_wait_for "Basics\|Cluster Name\|cluster_name\|Name\|Type" 10
tui_assert_title "Basics" "Basics page title"
tui_screenshot "cl-01b-basics"
tui_assert_contains "Name\|name" "Cluster name field"
tui_assert_contains "Type\|type\|sno\|compact\|standard" "Cluster type field"

# Set cluster name if not already correct (fresh install has default name)
# Must check the "Cluster name:" line specifically, not just any "sno" on screen
# (the Type field also shows "sno" which would false-match)
_scr=$(tui_capture)
if ! echo "$_scr" | grep -qi "Cluster name:.*$_CLUSTER"; then
	echo "  Setting cluster name to $_CLUSTER (current: $(echo "$_scr" | grep -oi 'Cluster name:[^│]*' | head -1 | sed 's/Cluster name:[[:space:]]*//'))"
	# Press N to highlight the cluster-name item, Enter to open inputbox
	tui_keys N; sleep 0.5
	tui_keys Enter; sleep 1
	tui_screenshot "cl-01b-name-inputbox"
	# Clear old value and type the correct name
	tui_keys C-u; sleep 0.3
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$_CLUSTER'" 2>/dev/null
	sleep 0.3
	tui_keys Enter; sleep 1
	tui_screenshot "cl-01b-name-set"
fi
# Verify the name field specifically (not just Type which also contains "sno")
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Cluster name:.*$_CLUSTER"; then
	echo "  ✓ PASS: Cluster name set to $_CLUSTER"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Cluster name not set (expected $_CLUSTER)"
	echo "    Current: $(echo "$_scr" | grep -oi 'Cluster name:[^│]*' | head -1)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
# Force Type from skill table (SNO leftover "standard" fails VIP validation).
if tui_force_type "$_lab_type"; then
	echo "  ✓ PASS: Cluster type is $_lab_type"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Cluster type not $_lab_type (got: $(tui_capture | grep -oiE 'Type:[^│]*' | head -1))"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_assert_contains "sno\|compact\|standard" "Cluster type shown"
tui_screenshot "cl-01c-basics-detail"

# Advance to page 2: press Next (focus is on first button after menu loads)
tui_press_button "Next"
sleep 2
tui_screenshot "cl-01e-after-basics"

# ============================================================================
# 2. Page 2: Networking
# ============================================================================
echo ""
echo "--- 2. Cluster wizard page 2: Networking ---"
tui_wait_for "Network\|Machine\|Starting\|DNS\|Gateway" 10
tui_assert_title "Networking" "Networking page title"
tui_screenshot "cl-02-network"

tui_assert_contains "Machine\|machine" "Machine network field"
tui_assert_contains "Starting\|starting" "Starting IP field"
tui_assert_contains "DNS\|dns" "DNS field"
tui_assert_contains "Gateway\|gateway" "Gateway field"

# Apply throwaway-cluster skill values (machine/starting/VIPs/DNS/GW/NTP).
# starting_ip ≠ API for compact/standard — never use dig API as starting_ip.
tui_apply_lab_network
tui_assert_contains "${TUI_LAB_MACHINE_NETWORK}\|${_lab_starting_ip}" "Network values set correctly"
tui_screenshot "cl-02c-network-detail"

# Advance to page 3
tui_press_button "Next"
sleep 1

# ============================================================================
# 3. Page 3: Interfaces
# ============================================================================
echo ""
echo "--- 3. Cluster wizard page 3: Interfaces ---"
tui_wait_for "Interface\|Ports\|Port\|VLAN\|Image source\|ens" 10
tui_assert_title "Interfaces" "Interfaces page title"
tui_screenshot "cl-03-iface"

tui_assert_contains "Port\|port\|ens" "Port names field"
tui_assert_contains "Image source\|image source\|mirror\|direct" "Image source field"
tui_apply_lab_ports

# Advance to page 4
tui_press_button "Next"
sleep 1

# ============================================================================
# 4. Page 4: VM Resources (VMware/KVM only)
# ============================================================================
echo ""
echo "--- 4. Cluster wizard page 4: VM Resources ---"
tui_wait_for "CPU\|Memory\|Master\|VM\|Resources\|Data" 10
tui_assert_title "VM Resources\|Resources" "VM Resources page title"
tui_screenshot "cl-04-vm"

tui_assert_contains "CPU\|cpu\|vCPU" "CPU field"
tui_assert_contains "Memory\|memory\|RAM\|Mem" "Memory field"

# Check help
# Advance to review page
tui_press_button "Next"
sleep 1

# ============================================================================
# 5. Review page
# ============================================================================
echo ""
echo "--- 5. Review page ---"
tui_wait_for "Review\|Confirm\|Install" 10
tui_assert_title "Install Cluster\|Review" "Review page title"
sleep 1
tui_screenshot "cl-05-review"

# Verify review shows our cluster info
tui_assert_contains "$_CLUSTER" "Review shows cluster name"
tui_assert_contains "sno\|compact\|standard" "Review shows cluster type"
tui_assert_contains "VMware\|vmw\|ESXi" "Review shows platform"
tui_assert_contains "Network\|network\|10\." "Review shows network info"
tui_assert_contains "Install\|install" "Install button present"

# ============================================================================
# 6. Execute install
# ============================================================================
echo ""
echo "--- 6. Install cluster ---"
# Press Install button
tui_keys Enter
sleep 1
tui_screenshot "cl-06-install-start"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Terminal\|Run in Terminal\|Execution\|execution"; then
	echo "  Execution mode dialog appeared"
	tui_keys Enter
	sleep 1
fi

# Wait for install using the common progress helper (60 min timeout)
echo "  Waiting for cluster install to complete (up to 60 min)..."
echo "  (Monitor: ssh to $_TUI_HOST and check 'tmux a -t $_TUI_SESSION')"

if tui_wait_for_progress "cl-06" 3600; then
	echo "  ✓ PASS: Cluster install completed successfully"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Cluster install failed"
	tui_screenshot "cl-06-install-fail"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

tui_dismiss_result
tui_screenshot "cl-06-final"

# ============================================================================
# 7. Verify cluster state
# ============================================================================
echo ""
echo "--- 7. Verify cluster state ---"
_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" == "yes" ]]; then
	echo "  ✓ PASS: Cluster '$_CLUSTER' .install-complete exists"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Cluster '$_CLUSTER' not installed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify cluster is reachable
_kubeconfig=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig && echo yes || echo no")
if [[ "$_kubeconfig" == "yes" ]]; then
	echo "  ✓ PASS: kubeconfig exists"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	_nodes=$($_TUI_SSH "export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig; oc get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)
	if [[ "$_nodes" -gt 0 ]]; then
		echo "  ✓ PASS: Cluster has $_nodes node(s)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Cannot reach cluster nodes"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# ============================================================================
# 8. Cleanup
# ============================================================================
echo ""
echo "--- 8. Cleanup ---"
# Dismiss any lingering completion dialog before cleanup
tui_dismiss_result
tui_cleanup
tui_summary
