#!/bin/bash
# Test: TUI cluster workflow — wizard pages, review, install, monitor
# Creates a new SNO cluster via the TUI wizard on VMware.
# DESTRUCTIVE: creates VMs and installs a real cluster.
# Prereqs: mirror installed + synced, vmware.conf, pull-secret.
#
# Uses cluster name "sno" by default (must have DNS A records).
# Set TUI_CLUSTER_NAME to override (valid: sno, compact2, standard, ocp).

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"

# Look up the DNS-registered API IP for this cluster name.
# The starting_ip MUST match the DNS A record for api.<name>.<domain>.
_dns_server="10.0.1.8"
_domain="example.com"
_api_ip=$(dig +short "api.${_CLUSTER}.${_domain}" "@${_dns_server}" 2>/dev/null | head -1)
if [[ -z "$_api_ip" ]]; then
	echo "  ERROR: No DNS A record for api.${_CLUSTER}.${_domain} on ${_dns_server}"
	echo "  Valid cluster names with DNS: sno, compact2, standard, ocp"
	exit 1
fi
# Derive machine network from the API IP (assumes /20 on 10.0.x.x)
_machine_network="10.0.0.0/20"
_gateway="10.0.0.1"

echo "=== TUI Cluster Workflow Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER"
echo ""

tui_deploy_code
tui_pre_cleanup
echo ""

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# Pre-test cleanup: delete any leftover cluster via the TUI
tui_delete_cluster "$_CLUSTER"

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
tui_screenshot "cl-01b-basics"
tui_assert_contains "Name\|name" "Cluster name field"
tui_assert_contains "Type\|type\|sno\|compact\|standard" "Cluster type field"

# Verify cluster name and type are shown correctly
tui_assert_contains "$_CLUSTER" "Cluster name pre-filled"
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
tui_screenshot "cl-02-network"

tui_assert_contains "Machine\|machine" "Machine network field"
tui_assert_contains "Starting\|starting" "Starting IP field"
tui_assert_contains "DNS\|dns" "DNS field"
tui_assert_contains "Gateway\|gateway" "Gateway field"

# Values pre-filled from cluster.conf — verify, no need to edit
tui_assert_contains "$_machine_network\|$_api_ip" "Network values pre-filled"
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
tui_screenshot "cl-03-iface"

tui_assert_contains "Port\|port\|ens" "Port names field"
tui_assert_contains "Image source\|image source\|mirror\|direct" "Image source field"

# Check help
# Advance to page 4
tui_press_button "Next"
sleep 1

# ============================================================================
# 4. Page 4: VM Resources (VMware/KVM only)
# ============================================================================
echo ""
echo "--- 4. Cluster wizard page 4: VM Resources ---"
tui_wait_for "CPU\|Memory\|Master\|VM\|Resources\|Data" 10
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
