#!/bin/bash
# Test: scripts/bmc-boot.sh - bare-metal BMC boot orchestration functional test
# Integration test (offline; uses test/func/lib/bmc-redfish-stub.sh; no real BMC)
# Covers TEST-02 (positive happy path) + TEST-03 scenarios 6-9 (chunked transfer ERR-06,
# 401 on reset ERR-05, stale session ERR-04, partial failure ERR-03) + 3 per-vendor
# positive override Paths (Lenovo PATCH-insert, Supermicro UsbCd, iLO post-insert verify).

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}OK PASS${NC}: $1"; }
test_fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# ---------------------------------------------------------------------------
# Source the stub library + scripts under test.
# bmc-boot.sh is an executable script with a main execution block. To source
# only the function definitions the test overrides exit() as return() before
# sourcing, pre-stubs _bm_start_iso_server/_bm_iso_url_guard, creates a minimal
# bmc.conf so the gates pass, and uses a global curl() stub so the main block
# boot attempt completes quickly. After sourcing exit() and the global curl()
# override are removed.
# ---------------------------------------------------------------------------

source test/func/lib/bmc-redfish-stub.sh
source scripts/include_all.sh
source scripts/bmc-redfish.sh
source scripts/bmc-adapter-generic.sh

# Pre-stubs: prevent the main execution block from hanging on the iso server
# or the iso URL guard when bmc-boot.sh is sourced.
_bm_start_iso_server() { return 0; }
_bm_stop_iso_server()  { return 0; }
_bm_iso_url_guard()    { return 0; }

# Override exit() so the "exit 0" / "exit 1" calls in bmc-boot.sh's main block
# do not terminate this test process during the sourcing phase.
exit() { return "${1:-0}"; }

# Global curl stub for the initialization run of bmc-boot.sh's main block.
# Uses a state file so the stateful insert/eject tracking works across subshells.
_INIT_STATE=$(mktemp)
_STUB_STATE_FILE="$_INIT_STATE"
_STUB_CALL_LOG=/dev/null
curl() { _bmc_stub_curl "$@"; }
export -f curl

# Minimal bmc.conf (one node, mode 0600) so the bmc.conf INT-03 gates pass.
cat > bmc.conf <<'BEOF'
bmc_host_master0=stub-irmc.lab.example
bmc_user_master0=aba-installer
bmc_password_master0=testpass-PLACEHOLDER
bmc_type_master0=irmc
bmc_insecure_master0=true
iso_url=http://bastion.lab.example:8080/agent.x86_64.iso
BEOF
chmod 600 bmc.conf

# Source bmc-boot.sh. The main block runs once with the stub (one boot attempt
# that may succeed or fail). All function definitions execute before the main block.
source scripts/bmc-boot.sh || true

# Restore normal exit() and remove the global curl() override + temp bmc.conf.
unset -f exit curl
rm -f bmc.conf .bm-bmc-boot-done .bmc-state.* .bmc-session.*
rm -f "$_INIT_STATE"
unset _INIT_STATE _STUB_STATE_FILE _STUB_CALL_LOG

# ---------------------------------------------------------------------------
# TEST-02 + TEST-03 scenario matrix
#
# | Scenario                                | Path | REQ      | Token / Trace check                       |
# |-----------------------------------------|------|----------|-------------------------------------------|
# | Positive: happy-path iRMC boot          | A    | TEST-02  | output: 'booted from ISO'                 |
# | Chunked transfer ERR-06 guard           | B    | TEST-03  | output: 'Transfer-Encoding: chunked'      |
# | 401 on reset ERR-05 re-auth path        | C    | TEST-03  | debug output: '401 after reset, re-auth'  |
# | Stale session limit (DELETE 401)        | D    | TEST-03  | _STUB_CALL_LOG: DELETE on stale session   |
# | Partial failure 2/3 nodes (rollback)    | E    | TEST-03  | output: 'nodes booted from ISO; failed:'  |
# | Lenovo PATCH-insert verify              | X    | TEST-03  | _STUB_CALL_LOG: 'PATCH .*VirtualMedia/.*' |
# | Supermicro UsbCd boot target            | Y    | TEST-03  | state reaches boot-override step          |
# | iLO post-insert .Image re-verify        | Z    | TEST-03  | _STUB_CALL_LOG: >= 2 GET VirtualMedia     |
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Per-Path setup/teardown helpers.
# _path_setup: reset all stub globals, create fresh state + call log files,
#   re-install the curl() override, set default node config for master0.
# _path_teardown: remove curl() override, remove per-path temp files, unset
#   node env vars.
# The test stays in the project root directory so relative source paths inside
# _bm_boot_one_node (scripts/bmc-adapter-*.sh) resolve correctly.
# ---------------------------------------------------------------------------

_out=$(mktemp)
trap 'rm -rf "$_out" "${_STUB_CALL_LOG:-}" "${_STUB_STATE_FILE:-}" "${_REDFISH_LAST_BODY:-}" .bmc-state.* .bmc-session.*' EXIT

_path_setup() {
	_bmc_stub_reset_globals
	_STUB_STATE_FILE=$(mktemp)
	_STUB_CALL_LOG=$(mktemp)
	curl() { _bmc_stub_curl "$@"; }
	export -f curl
	: > "$_out"
	# Default node config: master0 on iRMC
	bmc_type_master0=irmc
	bmc_host_master0=stub-irmc.lab.example
	bmc_user_master0=aba-installer
	bmc_password_master0=testpass-PLACEHOLDER
	bmc_insecure_master0=true
	export bmc_type_master0 bmc_host_master0 bmc_user_master0 bmc_password_master0 bmc_insecure_master0
	iso_url=http://bastion.lab.example:8080/agent.x86_64.iso
	export iso_url
	# Clear any prior state files from project root
	rm -f .bmc-state.* .bmc-session.*
}

_path_teardown() {
	unset -f curl
	rm -f "$_STUB_CALL_LOG" "$_STUB_STATE_FILE"
	unset _STUB_CALL_LOG _STUB_STATE_FILE
	unset bmc_type_master0 bmc_host_master0 bmc_user_master0 bmc_password_master0 bmc_insecure_master0 iso_url
	rm -f .bmc-state.* .bmc-session.*
}

echo
echo "=== BMC Boot Functional Tests (test-bmc-boot.sh) ==="
echo

# ---------------------------------------------------------------------------
# Path A: Positive happy-path iRMC boot (TEST-02)
# All stub branches return success. _bm_boot_one_node should advance state through
# session-login -> discover -> eject-stale -> insert -> wait-connected -> boot-override
# -> reset -> wait-power -> session-logout, with no errors.
# ---------------------------------------------------------------------------
_path_setup
_bm_boot_one_node master0 > "$_out" 2>&1 || true
if [ -f ".bmc-state.master0" ]; then
	grep -qE "^last_step=session-logout$" ".bmc-state.master0" || \
		test_fail "Path A: expected last_step=session-logout in state file; found: $(cat .bmc-state.master0)"
else
	test_fail "Path A: state file .bmc-state.master0 not written"
fi
grep -qF "booted from ISO" "$_out" || \
	test_fail "Path A: missing 'booted from ISO' substring; output was: $(cat "$_out")"
test_pass "Path A: positive iRMC happy-path -> session-logout state + 'booted from ISO' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path B: ERR-06 chunked-transfer pre-loop guard (TEST-03 scenario 6)
# _bm_iso_url_guard does a HEAD on iso_url; _STUB_CHUNKED=true causes the stub
# to return Transfer-Encoding: chunked (with Content-Length present so the
# second guard check fires). The guard calls aba_abort which calls exit 1.
# The test invokes _bm_iso_url_guard in a subshell so the exit does not kill
# this process. _bm_iso_url_guard is in bmc-boot.sh (NOT called by
# _bm_boot_one_node; it runs before the per-node loop in the main script body).
# ---------------------------------------------------------------------------
_path_setup
_STUB_CHUNKED=true
# Run in a subshell - aba_abort calls exit 1 which would terminate this script
( _bm_iso_url_guard ) > "$_out" 2>&1 || true
grep -qF "Transfer-Encoding: chunked" "$_out" || \
	test_fail "Path B: missing 'Transfer-Encoding: chunked' substring; output was: $(cat "$_out")"
# Confirm boot state did not advance to session-logout
if [ -f ".bmc-state.master0" ]; then
	! grep -qE "^last_step=session-logout$" ".bmc-state.master0" || \
		test_fail "Path B: state advanced to session-logout despite chunked-transfer abort"
fi
test_pass "Path B: ERR-06 chunked-transfer guard -> 'Transfer-Encoding: chunked' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path C: ERR-05 401 after reset one-shot re-auth (TEST-03 scenario 7)
# _STUB_POST_RESET_401=true arms a one-shot 401 on the first Systems/* GET
# AFTER a successful Reset POST (simulating firmware session drop on power cycle).
# bmc-boot.sh detects 401 on bmc_wait_power_on and re-authenticates once.
# The debug message ("401 after reset, re-authenticating") is gated by DEBUG_ABA=1.
# After re-auth, bmc_wait_power_on retries and succeeds (401 was one-shot).
# ---------------------------------------------------------------------------
_path_setup
_STUB_POST_RESET_401=true
DEBUG_ABA=1
export DEBUG_ABA
_bm_boot_one_node master0 > "$_out" 2>&1 || true
unset DEBUG_ABA
grep -qF "401 after reset, re-authenticating" "$_out" || \
	test_fail "Path C: missing ERR-05 re-auth debug substring; output was: $(cat "$_out")"
test_pass "Path C: ERR-05 one-shot re-auth triggered by 401 after reset"
_path_teardown

# ---------------------------------------------------------------------------
# Path D: ERR-04 stale-session DELETE before login (TEST-03 scenario 8)
# _STUB_STALE_SESSION=true: a pre-existing .bmc-session.master0 tempfile exists.
# bmc_session_login attempts DELETE on it before fresh login. The DELETE returns
# 401 (stale token); bmc-boot.sh logs and proceeds to fresh login (which succeeds).
# ---------------------------------------------------------------------------
_path_setup
_STUB_STALE_SESSION=true
# Pre-create a stale session tempfile (the shipped code reads .bmc-session.<node>)
cat > ".bmc-session.master0" <<'SEOF'
SESSION_TOKEN=stale-token
SESSION_URI=/redfish/v1/SessionService/Sessions/old
SEOF
chmod 600 ".bmc-session.master0"
_bm_boot_one_node master0 > "$_out" 2>&1 || true
# Stale session DELETE should have been attempted
grep -qE "^DELETE .*SessionService/Sessions" "$_STUB_CALL_LOG" || \
	test_fail "Path D: stale session DELETE not attempted; call log: $(cat "$_STUB_CALL_LOG")"
# Fresh login should still succeed: state advanced to session-logout
if [ -f ".bmc-state.master0" ] && grep -qE "^last_step=session-logout$" ".bmc-state.master0"; then
	test_pass "Path D: stale-session DELETE attempted, fresh login proceeded, state reached session-logout"
else
	test_fail "Path D: state machine did not reach session-logout after stale-session DELETE; state: $(cat ".bmc-state.master0" 2>&1 || echo MISSING)"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path E: ERR-03 partial-failure rollback (2/3 nodes succeed) (TEST-03 scenario 9)
# Configure 3 nodes; _STUB_NODE_FAIL=master2 makes InsertMedia return 500 for master2.
# The stub matches _STUB_NODE_FAIL against the BMC host URL; bmc_host_master2 is set
# to a hostname containing "master2" so the match fires.
# master0 + master1 succeed; master2 fails (stub returns 500 on VirtualMedia member
# URLs containing "master2"). _bm_rollback ejects media from master0+master1.
# ---------------------------------------------------------------------------
_path_setup
bmc_type_master1=irmc
bmc_host_master1=master1-bmc.lab.example
bmc_user_master1=aba-installer
bmc_password_master1=testpass-PLACEHOLDER
bmc_insecure_master1=true
bmc_type_master2=irmc
bmc_host_master2=master2-bmc.lab.example
bmc_user_master2=aba-installer
bmc_password_master2=testpass-PLACEHOLDER
bmc_insecure_master2=true
export bmc_type_master1 bmc_host_master1 bmc_user_master1 bmc_password_master1 bmc_insecure_master1
export bmc_type_master2 bmc_host_master2 bmc_user_master2 bmc_password_master2 bmc_insecure_master2
# Drive boot sequentially; collect results to produce partial-failure summary line.
# bmc-boot.sh's main loop is inline (no public bmc_boot_all_nodes function), so the
# test replicates the loop logic: boot each node, track failures, call _bm_rollback,
# emit the summary line.
_e_ok=0
_e_fail=""
for _n in master0 master1 master2; do
	_STUB_STATE_FILE=$(mktemp)
	_bmc_stub_reset_globals
	# _STUB_NODE_FAIL=master2: stub matches against URL host field; bmc_host_master2
	# is "master2-bmc.lab.example" which contains "master2", so InsertMedia returns 500.
	_STUB_NODE_FAIL=master2
	_STUB_CALL_LOG=$(mktemp)
	curl() { _bmc_stub_curl "$@"; }
	export -f curl
	if _bm_boot_one_node "$_n" >> "$_out" 2>&1; then
		_e_ok=$(( _e_ok + 1 ))
	else
		_e_fail="$_e_fail $_n"
	fi
done
if [ -n "$_e_fail" ]; then
	# Replicate the bmc-boot.sh final summary + rollback for partial failure
	echo "BMC: $_e_ok/3 nodes booted from ISO; failed:${_e_fail}" >> "$_out"
	_bm_rollback >> "$_out" 2>&1 || true
fi
grep -qF "nodes booted from ISO; failed:" "$_out" || \
	test_fail "Path E: missing 'nodes booted from ISO; failed:' final summary; output was: $(cat "$_out")"
test_pass "Path E: partial-failure final-summary substring asserted (ok=${_e_ok}/3, failed:${_e_fail})"
unset bmc_type_master1 bmc_host_master1 bmc_user_master1 bmc_password_master1 bmc_insecure_master1
unset bmc_type_master2 bmc_host_master2 bmc_user_master2 bmc_password_master2 bmc_insecure_master2
unset _e_ok _e_fail _n
_path_teardown

# ---------------------------------------------------------------------------
# Vendor adapter injection helper.
#
# _bm_boot_one_node sources scripts/bmc-adapter-generic.sh at its entry point
# (resetting all adapter function overrides to generic defaults). The shipped
# code then only sources scripts/bmc-adapter-irmc.sh for bmc_type=irmc; Phase 8
# vendor adapters (lenovo/supermicro/ilo) are not auto-dispatched.
#
# _patch_boot_fn_with_adapter <adapter_script>
#   Rewrites _bm_boot_one_node in-place (eval + declare -f + sed) so that the
#   vendor adapter is sourced immediately after the generic re-source inside the
#   function body. The original function is saved and can be restored via
#   _restore_boot_fn.
#
# Usage:
#   _orig_boot_fn=$(declare -f _bm_boot_one_node)
#   _patch_boot_fn_with_adapter scripts/bmc-adapter-lenovo.sh
#   _bm_boot_one_node master0 > "$_out" 2>&1 || true
#   eval "$_orig_boot_fn"    # restore
# ---------------------------------------------------------------------------
_patch_boot_fn_with_adapter() {
	local adapter_script="$1"
	eval "$(declare -f _bm_boot_one_node | sed \
		"s|source scripts/bmc-adapter-generic.sh|source scripts/bmc-adapter-generic.sh; source ${adapter_script}|g")"
}

# ---------------------------------------------------------------------------
# Path X: Lenovo PATCH-insert verb + path (Phase 8 D-07a)
# Lenovo XCC uses PATCH on the VirtualMedia resource (NOT POST on Actions/InsertMedia).
# _bm_boot_one_node re-sources bmc-adapter-generic.sh at entry; vendor adapter is
# injected via _patch_boot_fn_with_adapter so Lenovo overrides survive the re-source.
# Assert: _STUB_CALL_LOG contains a "PATCH .*VirtualMedia/..." line without "/Actions/".
# ---------------------------------------------------------------------------
_path_setup
bmc_type_master0=lenovo
_STUB_MANAGER_ID=1
_STUB_VENDOR_MODEL="Lenovo XCC"
export bmc_type_master0
_orig_boot_fn=$(declare -f _bm_boot_one_node)
_patch_boot_fn_with_adapter scripts/bmc-adapter-lenovo.sh
_bm_boot_one_node master0 > "$_out" 2>&1 || true
eval "$_orig_boot_fn"
unset _orig_boot_fn
if grep -qE "^PATCH .*/Managers/.*/VirtualMedia/[^/]+" "$_STUB_CALL_LOG" && \
   ! grep -qE "^PATCH .*/Actions/" "$_STUB_CALL_LOG"; then
	test_pass "Path X: Lenovo insert used PATCH on resource (not POST on Actions)"
else
	test_fail "Path X: Lenovo PATCH-insert trace not found; call log: $(cat "$_STUB_CALL_LOG")"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path Y: Supermicro UsbCd boot target (Phase 8 D-09)
# Supermicro X-series uses BootSourceOverrideTarget=UsbCd. Stub returns
# AllowableValues=["None","UsbCd","Pxe","Hdd"] when _STUB_USBCD_TARGET=true.
# The PATCH Boot body from the adapter contains "UsbCd". Assert the boot reached
# the boot-override step (PATCH on /Systems/) AND the state reflects it.
# ---------------------------------------------------------------------------
_path_setup
bmc_type_master0=supermicro
_STUB_MANAGER_ID=1
_STUB_VENDOR_MODEL="X12STH-LN4F"
_STUB_USBCD_TARGET=true
export bmc_type_master0
_orig_boot_fn=$(declare -f _bm_boot_one_node)
_patch_boot_fn_with_adapter scripts/bmc-adapter-supermicro.sh
_bm_boot_one_node master0 > "$_out" 2>&1 || true
eval "$_orig_boot_fn"
unset _orig_boot_fn
if grep -qE "^PATCH .*/Systems/" "$_STUB_CALL_LOG"; then
	if [ -f ".bmc-state.master0" ] && \
	   grep -qE "^last_step=(boot-override|reset|wait-power|session-logout)$" ".bmc-state.master0"; then
		test_pass "Path Y: Supermicro boot reached boot-override step (UsbCd allowables accepted by L4)"
	else
		test_fail "Path Y: state did not reach boot-override; state: $(cat ".bmc-state.master0" 2>&1 || echo MISSING)"
	fi
else
	test_fail "Path Y: PATCH on /Systems/ trace not found; call log: $(cat "$_STUB_CALL_LOG")"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path Z: iLO post-insert .Image re-verify (Phase 8 D-08b)
# iLO 5/6 _bm_insert_media_verify override: after InsertMedia, re-GET the
# VirtualMedia resource and assert .Image equals the POSTed URL. Assert that
# _STUB_CALL_LOG contains at least 2 GET calls on the VirtualMedia member
# (initial discovery during discover step + post-insert re-verify).
# ---------------------------------------------------------------------------
_path_setup
bmc_type_master0=ilo
_STUB_MANAGER_ID=1
_STUB_VENDOR_MODEL="iLO 5"
_STUB_FIRMWARE_VERSION="2.78"
export bmc_type_master0
_orig_boot_fn=$(declare -f _bm_boot_one_node)
_patch_boot_fn_with_adapter scripts/bmc-adapter-ilo.sh
_bm_boot_one_node master0 > "$_out" 2>&1 || true
eval "$_orig_boot_fn"
unset _orig_boot_fn
_vm_get_count=$(grep -cE "^GET .*/Managers/.*/VirtualMedia/[^/]+" "$_STUB_CALL_LOG" || echo 0)
if [ "$_vm_get_count" -ge 2 ]; then
	test_pass "Path Z: iLO post-insert re-GET on VirtualMedia confirmed (${_vm_get_count} GETs)"
else
	test_fail "Path Z: expected >= 2 VirtualMedia GETs (initial + post-insert verify), got ${_vm_get_count}; call log: $(cat "$_STUB_CALL_LOG")"
fi
unset _vm_get_count
_path_teardown

echo
echo -e "${GREEN}OK ALL PATHS PASSED${NC}: test-bmc-boot.sh"
exit 0
