#!/bin/bash
# Focused regression: Detecting… + Select-cluster must clear, then day2 must
# reach a verified success (no soft PASS on timeout / menu-after-error).
# Reproduces the Upgrade day-2 hang from TUI_ALL_REPORT_20261110.
#
# Prereq for full wait success: a reachable installed cluster ($_CLUSTER).
# Extra leftover .install-complete dirs are created only for the picker race.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_CLUSTER="${TUI_CLUSTER_NAME:-sno}"

echo "=== TUI Cluster-Select Race Regression ==="
echo "  Host: $_TUI_HOST  Cluster: $_CLUSTER"
echo ""

tui_deploy_code
tui_pre_cleanup

# Extra leftover markers so Detecting / Select-cluster appears (post-BM shape).
# Do not invent a fake marker for $_CLUSTER if it is already installed — that
# cluster must be reachable for the hard day2 wait below.
_csr_created_markers=""
for _d in compact standard ocp; do
	[[ "$_d" == "$_CLUSTER" ]] && continue
	if ! $_TUI_SSH "test -f ~/aba/$_d/.install-complete" 2>/dev/null; then
		$_TUI_SSH "mkdir -p ~/aba/$_d && touch ~/aba/$_d/.install-complete" >/dev/null
		_csr_created_markers="$_csr_created_markers $_d"
	fi
done

_csr_cleanup_markers() {
	for _d in $_csr_created_markers; do
		$_TUI_SSH "rm -f ~/aba/$_d/.install-complete" >/dev/null 2>&1 || true
	done
}
trap _csr_cleanup_markers EXIT

# Hard prereq: our cluster must actually be installed and reachable
_inst=$($_TUI_SSH "test -f ~/aba/$_CLUSTER/.install-complete && echo yes || echo no")
if [[ "$_inst" != "yes" ]]; then
	echo "  ✗ FAIL: Cluster '$_CLUSTER' not installed — race test needs a live cluster"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary; exit 1
fi
_api_ok=$($_TUI_SSH "
	export KUBECONFIG=~/aba/$_CLUSTER/iso-agent-based/auth/kubeconfig
	timeout 20 oc get --raw=/readyz >/dev/null 2>&1 && echo yes || echo no
" 2>/dev/null || echo no)
if [[ "$_api_ok" != "yes" ]]; then
	echo "  ✗ FAIL: Cluster '$_CLUSTER' API not reachable — refusing soft day2 PASS"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary; exit 1
fi
echo "  ✓ PASS: Cluster '$_CLUSTER' installed and API reachable"
_TUI_PASS=$(( _TUI_PASS + 1 ))

tui_start_to_menu || { tui_summary; exit 1; }

# Navigate Actions → Day-2 → OperatorHub (same path as upgrade day2)
echo "--- Navigate to Day-2 OperatorHub ---"
tui_back_to "Actions" 5
tui_select_item "Day-2"
for _w in 1 2 3 4 5; do
	sleep 2
	_scr=$(tui_capture)
	if echo "$_scr" | grep -q "── Configuration ──\|── Status ──\|── Lifecycle ──\|── Cleanup ──"; then
		break
	fi
	if echo "$_scr" | grep -qi "Quit.*Q\|Press.*ENTER\|── Success ──\|── FAILED ──"; then
		tui_keys Enter; sleep 1
	fi
done
tui_screenshot "csr-01-day2-menu"

tui_select_item "OperatorHub\|Configure.*OperatorHub\|Registry"
sleep 2
tui_screenshot "csr-02-after-opshub"

echo "--- tui_pick_cluster (must clear Detecting / Select) ---"
_t0=$(date +%s)
if ! tui_pick_cluster "$_CLUSTER"; then
	echo "  ✗ FAIL: tui_pick_cluster timed out"
	tui_screenshot "csr-pick-timeout"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary; exit 1
fi
_t1=$(date +%s)
echo "  pick_cluster took $((_t1 - _t0))s"
_scr=$(tui_capture)
if echo "$_scr" | grep -qiE "Select cluster for Day-2|Select cluster"; then
	echo "  ✗ FAIL: still on Select cluster after tui_pick_cluster"
	tui_screenshot "csr-still-select"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_summary; exit 1
fi
echo "  ✓ PASS: cleared Detecting/Select cluster"
_TUI_PASS=$(( _TUI_PASS + 1 ))
tui_screenshot "csr-03-after-pick"

tui_dismiss_exec_mode

echo "--- day2 must complete successfully (no soft PASS) ---"
_t0=$(date +%s)
_rc=0
tui_wait_for_progress "csr-day2" 600 || _rc=$?
_t1=$(date +%s)
_elapsed=$(( _t1 - _t0 ))
echo "  wait_for_progress rc=$_rc elapsed=${_elapsed}s"
tui_screenshot "csr-04-after-wait"
_scr=$(tui_capture)

if echo "$_scr" | grep -qiE "Select cluster for Day-2"; then
	echo "  ✗ FAIL: wait left us on Select cluster (hang race not fixed)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
elif [[ "$_rc" -eq 0 ]]; then
	echo "  ✓ PASS: day2 completed successfully after cluster select (${_elapsed}s)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: day2 did not complete successfully (rc=$_rc elapsed=${_elapsed}s)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

tui_summary
exit $(( _TUI_FAIL > 0 ? 1 : 0 ))
