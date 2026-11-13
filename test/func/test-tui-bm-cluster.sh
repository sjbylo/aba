#!/bin/bash
# Test: TUI bare-metal cluster wizard and install gates.
# SNO continues through Retry after the MACs are fixed, then Yes on the
# boot ask. A vSphere VM is booted only until the agent answers, then removed.
# Compact and standard first stop on a short MAC list. The test then re-opens
# the install wizard, enters the full MAC list, and the install builds the
# agent ISO. Those servers are not booted.
# DESTRUCTIVE on the TUI host: writes platform=bm while it runs, then restores it.
# Creates ~/aba/$TUI_BM_CLUSTER and deletes it at the end.
#
# Default name is sno4 (throwaway-cluster skill). Override with TUI_BM_CLUSTER.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_BM_CLUSTER:-sno4}"
_MAC1="00:50:56:0a:b4:01"
_MAC2="00:50:56:0a:b4:02"

tui_lab_resolve_cluster "$_CLUSTER" || exit 1

echo "=== TUI Bare-metal Cluster Test ==="
echo "  Host: $_TUI_HOST"
echo "  Cluster: $_CLUSTER (starting=$_lab_starting_ip)"
echo ""

_saved_platform=$($_TUI_SSH "grep '^platform=' ~/aba/aba.conf 2>/dev/null | head -1 | cut -d= -f2")
_saved_platform="${_saved_platform:-vmw}"

_restore_platform() {
	$_TUI_SSH "cd ~/aba && aba --platform '$_saved_platform'" >/dev/null 2>&1 || true
}

# Sim VMs are not ABA VMs while platform=bm, so aba delete will not power them off.
_booted=0
_bm_sim_cleanup() {
	[ "$_booted" = 1 ] || return 0
	$_TUI_SSH "cd ~/aba && tools/bm-sim-delete.sh '$_CLUSTER'" >/dev/null 2>&1 || true
}

tui_deploy_code
tui_pre_cleanup
echo ""

tui_start_to_menu || { tui_summary; _restore_platform; exit 1; }
# tui_start_to_menu installs its own EXIT trap. Keep the platform restore with it.
trap 'tui_stop 2>/dev/null; _bm_sim_cleanup; _restore_platform' EXIT

# Delete while aba.conf is still the saved platform, so vmw/kvm VMs are
# destroyed. Bare metal has none. The directory and cluster.conf stay.
tui_delete_cluster "$_CLUSTER"
tui_delete_cluster compact || true
tui_delete_cluster standard || true
echo "  Pre-cleanup: ensuring starting IP $_lab_starting_ip is free..."
if ! tui_ensure_ip_free "$_lab_starting_ip"; then
	echo "  ERROR: IP $_lab_starting_ip still in use"
	tui_summary
	exit 1
fi

_bm_force_platform() {
	local _try _scr
	for _try in 1 2 3 4 5 6; do
		_scr=$(tui_capture)
		if echo "$_scr" | grep -q 'bm (bare-metal)'; then
			return 0
		fi
		tui_keys P; sleep 0.4
		tui_keys Enter; sleep 0.8
	done
	return 1
}

# Replace the MAC edit box. dialog's Delete does not remove a newline, so a
# second prefilled line survives an End/Backspace wipe. Backspace in column 0
# joins the next line; repeat so every prefilled address is gone.
_bm_replace_macs() {
	local mac keys i n
	tui_keys M; sleep 0.4
	tui_keys Enter; sleep 1
	keys="End"
	for i in $(seq 1 40); do
		keys="$keys BSpace"
	done
	for n in $(seq 1 12); do
		keys="$keys Down Home BSpace End"
		for i in $(seq 1 40); do
			keys="$keys BSpace"
		done
	done
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION $keys" 2>/dev/null
	sleep 1
	i=0
	for mac in "$@"; do
		[ "$i" -gt 0 ] && tui_keys Enter
		i=$(( i + 1 ))
		$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$mac'" 2>/dev/null
		sleep 0.2
	done
	tui_keys Tab; sleep 0.2
	tui_keys Enter; sleep 1
}

# The error dialog is modal, so the wizard cannot be opened behind it.
# Retry re-runs the same install. Fix the files from outside, then Retry.
# One vSphere NIC is ens160. 10.0.0.1 does not answer ARP on this lab.
_bm_prepare_boot_conf() {
	$_TUI_SSH "set -e
cd ~/aba/$_CLUSTER
sed -i 's/^ports=.*/ports=ens160/' cluster.conf
if grep -q '^next_hop_address=' cluster.conf; then
	sed -i 's/^next_hop_address=.*/next_hop_address=10.0.1.5/' cluster.conf
else
	echo next_hop_address=10.0.1.5 >> cluster.conf
fi
if grep -q '^master_mem=' cluster.conf; then
	sed -i 's/^master_mem=.*/master_mem=20/' cluster.conf
else
	echo master_mem=20 >> cluster.conf
fi
printf '%s\n' '$_MAC1' > macs.conf
touch cluster.conf macs.conf"
}

_bm_wait_agent() {
	local ip="$1" i code
	i=0
	while [ "$i" -lt 36 ]; do
		code=$($_TUI_SSH "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 http://$ip:8090/ || true")
		echo "  agent $ip:8090 http=$code"
		case "$code" in
			4*) return 0 ;;
		esac
		i=$(( i + 1 ))
		sleep 10
	done
	return 1
}

_bm_set_cluster_name() {
	local name="$1"
	_scr=$(tui_capture)
	# Exact field match — "Cluster name:.*sno" must not match sno4
	if tui_cluster_name_is "$name" "$_scr"; then
		return 0
	fi
	tui_keys N; sleep 0.4
	tui_keys Enter; sleep 0.8
	tui_keys C-u; sleep 0.2
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$name'" 2>/dev/null
	sleep 0.3
	tui_keys Enter
	tui_wait_gone "Enter cluster name" 8 || sleep 1
}

# One unique MAC per line. prefix is the third octet (1a compact, 2a standard).
_bm_mac_lines() {
	local prefix="$1" count="$2" i
	i=1
	while [ "$i" -le "$count" ]; do
		printf '00:50:56:%s:2f:%02x\n' "$prefix" "$i"
		i=$(( i + 1 ))
	done
}

# Compact / standard: prove the type, the VIP fields, and the stop dialog.
# No at the MAC check, so this pass does not build an ISO.
_bm_type_gates() {
	local name="$1" need="$2"
	echo ""
	echo "--- $name: $need MACs, then the stop dialog ---"
	tui_lab_resolve_cluster "$name" || {
		echo "  ✗ FAIL: $name lab DNS"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		return 0
	}
	_open_install
	tui_wait_for "Basics\|Cluster Name\|Name" 10
	_bm_set_cluster_name "$name"
	if tui_force_type "$_lab_type"; then
		echo "  ✓ PASS: $name type is $_lab_type"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: $name type is not $_lab_type"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "bm-${name}-type"
		return 0
	fi
	_bm_force_platform || true
	tui_press_button "Next"
	sleep 2
	tui_wait_for "Network\|Machine\|Starting" 10
	tui_apply_lab_network
	_scr=$(tui_capture)
	if echo "$_scr" | grep -q "API VIP:.*$_lab_api_ip"; then
		echo "  ✓ PASS: $name API VIP is $_lab_api_ip"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: $name API VIP is not $_lab_api_ip"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_press_button "Next"
	sleep 2
	tui_wait_for "Interface\|Ports\|MAC" 10
	tui_keys P; sleep 0.4
	tui_keys Enter; sleep 0.6
	tui_keys C-u; sleep 0.2
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l 'eno1,eno2'" 2>/dev/null
	sleep 0.3
	tui_keys Enter; sleep 1
	_bm_replace_macs "$_MAC1"
	_scr=$(tui_capture)
	tui_screenshot "bm-${name}-warn"
	if echo "$_scr" | grep -q "need $need" && echo "$_scr" | grep -q "Save anyway"; then
		echo "  ✓ PASS: $name asks to save anyway when it needs $need MACs"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: $name did not ask to save anyway when it needs $need MACs"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_keys Enter
	sleep 1
	tui_press_button "Next"
	sleep 2
	tui_wait_for "Review\|Install" 15 || true
	tui_keys Enter
	sleep 2
	# MAC check is asked during Generate configs. It may overlay the progress
	# dialog, or only be visible via Output if the yesno is slow to appear.
	_saw_ask=0
	for _wa in $(seq 1 60); do
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qiE "Bare-metal MAC check|placeholder"; then
			_saw_ask=1
			break
		fi
		# Peek Output while Generate configs is stuck In Progress
		if echo "$_scr" | grep -qi "Generate configs.*In Progress\|Overall Progress"; then
			if (( _wa % 10 == 0 )); then
				tui_keys Space 2>/dev/null || true
				sleep 1
				_scr=$(tui_capture)
				tui_screenshot "bm-${name}-ask-output-${_wa}"
				if echo "$_scr" | grep -qiE "Bare-metal MAC check|placeholder"; then
					_saw_ask=1
					tui_keys q 2>/dev/null || tui_keys Escape
					sleep 1
					break
				fi
				tui_keys q 2>/dev/null || tui_keys Escape
				sleep 1
			fi
		fi
		sleep 3
	done
	if [[ "$_saw_ask" -eq 1 ]]; then
		echo "  ✓ PASS: $name fresh placeholders ask"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		tui_press_button "No" || tui_keys Tab Enter
		sleep 2
	else
		echo "  ✗ FAIL: $name fresh placeholders did not ask"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "bm-${name}-no-ask"
		# Quit a stuck Generate-configs progress so fix_in_wizard can proceed
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Quit.*Q\|Overall Progress"; then
			tui_keys q; sleep 1
			tui_keys Enter 2>/dev/null || true
			sleep 1
		fi
		return 0
	fi
	if tui_wait_for "wizard\|Retry" 60; then
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "wizard" && echo "$_scr" | grep -qi "Retry"; then
			echo "  ✓ PASS: $name stop names the wizard and Retry"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: $name stop text missing wizard or Retry"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
		tui_press_button "Dismiss" || tui_keys Enter
		sleep 2
	else
		echo "  ✗ FAIL: $name had no stop dialog"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_back_to "Actions" 8 || true
}

# The stop dialog is already dismissed. Go back into the wizard, replace the
# short MAC list, and let install build the ISO. No on the boot ask stops
# this run only; there are no servers to boot here.
_bm_fix_in_wizard() {
	local name="$1"
	shift
	local need=$#
	local _n _saw _i
	echo ""
	echo "--- $name: correct $need MACs in the wizard, then build the ISO ---"
	_open_install
	tui_wait_for "Basics\|Cluster Name\|Name" 15
	_bm_set_cluster_name "$name"
	tui_press_button "Next" || tui_keys Tab Enter
	sleep 2
	tui_wait_for "Network\|Machine\|Starting" 15
	tui_press_button "Next" || tui_keys Tab Enter
	sleep 2
	tui_wait_for "Interface\|Ports\|MAC" 15
	_bm_replace_macs "$@"
	_scr=$(tui_capture)
	tui_screenshot "bm-${name}-macs-fixed"
	if echo "$_scr" | grep -q "needs "; then
		echo "  ✗ FAIL: $name still warns after $need MACs"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_keys Enter
		sleep 1
	else
		echo "  ✓ PASS: $name accepts $need MACs"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
	tui_press_button "Next" || tui_keys Tab Enter
	sleep 2
	tui_wait_for "Review\|Install" 20 || true
	tui_press_button "Install" || tui_keys Enter
	sleep 2
	# MAC ask runs under Generate configs. Compact often overlays the yesno on
	# the progress frame; standard has been seen with the prompt only in Output
	# for minutes while the main view stays at Generate configs [In Progress].
	_saw_build=0
	for _wa in $(seq 1 90); do
		_scr=$(tui_capture)
		if echo "$_scr" | grep -q "build the agent ISO" && ! echo "$_scr" | grep -q "Yes: re-check"; then
			_saw_build=1
			break
		fi
		if echo "$_scr" | grep -qi "Generate configs.*In Progress\|Overall Progress"; then
			if (( _wa % 10 == 0 )); then
				tui_keys Space 2>/dev/null || true
				sleep 1
				_scr=$(tui_capture)
				tui_screenshot "bm-${name}-build-output-${_wa}"
				if echo "$_scr" | grep -q "build the agent ISO" && ! echo "$_scr" | grep -q "Yes: re-check"; then
					_saw_build=1
					tui_keys q 2>/dev/null || tui_keys Escape
					sleep 1
					break
				fi
				tui_keys q 2>/dev/null || tui_keys Escape
				sleep 1
			fi
		fi
		sleep 3
	done
	if [[ "$_saw_build" -ne 1 ]]; then
		echo "  ✗ FAIL: $name did not reach the build ask"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "bm-${name}-no-build"
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Quit.*Q\|Overall Progress"; then
			tui_keys q; sleep 1
			tui_keys Enter 2>/dev/null || true
			sleep 1
		fi
		tui_press_button "Dismiss" || true
		tui_back_to "Actions" 8 || true
		return 0
	fi
	_scr=$(tui_capture)
	tui_screenshot "bm-${name}-build-ask"
	echo "  ✓ PASS: $name install asks to build after the wizard fix"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_press_button "Yes" || tui_keys Enter
	sleep 2

	_saw=0
	_i=0
	while [ "$_i" -lt 90 ]; do
		_scr=$(tui_capture)
		if echo "$_scr" | grep -q "Boot servers from the agent ISO"; then
			_saw=1
			tui_screenshot "bm-${name}-iso-ready"
			break
		fi
		# Progress success / ISO on disk also prove the build finished.
		if echo "$_scr" | grep -qi "All steps completed\|steps completed successfully"; then
			_saw=1
			tui_screenshot "bm-${name}-iso-progress-done"
			break
		fi
		if $_TUI_SSH "test -s ~/aba/$name/iso-agent-based/agent.*.iso" 2>/dev/null; then
			_saw=1
			tui_screenshot "bm-${name}-iso-file-ready"
			break
		fi
		if echo "$_scr" | grep -qi "Error\|FAILED" && \
		   echo "$_scr" | grep -qiE '<[[:space:]]*Dismiss|<[[:space:]]*Retry'; then
			tui_screenshot "bm-${name}-iso-error"
			break
		fi
		_i=$(( _i + 1 ))
		sleep 10
	done
	if [ "$_saw" -eq 1 ]; then
		echo "  ✓ PASS: $name built the agent ISO"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		# No servers for this cluster. No stops the run; the ISO is the result.
		tui_press_button "No" 2>/dev/null || tui_keys Tab Enter 2>/dev/null || true
		sleep 2
		tui_press_button "Dismiss" 2>/dev/null || tui_press_button "Done" 2>/dev/null || tui_keys Enter 2>/dev/null || true
		sleep 1
	else
		echo "  ✗ FAIL: $name did not build the agent ISO"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_press_button "Dismiss" 2>/dev/null || tui_keys Escape 2>/dev/null || true
	fi
	_n=$($_TUI_SSH "grep -cve '^[[:space:]]*$' ~/aba/$name/macs.conf 2>/dev/null || echo 0")
	if [ "$_n" = "$need" ]; then
		echo "  ✓ PASS: $name macs.conf has $need addresses"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: $name macs.conf has ${_n:-0} addresses, wanted $need"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if $_TUI_SSH "test -s ~/aba/$name/iso-agent-based/agent.*.iso"; then
		echo "  ✓ PASS: $name agent ISO file exists"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: $name agent ISO file is missing"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_back_to "Actions" 8 || true
}

_open_install() {
	tui_back_to "Actions" 8 || true
	tui_select_item "Install Cluster"
	sleep 1
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "already installed\|New Cluster"; then
		tui_keys Enter
		sleep 2
	fi
}

echo ""
echo "--- 1. Basics: bare metal, SNO, $_CLUSTER ---"
_open_install
tui_wait_for "Basics\|Cluster Name\|Name" 10
tui_screenshot "bm-01-basics"
_scr=$(tui_capture)
if ! tui_cluster_name_is "$_CLUSTER" "$_scr"; then
	tui_keys N; sleep 0.4
	tui_keys Enter; sleep 0.8
	tui_keys C-u; sleep 0.2
	$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l '$_CLUSTER'" 2>/dev/null
	sleep 0.3
	tui_keys Enter
	tui_wait_gone "Enter cluster name" 8 || sleep 1
fi
if tui_force_type sno; then
	echo "  ✓ PASS: type is sno"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: type is not sno"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
if _bm_force_platform; then
	echo "  ✓ PASS: platform is bare metal"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: platform did not become bare metal"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "bm-01-platform-fail"
fi
tui_screenshot "bm-01b-basics"

echo ""
echo "--- 2. Networking ---"
tui_press_button "Next"
sleep 2
tui_wait_for "Network\|Machine\|Starting" 10
tui_apply_lab_network
tui_screenshot "bm-02-network"
tui_press_button "Next"
sleep 2

echo ""
echo "--- 3. Interfaces: two ports, one MAC asks Save anyway ---"
tui_wait_for "Interface\|Ports\|MAC" 10
tui_assert_title "Interfaces" "Interfaces page"
tui_screenshot "bm-03-iface"
# BM skips the VM page, so this must not be VM Resources.
if tui_capture | grep -qi "VM Resources"; then
	echo "  ✗ FAIL: bare metal showed the VM Resources page"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
else
	echo "  ✓ PASS: bare metal skipped VM Resources"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

tui_keys P; sleep 0.4
tui_keys Enter; sleep 0.6
tui_keys C-u; sleep 0.2
$_TUI_SSH "tmux send-keys -t $_TUI_SESSION -l 'eno1,eno2'" 2>/dev/null
sleep 0.3
tui_keys Enter; sleep 1

_bm_replace_macs "$_MAC1"
_scr=$(tui_capture)
tui_screenshot "bm-03-mac-warn"
if echo "$_scr" | grep -q "too few" && echo "$_scr" | grep -q "Save anyway"; then
	echo "  ✓ PASS: short MAC list asks to save anyway"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: expected Save anyway for 1 MAC on 2 ports"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
tui_keys Enter
sleep 1
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Interfaces" && echo "$_scr" | grep -qi "1 entered"; then
	echo "  ✓ PASS: warning did not leave the wizard"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: wizard did not stay on Interfaces after the warning"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "bm-03-after-warn"
fi

echo ""
echo "--- 4. Install with one MAC: ask, then a re-run stops ---"
tui_press_button "Next"
sleep 2
tui_wait_for "Review\|Install" 15
tui_screenshot "bm-04-review"
tui_keys Enter
sleep 2
if ! tui_wait_for "Bare-metal MAC check\|placeholder" 180; then
	echo "  ✗ FAIL: fresh placeholders did not ask"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "bm-04-no-ask"
else
	echo "  ✓ PASS: fresh placeholders ask"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_screenshot "bm-04-ask"
	tui_press_button "No" || tui_keys Tab Enter
	sleep 2
fi

if tui_wait_for "wizard\|Retry\|placeholder" 60; then
	_scr=$(tui_capture)
	tui_screenshot "bm-04-stop"
	if echo "$_scr" | grep -qi "wizard" && echo "$_scr" | grep -qi "Retry"; then
		echo "  ✓ PASS: stop names the wizard and Retry"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: stop text missing wizard or Retry"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_press_button "Retry" || true
	sleep 3
	# Stop dialog uses wizard + Retry; MAC holes show as xx:xx:… (not the word "placeholder").
	if tui_wait_for "wizard\|Retry\|xx:xx:xx\|placeholder" 90; then
		_scr=$(tui_capture)
		tui_screenshot "bm-04-retry"
		if echo "$_scr" | grep -qiE "wizard|placeholder|xx:xx:xx:xx:xx:xx" \
			&& echo "$_scr" | grep -qi "Retry" \
			&& ! echo "$_scr" | grep -qi "Yes: re-check"; then
			echo "  ✓ PASS: Retry of the same placeholders stops without asking again"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: Retry asked again or did not stop"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	else
		echo "  ✗ FAIL: Retry did not return to the stop dialog"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ✗ FAIL: no stop dialog after No"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

echo ""
echo "--- 5. Fix the MAC, Retry, then boot ---"
# The stop dialog is still up. Retry re-runs this install; the wizard is behind it.
_bm_prepare_boot_conf
tui_press_button "Retry" || true
if tui_wait_for "build the agent ISO" 180; then
	_scr=$(tui_capture)
	tui_screenshot "bm-05-retry-ask"
	if echo "$_scr" | grep -q "build the agent ISO" && ! echo "$_scr" | grep -q "Yes: re-check"; then
		echo "  ✓ PASS: Retry after the MAC was fixed asks to build"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Retry after the fix did not ask to build"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	tui_press_button "Yes" || tui_keys Enter
	sleep 2
	_build_yes=1
else
	echo "  ✗ FAIL: Retry after the fix did not ask"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "bm-05-retry-no-ask"
fi

_build_yes=${_build_yes:-0}
if [ "$_build_yes" = 1 ]; then

# Stage nodes stays N/A until the run ends, so the boot ask covers it
# before the list can say No-op. Do not require that label here.
_saw_boot=0
_i=0
while [ "$_i" -lt 90 ]; do
	_scr=$(tui_capture)
	if echo "$_scr" | grep -q "Boot servers from the agent ISO"; then
		_saw_boot=1
		tui_screenshot "bm-05-boot"
		break
	fi
	if echo "$_scr" | grep -qi "Error\|FAILED\|Dismiss"; then
		tui_screenshot "bm-05-error"
		break
	fi
	_i=$(( _i + 1 ))
	sleep 10
done

if [ "$_saw_boot" -eq 1 ]; then
	echo "  ✓ PASS: manual boot ask appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	if echo "$_scr" | grep -q "ISO file:" && ! echo "$_scr" | grep -q "continue.*ISO file:"; then
		echo "  ✓ PASS: boot ask keeps the ISO line"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: boot ask folded the ISO line into the paragraph"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if echo "$_scr" | grep -q "of=/dev/sdX"; then
		echo "  ✓ PASS: dd target is whole on the boot ask"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: of=/dev/sdX was split on the boot ask"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	echo "  Booting the sim VM, then Yes starts monitoring"
	_booted=1
	$_TUI_SSH "ln -sfn ../vmware.conf ~/aba/$_CLUSTER/vmware.conf"
	$_TUI_SSH "cd ~/aba && test -x ~/bin/govc || make -sC cli govc" || true
	if $_TUI_SSH "cd ~/aba && tools/bm-sim-boot.sh $_CLUSTER"; then
		echo "  ✓ PASS: sim VM powered on"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: sim boot failed"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "bm-05-sim-boot"
	fi
	tui_press_button "Yes" || tui_keys Enter
	sleep 2
	if _bm_wait_agent "$_lab_starting_ip"; then
		echo "  ✓ PASS: agent answered after Yes"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: agent did not answer after Yes"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "bm-05-agent"
	fi
	tui_keys q
	sleep 2
	_bm_sim_cleanup
	_booted=0
	tui_back_to "Actions" 8 || true
else
	echo "  ✗ FAIL: boot ask did not appear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
fi

_bm_type_gates compact 6
_bm_fix_in_wizard compact $(_bm_mac_lines 1a 6)
_bm_type_gates standard 10
_bm_fix_in_wizard standard $(_bm_mac_lines 2a 10)

echo ""
echo "--- 6. Delete clears state and leaves the directory ---"
# Restore vmw first so delete destroys a sim VM if one is still on.
_restore_platform
tui_delete_cluster "$_CLUSTER" || true
if $_TUI_SSH "test -d ~/aba/$_CLUSTER && test -f ~/aba/$_CLUSTER/cluster.conf && test ! -f ~/aba/$_CLUSTER/agent-config.yaml"; then
	echo "  ✓ PASS: delete kept the directory and cleared generated state"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: delete did not keep cluster.conf and drop agent-config.yaml"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
_now=$($_TUI_SSH "grep '^platform=' ~/aba/aba.conf | head -1 | cut -d= -f2")
if [ "$_now" = "$_saved_platform" ]; then
	echo "  ✓ PASS: platform restored to $_saved_platform"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: platform is $_now (wanted $_saved_platform)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

tui_cleanup
tui_summary
