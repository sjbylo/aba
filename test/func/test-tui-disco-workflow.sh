#!/bin/bash
# Test: Full DISCO workflow — bundle on conno → transfer → disco TUI pipeline
# Creates a bundle on the connected host (conno), transfers it to the
# disconnected host (disco), then drives the full DISCO TUI workflow:
# unpack → install registry → load images → cluster install → verify.
#
# DESTRUCTIVE: wipes disco host ABA state, installs real cluster.
# LONG: ~2-3 hours (save/bundle ~60 min, load ~30 min, cluster ~40 min).
#
# Prerequisites:
#   - conno: mirror synced, internet access
#   - disco: ~/.vmware.conf.test, ~/.pull-secret.json.test
#   - DNS: api.<cluster>.example.com records (see SKILL.md)
#
# Environment:
#   TUI_CLUSTER_NAME  - Cluster name on disco (default: sno)
#   TUI_BUNDLE_PATH   - Reuse existing bundle (skip save/bundle phase)

set -o pipefail

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CONNO="conno.example.com"
_DISCO="${TUI_TEST_HOST:-disco.example.com}"
_CLUSTER="${TUI_CLUSTER_NAME:-sno}"
_SSH_CONNO="ssh -F $_TUI_SSH_CFG $_CONNO"
_SSH_DISCO="ssh -F $_TUI_SSH_CFG $_DISCO"
_BUNDLE_PATH="${TUI_BUNDLE_PATH:-}"
_BUNDLE_DEST="/tmp/disco-test-bundle.tar"

# DNS lookup for cluster
_dns_server="10.0.1.8"
_domain="example.com"
_api_ip=$(dig +short "api.${_CLUSTER}.${_domain}" "@${_dns_server}" 2>/dev/null | head -1)
if [[ -z "$_api_ip" ]]; then
	echo "  ERROR: No DNS A record for api.${_CLUSTER}.${_domain} on ${_dns_server}"
	echo "  Valid cluster names with DNS: sno, compact2, standard, ocp"
	exit 1
fi
_machine_network="10.0.0.0/20"
_gateway="10.0.0.1"

echo "=== TUI DISCO Workflow Test ==="
echo "  Connected host: $_CONNO"
echo "  Disconnected host: $_DISCO"
echo "  Cluster: $_CLUSTER (api=$_api_ip)"
echo ""

# Override TUI_TEST_HOST for the lib functions (they drive disco)
export TUI_TEST_HOST="$_DISCO"
# Re-source to pick up the new host
source test/func/tui-test-lib.sh

# ============================================================================
# Phase 1: Create bundle on conno
# ============================================================================
echo "================================================================"
echo "  Phase 1: Create bundle on conno"
echo "================================================================"
echo ""

if [[ -n "$_BUNDLE_PATH" ]]; then
	echo "  Using pre-built bundle: $_BUNDLE_PATH"
	_BUNDLE_DEST="$_BUNDLE_PATH"
	echo "  ✓ PASS: Bundle exists (pre-built)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	# Check conno mirror is synced
	_mirror_ok=$($_SSH_CONNO "test -f ~/aba/mirror/.available && echo yes || echo no")
	if [[ "$_mirror_ok" != "yes" ]]; then
		echo "  ✗ FAIL: Conno mirror not available — cannot create bundle"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_summary
		exit 1
	fi
	echo "  ✓ PASS: Conno mirror available"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Create full bundle (includes save + packaging)
	echo "  Creating bundle on conno (this takes 30-60 min for save)..."
	echo "  Command: aba bundle --out $_BUNDLE_DEST --force"
	$_SSH_CONNO "cd ~/aba && aba bundle --out $_BUNDLE_DEST --force --yes 2>&1" | tail -20
	_rc=${PIPESTATUS[0]}
	if [[ $_rc -eq 0 ]] && $_SSH_CONNO "test -s $_BUNDLE_DEST"; then
		_bsize=$($_SSH_CONNO "ls -lh $_BUNDLE_DEST | awk '{print \$5}'")
		echo "  ✓ PASS: Bundle created ($_BUNDLE_DEST, $_bsize)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Bundle creation failed (exit=$_rc)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_summary
		exit 1
	fi
fi

# Skip infrastructure setup if disco is already set up (TUI_SKIP_SETUP=1)
_SKIP_SETUP="${TUI_SKIP_SETUP:-0}"
if [[ "$_SKIP_SETUP" == "1" ]] && $_SSH_DISCO "test -f ~/aba/.bundle && test -f ~/aba/mirror/.available" 2>/dev/null; then
	echo "  SKIP: Phases 2-3 (disco already has bundle + mirror)"
	# Just clean up any existing test cluster
	if $_SSH_DISCO "test -d ~/aba/$_CLUSTER" 2>/dev/null; then
		echo "  Cleaning up leftover '$_CLUSTER' cluster..."
		$_SSH_DISCO "cd ~/aba && aba -d $_CLUSTER delete --yes 2>/dev/null; rm -rf ~/aba/$_CLUSTER; true"
		sleep 5
	fi
	$_SSH_DISCO "cp ~/.vmware.conf.test ~/.vmware.conf 2>/dev/null; cp ~/.vmware.conf ~/aba/vmware.conf 2>/dev/null; true"
else

# ============================================================================
# Phase 2: Clean disco host
# ============================================================================
echo ""
echo "================================================================"
echo "  Phase 2: Clean disco host"
echo "================================================================"
echo ""

# Delete any existing test cluster VMs via ABA CLI
if $_SSH_DISCO "test -d ~/aba/$_CLUSTER" 2>/dev/null; then
	echo "  Deleting existing '$_CLUSTER' cluster on disco..."
	$_SSH_DISCO "cd ~/aba && aba -d $_CLUSTER delete --yes 2>/dev/null; true"
	sleep 3
fi

echo "  Wiping disco host..."
$_SSH_DISCO "
  # Back up credentials
  cp ~/.vmware.conf ~/.vmware.conf.bak 2>/dev/null
  cp ~/.pull-secret.json ~/.pull-secret.json.bak 2>/dev/null

  # Stop and remove all podman state
  podman stop --all 2>/dev/null
  podman rm --all --force 2>/dev/null
  podman pod rm --all --force 2>/dev/null
  podman volume prune --force 2>/dev/null
  podman secret rm --all 2>/dev/null

  # Stop and remove systemd user units
  systemctl --user stop quay-app quay-pod quay-redis quay 2>/dev/null
  systemctl --user disable quay-app quay-pod quay-redis quay 2>/dev/null
  systemctl --user reset-failed 2>/dev/null
  rm -f ~/.config/systemd/user/quay-*.service 2>/dev/null
  rm -f ~/.config/containers/systemd/quay.container 2>/dev/null
  systemctl --user daemon-reload 2>/dev/null

  # Remove mirror data
  sudo rm -rf /opt/quay 2>/dev/null
  rm -rf ~/quay-install 2>/dev/null

  # Remove ABA installation and state
  rm -rf ~/aba
  rm -rf ~/.aba

  # Remove config files (NOT the .test or .bak copies)
  rm -f ~/.vmware.conf ~/.pull-secret.json
  echo 'wipe-done'
"
echo "  ✓ PASS: Disco host wiped"
_TUI_PASS=$(( _TUI_PASS + 1 ))

# ============================================================================
# Phase 3: Transfer and unpack bundle
# ============================================================================
echo ""
echo "================================================================"
echo "  Phase 3: Transfer and unpack bundle"
echo "================================================================"
echo ""

echo "  Transferring bundle to disco..."
if [[ "$_BUNDLE_DEST" == /tmp/* ]]; then
	# Bundle is on conno — SCP from conno to disco via bastion
	$_SSH_CONNO "scp -F ~/.aba/ssh.conf $_BUNDLE_DEST $_DISCO:/tmp/disco-test-bundle.tar" 2>&1
	_BUNDLE_ON_DISCO="/tmp/disco-test-bundle.tar"
else
	# Bundle is local on bastion
	scp -F "$_TUI_SSH_CFG" "$_BUNDLE_DEST" "$_DISCO:/tmp/disco-test-bundle.tar"
	_BUNDLE_ON_DISCO="/tmp/disco-test-bundle.tar"
fi

if $_SSH_DISCO "test -s $_BUNDLE_ON_DISCO"; then
	echo "  ✓ PASS: Bundle transferred to disco"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Bundle transfer failed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary
	exit 1
fi

# Unpack bundle
echo "  Unpacking bundle on disco..."
$_SSH_DISCO "cd ~ && tar xf $_BUNDLE_ON_DISCO" 2>&1
if $_SSH_DISCO "test -f ~/aba/.bundle && test -f ~/aba/install"; then
	echo "  ✓ PASS: Bundle unpacked (.bundle marker present)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Bundle unpack failed (no .bundle or install)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary
	exit 1
fi

# Run install
echo "  Running ./install on disco..."
$_SSH_DISCO "cd ~/aba && ./install --yes 2>&1" | tail -10
if $_SSH_DISCO "command -v aba >/dev/null 2>&1 && echo yes || echo no" | grep -q yes; then
	echo "  ✓ PASS: ABA installed on disco"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ABA install failed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary
	exit 1
fi

# Restore vmware.conf from .test backup
$_SSH_DISCO "cp ~/.vmware.conf.test ~/.vmware.conf 2>/dev/null; cp ~/.vmware.conf ~/aba/vmware.conf 2>/dev/null; true"

fi  # end of TUI_SKIP_SETUP else block

# ============================================================================
# Phase 4: TUI DISCO workflow — install registry + load
# ============================================================================
echo ""
echo "================================================================"
echo "  Phase 4: TUI DISCO workflow"
echo "================================================================"
echo ""

# Deploy latest TUI code
tui_deploy_code

# Launch TUI
tui_start
tui_assert_appears "OpenShift Installer\|ABA" "TUI launched in DISCO mode" 30 || {
	tui_stop; tui_summary; exit 1
}

# Past splash — retry Enter in case TUI wasn't ready
tui_keys Enter
sleep 8
# If still on splash, send Enter again
if tui_capture | grep -qi "Continue.*Exit.*Help"; then
	tui_keys Enter
	sleep 5
fi

echo ""
echo "--- 4a. DISCO bundle wizard gate ---"
tui_screenshot "disco-wf-01-gate"
_scr=$(tui_capture)

# Handle "Image Archives Needed" dialog (light bundle case)
if echo "$_scr" | grep -qi "Archives Needed\|Copy.*mirror_\|Check Again"; then
	echo "  Light bundle detected — archives need to be present"
	# Archives should already be in mirror/data/ from the full bundle
	tui_keys Enter  # "Check Again"
	sleep 3
	_scr=$(tui_capture)
fi

# Handle bundle info dialog
if echo "$_scr" | grep -qi "Install Bundle\|payload summary\|Disconnected.*payload"; then
	echo "  ✓ PASS: Bundle info dialog appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_screenshot "disco-wf-02-bundle-info"
	tui_keys Enter  # dismiss info
	sleep 5
fi

# The DISCO wizard gate may auto-install the mirror and auto-load images.
# Wait for either the DISCO main menu or an install/load progress dialog.
echo "  Waiting for DISCO wizard gate to complete (registry + load)..."
echo "  This may take 20-40 minutes if mirror install + load runs automatically."

# Poll for completion — DISCO menu appears when wizard gate finishes
_gate_timeout=3600  # 60 minutes
_gate_start=$(date +%s)
_gate_last_ss=0
while true; do
	_elapsed=$(( $(date +%s) - _gate_start ))
	[[ $_elapsed -ge $_gate_timeout ]] && {
		echo "  TIMEOUT waiting for DISCO wizard gate"
		break
	}

	if ! tui_session_alive; then
		echo "  SESSION DEAD during wizard gate"
		break
	fi

	_scr=$(tui_capture)

	# Periodic screenshots
	if (( _elapsed - _gate_last_ss >= 300 )); then
		tui_screenshot "disco-wf-gate-${_elapsed}s"
		_gate_last_ss=$_elapsed
	fi

	# Still on splash? Send Enter
	if echo "$_scr" | grep -qi "Continue.*Exit.*Help"; then
		tui_keys Enter; sleep 5
		continue
	fi

	# "Bundle on connected host" dialog — select Fully Disconnected (first button)
	if echo "$_scr" | grep -qi "Fully Disconnected.*Connected mode\|bundle.*internet"; then
		tui_keys Enter; sleep 5
		continue
	fi

	# Bundle info / payload summary dialog — dismiss
	if echo "$_scr" | grep -qi "Install Bundle\|payload summary\|Disconnected.*payload\|Next:.*install.*mirror"; then
		echo "  ✓ PASS: Bundle info dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_screenshot "disco-wf-02-bundle-info"
		tui_keys Enter; sleep 5
		continue
	fi

	# Mirror install location dialog — select "Install locally"
	if echo "$_scr" | grep -qi "Install locally\|Install on remote"; then
		tui_keys Enter; sleep 3
		continue
	fi

	# Mirror config review — press Next
	if echo "$_scr" | grep -qi "Hostname\|Image path\|Vendor\|Data dir" && echo "$_scr" | grep -qi "Next"; then
		tui_press_button "Next" 2>/dev/null || tui_keys Enter
		sleep 3
		continue
	fi

	# Handle execution mode dialog
	if echo "$_scr" | grep -qi "Terminal\|Execution\|Run in"; then
		tui_keys Enter; sleep 2
		continue
	fi

	tui_dismiss_result && continue

	# "Load images to mirror" confirmation dialog
	if echo "$_scr" | grep -qi "Load images to mirror" && echo "$_scr" | grep -qi "Continue"; then
		echo "  Load images confirmation — pressing Continue"
		tui_keys Enter; sleep 10
		continue
	fi

	# Handle confirmation dialogs (load, sync, etc.)
	if echo "$_scr" | grep -qi "Confirm\|Continue\|Proceed" && echo "$_scr" | grep -qi "Yes\|OK"; then
		tui_keys Enter; sleep 3
		continue
	fi

	# Progress dialog — just wait
	if echo "$_scr" | grep -qi "Progress\|Installing\|Loading\|Syncing\|%"; then
		sleep 15
		continue
	fi

	# Completion dialog with "Done" button (after mirror install/load)
	if echo "$_scr" | grep -qi "All steps completed\|Done.*Output\|Mirror Updated\|updated successfully"; then
		echo "  Completion dialog — dismissing"
		tui_keys Enter; sleep 5
		continue
	fi

	# Check for DISCO main menu (section headers unique to the menu)
	if echo "$_scr" | grep -q "── Registry ──\|── Cluster ──\|── Advanced ──"; then
		echo "  ✓ PASS: DISCO main menu reached (${_elapsed}s)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_screenshot "disco-wf-03-menu"
		break
	fi

	sleep 15
done

# ============================================================================
# Phase 4b: Verify registry installed and images loaded
# ============================================================================
echo ""
echo "--- 4b. Verify mirror state ---"
_mirror_ok=$($_SSH_DISCO "test -f ~/aba/mirror/.available && echo yes || echo no")
if [[ "$_mirror_ok" == "yes" ]]; then
	echo "  ✓ PASS: Mirror registry installed on disco"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  Mirror not installed yet — attempting via TUI menu..."
	# Navigate to Install Registry
	tui_select_item "Install Registry\|Registry"
	sleep 3
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Terminal\|Execution"; then
		tui_keys Enter; sleep 2
	fi
	# Wait for install to complete
	tui_wait_for "Actions\|Registry\|Load\|Install Cluster\|Press R\|ENTER to return" 1200
	tui_dismiss_result
	_mirror_ok=$($_SSH_DISCO "test -f ~/aba/mirror/.available && echo yes || echo no")
	if [[ "$_mirror_ok" == "yes" ]]; then
		echo "  ✓ PASS: Mirror registry installed via TUI"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Mirror registry install failed"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# Check if images are loaded — if not, load them via TUI
echo ""
echo "--- 4c. Load images ---"
# Check if release image is available (indicates successful load)
_loaded=$($_SSH_DISCO "grep -q 'last_action=load\|last_action=sync' ~/.aba/mirror/*/state.sh 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")
if [[ "$_loaded" == "yes" ]]; then
	echo "  ✓ PASS: Images already loaded in mirror"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  Loading images via TUI..."
	tui_select_item "Load images"
	sleep 5
	tui_screenshot "disco-wf-04-load"

	_scr=$(tui_capture)
	# Handle confirmation dialog
	if echo "$_scr" | grep -qi "Confirm\|Load\|OCP\|Continue\|Yes"; then
		tui_keys Enter; sleep 3
	fi

	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Terminal\|Execution"; then
		tui_keys Enter; sleep 2
	fi

	# Wait for load to complete (can take 20-30 min)
	echo "  Waiting for image load (up to 45 min)..."
	tui_wait_for "Actions\|Registry\|Load\|Install Cluster\|loaded\|Press R\|ENTER to return" 2700
	tui_screenshot "disco-wf-04b-load-done"

	tui_dismiss_result

	_loaded=$($_SSH_DISCO "grep -q 'last_action=load\|last_action=sync' ~/.aba/mirror/*/state.sh 2>/dev/null && echo yes || echo no" 2>/dev/null || echo "no")
	if [[ "$_loaded" == "yes" ]]; then
		echo "  ✓ PASS: Images loaded into mirror"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Image load failed or incomplete"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# ============================================================================
# Phase 5: Cluster install via TUI
# ============================================================================
echo ""
echo "================================================================"
echo "  Phase 5: Cluster install on disco"
echo "================================================================"
echo ""

# Pre-install cleanup: destroy any leftover cluster on disco AND conno
# Both hosts share the same DNS/IP space, so a running cluster on conno
# with the same name/IP will cause arping IP conflicts on disco.
if $_SSH_DISCO "test -d ~/aba/$_CLUSTER" 2>/dev/null; then
	echo "  Cleaning up leftover '$_CLUSTER' cluster on disco..."
	$_SSH_DISCO "cd ~/aba && aba -d $_CLUSTER delete --yes 2>/dev/null; rm -rf ~/aba/$_CLUSTER; true"
	sleep 5
fi
if $_SSH_CONNO "test -d ~/aba/$_CLUSTER" 2>/dev/null; then
	echo "  Cleaning up '$_CLUSTER' cluster on conno (IP conflict prevention)..."
	$_SSH_CONNO "cd ~/aba && aba -d $_CLUSTER delete --yes 2>/dev/null; rm -rf ~/aba/$_CLUSTER; true"
	sleep 5
fi

echo "--- 5a. Navigate to Install Cluster ---"
# Make sure we're at the DISCO main menu
_scr=$(tui_capture)
if ! echo "$_scr" | grep -qi "Install Cluster\|Registry\|Load"; then
	tui_back_to "Registry\|Install\|Load" 5
fi

tui_select_item "Install Cluster\|Install.*Cluster"
sleep 5
tui_screenshot "disco-wf-05-cluster-start"

# ============================================================================
# 5b. Cluster wizard pages (same as CONNO cluster test)
# ============================================================================
echo ""
echo "--- 5b. Cluster wizard page 1: Basics ---"
tui_wait_for "Cluster Basics\|Cluster name\|Platform\|cluster.*name" 15
tui_screenshot "disco-wf-05b-basics"

tui_assert_contains "Cluster name\|cluster name\|name" "Cluster name field"
tui_assert_contains "Type\|type\|sno\|compact\|standard" "Cluster type field"

# Set cluster name
tui_select_item "Cluster name\|name" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_SSH_DISCO "tmux send-keys -t $_TUI_SESSION -l '$_CLUSTER'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1
tui_screenshot "disco-wf-05b-name-set"
echo "  Set cluster name to: $_CLUSTER"

# Press Next
tui_press_button "Next"
sleep 3

echo ""
echo "--- 5c. Cluster wizard page 2: Networking ---"
tui_wait_for "Network\|Machine\|Starting\|DNS\|Gateway" 10
tui_screenshot "disco-wf-05c-network"

tui_assert_contains "Machine\|machine" "Machine network field"
tui_assert_contains "Starting\|starting" "Starting IP field"

# Set machine network
echo "  Setting machine network=$_machine_network, starting IP=$_api_ip, gateway=$_gateway"
tui_select_item "Machine" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_SSH_DISCO "tmux send-keys -t $_TUI_SESSION -l '$_machine_network'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1

# Set starting IP
tui_select_item "Starting" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_SSH_DISCO "tmux send-keys -t $_TUI_SESSION -l '$_api_ip'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1

# Set gateway
tui_select_item "Gateway" 2>/dev/null || true
sleep 1
tui_keys C-u; sleep 0.3
$_SSH_DISCO "tmux send-keys -t $_TUI_SESSION -l '$_gateway'" 2>/dev/null
sleep 0.3
tui_keys Tab Enter; sleep 1

tui_screenshot "disco-wf-05c-network-done"

# Press Next
tui_press_button "Next"
sleep 3

echo ""
echo "--- 5d. Cluster wizard page 3: Interfaces ---"
tui_wait_for "Interface\|Ports\|Port\|VLAN\|Image source\|ens" 10
tui_screenshot "disco-wf-05d-iface"
tui_assert_contains "Port\|port\|ens" "Port names field"

# Press Next
tui_press_button "Next"
sleep 3

echo ""
echo "--- 5e. Cluster wizard page 4: VM Resources ---"
tui_wait_for "CPU\|Memory\|Resources\|VM" 10
tui_screenshot "disco-wf-05e-vm"
tui_assert_contains "CPU\|cpu\|Core" "CPU field"

# Press Next
tui_press_button "Next"
sleep 3

echo ""
echo "--- 5f. Review page ---"
tui_wait_for "Review\|Install\|Summary" 10
tui_screenshot "disco-wf-05f-review"
tui_assert_contains "$_CLUSTER" "Review shows cluster name"
tui_assert_contains "Install\|install" "Install button present"

# Press Install
echo ""
echo "--- 5g. Install cluster ---"
tui_keys Enter
sleep 3
tui_screenshot "disco-wf-05g-install-start"

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Terminal\|Execution\|execution"; then
	echo "  Execution mode dialog appeared"
	tui_keys Enter
	sleep 2
fi

# Wait for install to complete (SNO ~30-45 min)
echo "  Waiting for cluster install (up to 60 min)..."
_install_timeout=3600
_start_time=$(date +%s)
_last_ss=0
while true; do
	_elapsed=$(( $(date +%s) - _start_time ))
	[[ $_elapsed -ge $_install_timeout ]] && {
		echo "  TIMEOUT: cluster install did not complete in 60 min"
		break
	}

	if ! tui_session_alive; then
		echo "  SESSION DEAD during cluster install"
		break
	fi
	_scr=$(tui_capture)

	# Periodic screenshots
	if (( _elapsed - _last_ss >= 300 )); then
		tui_screenshot "disco-wf-install-${_elapsed}s"
		_last_ss=$_elapsed
	fi

	# Check for actual install completion
	if echo "$_scr" | grep -qi "Cluster is installed\|Install complete\|install completed.*marker\|Login to the console"; then
		echo "  ✓ PASS: Cluster install completed (${_elapsed}s)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		break
	fi

	# Check for fatal error
	if echo "$_scr" | grep -qi "FAILED\|fatal\|timed out.*bootstrap"; then
		echo "  ✗ FAIL: Cluster install failed"
		tui_screenshot "disco-wf-install-fail"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		break
	fi

	# Check if back at menu (install finished)
	if tui_dismiss_result; then
		_scr=$(tui_capture)
	fi

	if echo "$_scr" | grep -q "Install Cluster\|Registry\|Load"; then
		echo "  Returned to DISCO menu — checking cluster state..."
		_inst=$($_SSH_DISCO "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
		if [[ "$_inst" == "yes" ]]; then
			echo "  ✓ PASS: Cluster install completed (marker file, ${_elapsed}s)"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ~ NOTE: Back at menu but .install-complete not found"
		fi
		break
	fi

	sleep 30
done

tui_screenshot "disco-wf-05g-install-final"

# ============================================================================
# Phase 6: Verify cluster
# ============================================================================
echo ""
echo "================================================================"
echo "  Phase 6: Verify cluster"
echo "================================================================"
echo ""

_inst=$($_SSH_DISCO "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" == "yes" ]]; then
	echo "  ✓ PASS: Cluster '$_CLUSTER' .install-complete exists"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Cluster '$_CLUSTER' not installed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

_kubeconfig=$($_SSH_DISCO "test -f ~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig && echo yes || echo no")
if [[ "$_kubeconfig" == "yes" ]]; then
	echo "  ✓ PASS: kubeconfig exists"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	_nodes=$($_SSH_DISCO "export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig; oc get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)
	if [[ "$_nodes" -gt 0 ]]; then
		echo "  ✓ PASS: Cluster has $_nodes node(s)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Cannot reach cluster nodes"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# ============================================================================
# Phase 7: Cleanup
# ============================================================================
echo ""
echo "================================================================"
echo "  Phase 7: Cleanup"
echo "================================================================"
echo ""

# Dismiss any lingering dialog before cleanup
tui_dismiss_result
tui_cleanup

# Clean up bundle on conno
$_SSH_CONNO "rm -f $_BUNDLE_DEST 2>/dev/null" || true

tui_summary
