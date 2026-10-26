#!/bin/bash
# Master TUI test runner — executes all TUI tests in pipeline order.
#
# Usage:
#   test/func/test-tui-all.sh              # Full suite (includes cluster install)
#   test/func/test-tui-all.sh --quick      # Quick tests only (smoke, nav, help, wizard)
#   test/func/test-tui-all.sh --no-delete  # Full suite but keep the cluster at the end
#
# Environment variables:
#   TUI_TEST_HOST     - Target host (default: conno.example.com)
#   TUI_CLUSTER_NAME  - Cluster name for install/day2/upgrade tests (default: sno)
#   TUI_SKIP_DELETE   - Set to 1 to skip cluster deletion
#
# Pipeline order:
#   1.  smoke          - splash, menus, buttons, exit
#   2.  help           - help text consistency across all menus
#   3.  nav            - dynamic menu discovery and navigation
#   4.  wizard         - setup wizard pages (non-destructive)
#   5.  operators      - operator workflows: sets, search, view, images
#   6.  mirror-config  - mirror config forms + platform config (non-destructive)
#   7.  payload-deep   - prepare upgrade, version/channel, settings, bundle
#   8.  cluster-pages  - cluster wizard page navigation (non-destructive)
#   9.  day2-deep      - day-2 status, OSUS, upgrade picker, confirmations
#  10.  disco-smoke    - DISCO mode on disco host (non-destructive)
#  --- destructive (full mode only) ---
#  11.  mirror         - mirror install + sync (destructive, ~15 min)
#  12.  cluster        - cluster wizard + install (destructive, ~45 min)
#  13.  day2           - OperatorHub, NTP, OSUS (~10 min)
#  14.  upgrade        - version selection + upgrade (~45 min)
#  15.  lifecycle      - shutdown, startup, clean, delete (~30 min)

set -o pipefail

cd "$(dirname "$0")/../.."

_QUICK=false
_NO_DELETE=false
for arg in "$@"; do
	case "$arg" in
		--quick) _QUICK=true ;;
		--no-delete) _NO_DELETE=true ;;
	esac
done

export TUI_CLUSTER_NAME="${TUI_CLUSTER_NAME:-sno}"
[[ "$_NO_DELETE" == "true" ]] && export TUI_SKIP_DELETE=1

_total_pass=0
_total_fail=0
_total_skip=0
_results=()

_run_test() {
	local name="$1" script="$2"
	echo ""
	echo "================================================================"
	echo "  RUNNING: $name"
	echo "================================================================"
	echo ""

	local output rc
	output=$(bash "$script" 2>&1)
	rc=$?
	echo "$output"

	# Extract PASS/FAIL counts from output
	local _p _f
	_p=$(echo "$output" | grep 'PASS:' | tail -1 | grep -oE '[0-9]+')
	_f=$(echo "$output" | grep 'FAIL:' | tail -1 | grep -oE '[0-9]+')
	_p=${_p:-0}
	_f=${_f:-0}
	_total_pass=$(( _total_pass + _p ))
	_total_fail=$(( _total_fail + _f ))

	if [[ $rc -eq 0 ]]; then
		_results+=("  ✓ $name: ${_p} pass, ${_f} fail")
	else
		_results+=("  ✗ $name: ${_p} pass, ${_f} fail (EXIT $rc)")
	fi

	return $rc
}

echo "========================================"
echo "  ABA TUI Full Test Suite"
echo "  Host: ${TUI_TEST_HOST:-conno.example.com}"
echo "  Mode: $( $_QUICK && echo "QUICK" || echo "FULL" )"
echo "  Cluster: $TUI_CLUSTER_NAME"
echo "========================================"

# --- Quick tests (always run — non-destructive, ~10 min total) ---
_run_test "Smoke Test" "test/func/test-tui-smoke.sh" || true
_run_test "Help Consistency" "test/func/test-tui-help.sh" || true
_run_test "Navigation" "test/func/test-tui-nav.sh" || true
_run_test "Wizard" "test/func/test-tui-wizard.sh" || true
_run_test "Operators" "test/func/test-tui-operators.sh" || true
_run_test "Mirror Config" "test/func/test-tui-mirror-config.sh" || true
_run_test "Payload Deep" "test/func/test-tui-payload-deep.sh" || true
_run_test "Cluster Pages" "test/func/test-tui-cluster-pages.sh" || true
_run_test "Day-2 Deep" "test/func/test-tui-day2-deep.sh" || true
_run_test "DISCO Smoke" "test/func/test-tui-disco-smoke.sh" || true

if [[ "$_QUICK" == "true" ]]; then
	echo ""
	echo "  (--quick mode: skipping destructive mirror, cluster, day2, upgrade, lifecycle)"
	_total_skip=5
else
	# --- Destructive tests (full mode only, pipeline order) ---
	_run_test "Mirror Workflow" "test/func/test-tui-mirror.sh" || true
	_run_test "Cluster Install" "test/func/test-tui-cluster.sh" || true
	_run_test "Day-2 Operations" "test/func/test-tui-day2.sh" || true
	_run_test "Upgrade" "test/func/test-tui-upgrade.sh" || true
	_run_test "Lifecycle" "test/func/test-tui-lifecycle.sh" || true
fi

# --- Summary ---
echo ""
echo ""
echo "========================================"
echo "  TUI FULL SUITE RESULTS"
echo "========================================"
for r in "${_results[@]}"; do
	echo "$r"
done
echo "----------------------------------------"
echo "  Total PASS: $_total_pass"
echo "  Total FAIL: $_total_fail"
[[ $_total_skip -gt 0 ]] && echo "  Skipped:    $_total_skip test(s)"
echo "========================================"

[[ $_total_fail -eq 0 ]]
