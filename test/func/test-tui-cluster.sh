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
_ssh_cfg="$HOME/.aba/ssh.conf"

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

# Pre-test cleanup: destroy any leftover cluster VMs and state from prior runs
if $_TUI_SSH "test -d ~/aba/$_CLUSTER" 2>/dev/null; then
	echo "  Cleaning up leftover '$_CLUSTER' cluster from prior run..."
	$_TUI_SSH "cd ~/aba && aba -d $_CLUSTER delete --yes 2>/dev/null; rm -rf ~/aba/$_CLUSTER; true"
	sleep 5
fi

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
# 1. Open cluster install wizard
# ============================================================================
echo ""
echo "--- 1. Cluster wizard page 1: Basics ---"
tui_select_item "Install Cluster"
sleep 3
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

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "Cluster name\|cluster name" "Basics help content"
tui_assert_contains "sno\|compact\|standard" "Help describes cluster types"
tui_screenshot "cl-01c-basics-help"
tui_keys Enter; sleep 1

# Set cluster name to our test name
# Find the name field and select it
tui_select_item "Name" 2>/dev/null || tui_select_item "name" 2>/dev/null || {
	# Try selecting first menu item
	tui_keys Enter
}
sleep 1
tui_screenshot "cl-01d-name-input"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Cluster Name\|Enter.*name\|cluster name"; then
	# Clear existing name and type our test name
	# Ctrl-U clears the input line, then type new name
	tui_keys C-u
	sleep 0.3
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$_CLUSTER'" 2>/dev/null
	sleep 0.3
	tui_keys Tab Enter
	sleep 2
	echo "  Set cluster name to: $_CLUSTER"
fi

# Make sure we're back on the Basics menu (not stuck in an input dialog)
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Enter cluster name\|Use Tab to navigate"; then
	echo "  Input dialog still open — pressing Tab Enter to dismiss"
	tui_keys Tab Enter
	sleep 2
fi

# Advance to page 2 (Next button)
tui_press_button "Next" 2>/dev/null || tui_press_button "OK" 2>/dev/null || tui_keys Enter
sleep 3  # cluster.conf generation may take a moment
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

# Check help
tui_press_button "Help"
sleep 2
tui_assert_contains "Machine network\|machine network\|CIDR" "Network help content"
tui_screenshot "cl-02b-network-help"
tui_keys Enter; sleep 1

# Set correct machine network to match DNS records
echo "  Setting machine network=$_machine_network, starting IP=$_api_ip, gateway=$_gateway"
tui_select_item "Machine" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$_machine_network'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1

# Set starting IP
tui_select_item "Starting" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$_api_ip'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1

# Set gateway
tui_select_item "Gateway" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$_gateway'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1

tui_screenshot "cl-02c-network-updated"

# Advance to page 3
tui_press_button "Next" 2>/dev/null || tui_keys Enter
sleep 2

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
tui_press_button "Help"
sleep 2
tui_assert_contains "Ports\|ports\|NIC" "Interface help content"
tui_screenshot "cl-03b-iface-help"
tui_keys Enter; sleep 1

# Advance to page 4
tui_press_button "Next" 2>/dev/null || tui_keys Enter
sleep 2

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
tui_press_button "Help"
sleep 2
tui_assert_contains "vCPU\|CPU\|Memory\|RAM" "VM resources help content"
tui_screenshot "cl-04b-vm-help"
tui_keys Enter; sleep 1

# Advance to review page
tui_press_button "Next" 2>/dev/null || tui_keys Enter
sleep 2

# ============================================================================
# 5. Review page
# ============================================================================
echo ""
echo "--- 5. Review page ---"
tui_wait_for "Review\|Confirm\|Install" 10
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
sleep 3
tui_screenshot "cl-06-install-start"

# At this point the TUI will either:
# a) Show execution options (terminal/TUI mode)
# b) Start the install directly
# c) Show a confirmation dialog

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Terminal\|Run in Terminal\|Execution\|execution"; then
	echo "  Execution mode dialog appeared"
	# Select "Run in Terminal" for visible output
	tui_keys Enter
	sleep 2
fi

# Wait for install to complete (SNO takes ~30-45 min on VMware)
echo "  Waiting for cluster install to complete (up to 60 min)..."
echo "  (Monitor: ssh to $_TUI_HOST and check 'tmux a -t $_TUI_SESSION')"

# Poll for completion indicators
_install_timeout=3600  # 60 minutes
_start_time=$(date +%s)
_last_screenshot=0
while true; do
	_elapsed=$(( $(date +%s) - _start_time ))
	[[ $_elapsed -ge $_install_timeout ]] && break

	if ! tui_session_alive; then
		echo "  SESSION DEAD during cluster install"
		break
	fi
	_scr=$(tui_capture)

	# Take periodic screenshots (every 5 min)
	if (( _elapsed - _last_screenshot >= 300 )); then
		tui_screenshot "cl-06-progress-${_elapsed}s"
		_last_screenshot=$_elapsed
	fi

	# Check for actual install completion (not "ready for install" or command name)
	if echo "$_scr" | grep -qi "Cluster is installed\|Install complete\|install completed.*marker\|Login to the console"; then
		echo "  ✓ PASS: Cluster install completed successfully (${_elapsed}s)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		break
	fi

	# Check for fatal error
	if echo "$_scr" | grep -qi "FAILED\|fatal\|timed out.*bootstrap"; then
		echo "  ✗ FAIL: Cluster install failed"
		tui_screenshot "cl-06-install-fail"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		break
	fi

	tui_dismiss_result && continue

	# Check if we're back at main menu (install finished)
	if echo "$_scr" | grep -q "Actions"; then
		echo "  Returned to main menu — checking cluster state..."
		_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
		if [[ "$_inst" == "yes" ]]; then
			echo "  ✓ PASS: Cluster install completed (marker file exists, ${_elapsed}s)"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ~ NOTE: Back at menu but .install-complete not found yet"
		fi
		break
	fi

	sleep 30
done
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
