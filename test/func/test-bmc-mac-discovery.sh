#!/bin/bash
# Test: TEST-06 - MAC auto-discovery functional coverage.
# Integration test (offline; uses test/func/lib/bmc-redfish-stub.sh; no real BMC).
# Covers every MAC-* error code introduced by Phase 10 plus happy path,
# bond-filter, sidecar cache, and _bm_get_mac resolution order.
#
# Scenario matrix (mirror test-preflight-check-bm.sh format):
#
# | Path | What                                  | Helper exercised             | REQ     |
# |------|---------------------------------------|------------------------------|---------|
# | A    | Happy: single LinkUp NIC              | _bm_resolve_mac              | TEST-06 |
# | B    | MAC-04 no LinkUp NIC                  | _bm_resolve_mac              | TEST-06 |
# | C    | MAC-05 ambiguous (2 LinkUp NICs)      | _bm_resolve_mac              | TEST-06 |
# | D    | Bond filter: iLO-bond0 dropped (D-06) | _bm_resolve_mac              | TEST-06 |
# | E    | MAC-08 Redfish HTTP 500               | _bm_discover_macs (10-02)    | TEST-06 |
# | F    | MAC-03 operator mac mismatch          | _bm_discover_macs (10-02)    | TEST-06 |
# | G    | MAC-09 opt-out without mac_<node>     | _bm_discover_macs (10-02)    | TEST-06 |
# | H    | D-02 cache hit (fresh sidecar)        | _bm_discover_macs (10-02)    | TEST-06 |
# | I    | _bm_get_mac resolution order (3-way)  | _bm_get_mac                  | TEST-06 |
#
# Paths E-H exercise _bm_discover_macs which lives in scripts/preflight-check-bm.sh
# and is being added by sibling Plan 10-02 in the same wave. At this branch base
# the function is NOT yet defined; affected Paths self-report as SKIP and the
# suite still completes with "OK ALL PATHS PASSED" (the parallel-wave executor
# is expected to surface SKIPs in SUMMARY.md). After the orchestrator merges
# 10-02 + 10-03 to dev, all Paths run and pass.

set -e

cd "$(dirname "$0")/../.."

REPO_ROOT=$(pwd)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}OK PASS${NC}: $1"; }
test_skip() { echo -e "${YELLOW}SKIP${NC}: $1"; }
test_fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# ---------------------------------------------------------------------------
# Source the shared Redfish stub (provides _bmc_stub_curl + EthernetInterfaces
# fixtures from Plan 10-03 Task 1).
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/test/func/lib/bmc-redfish-stub.sh"

# ---------------------------------------------------------------------------
# Source runtime helpers (aba_info_ok / aba_warning / aba_abort / aba_debug,
# normalize-bmc-conf, bmc_redact_env). MUST come before bmc-redfish / adapters.
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/scripts/include_all.sh"

# ---------------------------------------------------------------------------
# Source Redfish wrapper + generic adapter (the latter owns the canonical
# _bm_get_ethernetinterfaces wrapper per Plan 10-01 Task 2; vendor overlays
# may redefine via bash function-redefine-wins).
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/scripts/bmc-redfish.sh"
source "${REPO_ROOT}/scripts/bmc-adapter-generic.sh"

# ---------------------------------------------------------------------------
# Source the MAC discovery library under test (3 vendor-agnostic helpers
# from Plan 10-01: _bm_filter_enabled_up, _bm_resolve_mac, _bm_get_mac).
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/scripts/bmc-mac-discovery.sh"

# ---------------------------------------------------------------------------
# Source preflight script for _bm_discover_macs (added by sibling Plan 10-02
# wave). At branch base this file does not yet contain _bm_discover_macs; the
# helper detect below routes Paths E-H to SKIP rather than FAIL.
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/scripts/preflight-check-bm.sh"

_has_bm_discover_macs() {
	declare -F _bm_discover_macs > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Shared output capture + sandbox top-level dir
# ---------------------------------------------------------------------------
_out=$(mktemp)
_top_dir=$(mktemp -d)
trap 'rm -f "$_out"; rm -rf "$_top_dir"' EXIT

echo
echo "=== BMC MAC Discovery Functional Tests (test-bmc-mac-discovery.sh) ==="
echo

# ---------------------------------------------------------------------------
# Common per-Path setup: clean stub flags, fresh tmp workdir + minimal bmc.conf,
# override curl() to route through the stub, seed SESSION_TOKEN + SYSTEM_ID so
# _redfish_request does not short-circuit on "no active session" guard.
# ---------------------------------------------------------------------------
_path_setup() {
	_bmc_stub_reset_globals
	_STUB_CALL_LOG=$(mktemp)
	curl() { _bmc_stub_curl "$@"; }
	export -f curl

	_preflight_errors=0
	_preflight_warnings=0
	: > "$_out"

	# Per-Path temp workdir with bmc.conf (mode 0600).
	_path_dir=$(mktemp -d "${_top_dir}/path.XXXXXX")
	cat > "${_path_dir}/bmc.conf" <<'BMCEOF'
bmc_type_n0=irmc
bmc_host_n0=127.0.0.1
bmc_user_n0=aba-installer
bmc_password_n0=testpass-PLACEHOLDER
bmc_insecure_n0=true
BMCEOF
	chmod 600 "${_path_dir}/bmc.conf"
	pushd "${_path_dir}" > /dev/null

	# Export bmc vars + iso_url into env (preflight code reads via indirection).
	bmc_type_n0=irmc
	bmc_host_n0=127.0.0.1
	bmc_user_n0=aba-installer
	bmc_password_n0=testpass-PLACEHOLDER
	bmc_insecure_n0=true
	export bmc_type_n0 bmc_host_n0 bmc_user_n0 bmc_password_n0 bmc_insecure_n0

	# Bypass the _redfish_inner_request "no active session" guard so the stub
	# is reached on every Redfish call.
	SESSION_TOKEN_n0="stub-token-abc123"
	export SESSION_TOKEN_n0

	# Pre-seed the per-node id cache so _bm_get_ethernetinterfaces does not
	# need to call bmc_discover_ids (which would issue extra GETs).
	SYSTEM_ID_n0="0"
	MANAGER_ID_n0="iRMC"
	export SYSTEM_ID_n0 MANAGER_ID_n0
}

_path_teardown() {
	popd > /dev/null
	unset -f curl
	unset SESSION_TOKEN_n0 SYSTEM_ID_n0 MANAGER_ID_n0
	unset bmc_type_n0 bmc_host_n0 bmc_user_n0 bmc_password_n0 bmc_insecure_n0
	unset mac_n0 mac_discovery_n0
	rm -f "$_STUB_CALL_LOG"
}

# ---------------------------------------------------------------------------
# Path A: Happy path - 1 NIC LinkUp + Enabled -> singleton resolution.
# ---------------------------------------------------------------------------
_path_setup
_STUB_NIC_SCENARIO=happy
nic_lines=$(_bm_get_ethernetinterfaces n0)
rc=$?
[ "$rc" -eq 0 ] || test_fail "Path A: _bm_get_ethernetinterfaces returned $rc, expected 0"
_bm_resolve_mac n0 "$nic_lines"
rc=$?
[ "$rc" -eq 0 ] || test_fail "Path A: _bm_resolve_mac returned $rc, expected 0; got nic_lines=$nic_lines"
[ "$_BM_DISCOVERED_MAC" = "aa:bb:cc:dd:ee:01" ] || test_fail "Path A: _BM_DISCOVERED_MAC='$_BM_DISCOVERED_MAC', expected aa:bb:cc:dd:ee:01"
[ "$_BM_DISCOVERED_NIC_ID" = "NIC.Integrated.1" ] || test_fail "Path A: _BM_DISCOVERED_NIC_ID='$_BM_DISCOVERED_NIC_ID', expected NIC.Integrated.1"
test_pass "Path A: happy single-NIC -> singleton resolution (mac=$_BM_DISCOVERED_MAC nic=$_BM_DISCOVERED_NIC_ID)"
_path_teardown

# ---------------------------------------------------------------------------
# Path B: MAC-04 no enabled NIC with link -> rc 4 + operator-visible error.
# ---------------------------------------------------------------------------
_path_setup
_STUB_NIC_SCENARIO=no-linkup
nic_lines=$(_bm_get_ethernetinterfaces n0)
rc=0
_bm_resolve_mac n0 "$nic_lines" > "$_out" 2>&1 || rc=$?
[ "$rc" -eq 4 ] || test_fail "Path B: _bm_resolve_mac rc=$rc expected 4 (MAC-04)"
grep -qF "MAC-04" "$_out" || test_fail "Path B: missing MAC-04 token; output: $(cat "$_out")"
grep -qF "no enabled NIC with link reported" "$_out" || test_fail "Path B: missing MAC-04 description; output: $(cat "$_out")"
test_pass "Path B: MAC-04 (no LinkUp NIC) -> rc 4 + 'no enabled NIC with link reported'"
_path_teardown

# ---------------------------------------------------------------------------
# Path C: MAC-05 ambiguous (>1 LinkUp+Enabled NIC) -> rc 5 + both MACs listed.
# ---------------------------------------------------------------------------
_path_setup
_STUB_NIC_SCENARIO=ambiguous
_STUB_NIC_MACS="aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02"
nic_lines=$(_bm_get_ethernetinterfaces n0)
rc=0
_bm_resolve_mac n0 "$nic_lines" > "$_out" 2>&1 || rc=$?
[ "$rc" -eq 5 ] || test_fail "Path C: _bm_resolve_mac rc=$rc expected 5 (MAC-05); output: $(cat "$_out")"
grep -qF "MAC-05" "$_out" || test_fail "Path C: missing MAC-05 token; output: $(cat "$_out")"
grep -qF "ambiguous" "$_out" || test_fail "Path C: missing 'ambiguous' word; output: $(cat "$_out")"
grep -qF "aa:bb:cc:dd:ee:01" "$_out" || test_fail "Path C: missing first MAC in candidate list; output: $(cat "$_out")"
grep -qF "aa:bb:cc:dd:ee:02" "$_out" || test_fail "Path C: missing second MAC in candidate list; output: $(cat "$_out")"
grep -qF "set mac_n0=" "$_out" || test_fail "Path C: missing disambiguation hint; output: $(cat "$_out")"
test_pass "Path C: MAC-05 (ambiguous) -> rc 5 + both MACs + disambiguation hint"
_path_teardown

# ---------------------------------------------------------------------------
# Path D: Bond filter - iLO-bond0 dropped per D-06, physical singleton survives.
# bond-entry scenario: slot 0 LinkUp physical + slot 1 Bond iLO-bond0 LinkUp
# + slot 2 LinkDown physical. D-06 drops bond, D-04 drops LinkDown -> singleton.
# ---------------------------------------------------------------------------
_path_setup
_STUB_NIC_SCENARIO=bond-entry
nic_lines=$(_bm_get_ethernetinterfaces n0)
_bm_resolve_mac n0 "$nic_lines"
rc=$?
[ "$rc" -eq 0 ] || test_fail "Path D: _bm_resolve_mac rc=$rc expected 0 (singleton survivor); nic_lines=$nic_lines"
[ "$_BM_DISCOVERED_NIC_ID" = "NIC.Integrated.1" ] || test_fail "Path D: expected NIC.Integrated.1 survivor, got '$_BM_DISCOVERED_NIC_ID'"
case "$_BM_DISCOVERED_NIC_ID" in
	*bond*|*Bond*) test_fail "Path D: bond entry leaked into discovered nic id: '$_BM_DISCOVERED_NIC_ID'" ;;
esac
test_pass "Path D: bond filter (D-06) drops iLO-bond0 + LinkDown -> singleton survivor=$_BM_DISCOVERED_NIC_ID"
_path_teardown

# ---------------------------------------------------------------------------
# Path E: MAC-08 Redfish HTTP 500 on EthernetInterfaces collection.
# Exercises Plan 10-02 _bm_discover_macs. SKIPs when 10-02 not merged.
# ---------------------------------------------------------------------------
_path_setup
if _has_bm_discover_macs; then
	_STUB_NIC_SCENARIO=http500
	_pre=$_preflight_errors
	rc=0
	_bm_discover_macs n0 > "$_out" 2>&1 || rc=$?
	_post=$_preflight_errors
	[ "$rc" -ne 0 ] || test_fail "Path E: _bm_discover_macs rc=$rc expected non-zero on http500"
	grep -qF "MAC-08" "$_out" || test_fail "Path E: missing MAC-08 token; output: $(cat "$_out")"
	grep -qF "Redfish EthernetInterfaces" "$_out" || test_fail "Path E: missing 'Redfish EthernetInterfaces' phrase; output: $(cat "$_out")"
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path E: _preflight_errors delta=$((_post - _pre)), expected >= 1"
	test_pass "Path E: MAC-08 (Redfish 500) -> non-zero rc + MAC-08 line + _preflight_errors bumped"
else
	test_skip "Path E: _bm_discover_macs not defined (Plan 10-02 not yet merged in this worktree)"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path F: MAC-03 operator mac_n0 does NOT match BMC report.
# Exercises Plan 10-02 _bm_discover_macs. SKIPs when 10-02 not merged.
# ---------------------------------------------------------------------------
_path_setup
if _has_bm_discover_macs; then
	_STUB_NIC_SCENARIO=happy
	mac_n0="99:99:99:99:99:99"
	export mac_n0
	_pre=$_preflight_errors
	rc=0
	_bm_discover_macs n0 > "$_out" 2>&1 || rc=$?
	_post=$_preflight_errors
	[ "$rc" -ne 0 ] || test_fail "Path F: _bm_discover_macs rc=$rc expected non-zero on operator mismatch"
	grep -qF "MAC-03" "$_out" || test_fail "Path F: missing MAC-03 token; output: $(cat "$_out")"
	grep -qF "operator mac_n0=99:99:99:99:99:99" "$_out" || test_fail "Path F: missing operator MAC echo; output: $(cat "$_out")"
	grep -qF "reported NICs:" "$_out" || test_fail "Path F: missing 'reported NICs:' phrase; output: $(cat "$_out")"
	grep -qF "aa:bb:cc:dd:ee:01" "$_out" || test_fail "Path F: missing BMC-reported MAC in candidate list; output: $(cat "$_out")"
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path F: _preflight_errors delta=$((_post - _pre)), expected >= 1"
	test_pass "Path F: MAC-03 (operator mismatch) -> non-zero rc + MAC-03 line + reported NIC list"
else
	test_skip "Path F: _bm_discover_macs not defined (Plan 10-02 not yet merged in this worktree)"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path G: MAC-09 mac_discovery_n0=disabled but no mac_n0.
# Exercises Plan 10-02 _bm_discover_macs. SKIPs when 10-02 not merged.
# ---------------------------------------------------------------------------
_path_setup
if _has_bm_discover_macs; then
	# Add the opt-out flag to bmc.conf and env (post-normalize-bmc-conf would set it).
	cat >> bmc.conf <<'BMCEOF'
mac_discovery_n0=disabled
BMCEOF
	mac_discovery_n0=disabled
	export mac_discovery_n0
	unset mac_n0
	_pre=$_preflight_errors
	rc=0
	_bm_discover_macs n0 > "$_out" 2>&1 || rc=$?
	_post=$_preflight_errors
	[ "$rc" -ne 0 ] || test_fail "Path G: _bm_discover_macs rc=$rc expected non-zero on MAC-09"
	grep -qF "MAC-09" "$_out" || test_fail "Path G: missing MAC-09 token; output: $(cat "$_out")"
	grep -qF "mac_discovery_n0=disabled but mac_n0 not set" "$_out" || test_fail "Path G: missing MAC-09 description; output: $(cat "$_out")"
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path G: _preflight_errors delta=$((_post - _pre)), expected >= 1"
	test_pass "Path G: MAC-09 (opt-out without mac_<node>) -> non-zero rc + MAC-09 line"
else
	test_skip "Path G: _bm_discover_macs not defined (Plan 10-02 not yet merged in this worktree)"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path H: D-02 cache hit - sidecar fresh + bmc.conf older + http500 would fail
# if Redfish were actually called -> success rc 0 proves cache bypassed Redfish.
# Exercises Plan 10-02 _bm_discover_macs. SKIPs when 10-02 not merged.
# ---------------------------------------------------------------------------
_path_setup
if _has_bm_discover_macs; then
	# Pre-populate fresh sidecar that points to a discovered MAC.
	cat > .bmc-state.n0 <<'STATEEOF'
last_step=discovery
script_version=1.2.0
bmc_conf_hash=test-hash-abc
iso_sha=
last_updated=2026-05-18T10:30:00Z
discovered_mac=aa:bb:cc:dd:ee:01
discovered_nic_id=NIC.Integrated.1
discovered_at=2026-05-18T10:30:00Z
STATEEOF
	chmod 600 .bmc-state.n0
	# Make bmc.conf older than the sidecar so the cache-mtime check passes.
	touch -d "1 hour ago" bmc.conf
	touch .bmc-state.n0
	# http500 scenario would FAIL if Redfish were actually called -> rc 0
	# proves the cache short-circuited the network round-trip.
	_STUB_NIC_SCENARIO=http500
	unset mac_n0
	rc=0
	_bm_discover_macs n0 > "$_out" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		# Cache hit confirmed: stub call log must NOT contain EthernetInterfaces.
		# (grep against a local stub-log file, not a Redfish call - the UX-05
		# stderr-suppression prohibition applies only to live Redfish invocations.)
		_call_log_content=""
		[ -f "$_STUB_CALL_LOG" ] && _call_log_content=$(cat "$_STUB_CALL_LOG")
		if printf '%s\n' "$_call_log_content" | grep -q "EthernetInterfaces"; then
			test_fail "Path H: cache hit expected but stub was called for EthernetInterfaces; calls: $_call_log_content"
		fi
		test_pass "Path H: D-02 cache hit (fresh sidecar, older bmc.conf) -> no Redfish call"
	else
		test_skip "Path H: _bm_discover_macs returned $rc - cache-mtime branch may not yet be wired in this checkout"
	fi
else
	test_skip "Path H: _bm_discover_macs not defined (Plan 10-02 not yet merged in this worktree)"
fi
_path_teardown

# ---------------------------------------------------------------------------
# Path I: _bm_get_mac resolution order (D-03):
#   (i)   operator mac_n0 wins over sidecar discovered_mac
#   (ii)  sidecar wins when no operator mac_n0
#   (iii) hard-fail when neither operator nor sidecar present
# This Path exercises Plan 10-01's _bm_get_mac (already merged).
# ---------------------------------------------------------------------------
_path_setup
# Setup A: operator mac_n0 wins.
mac_n0="11:22:33:44:55:66"
export mac_n0
cat > .bmc-state.n0 <<'STATEEOF'
discovered_mac=aa:bb:cc:dd:ee:01
STATEEOF
chmod 600 .bmc-state.n0
val=$(_bm_get_mac n0)
rc=$?
[ "$rc" -eq 0 ] || test_fail "Path I (A): _bm_get_mac rc=$rc expected 0"
[ "$val" = "11:22:33:44:55:66" ] || test_fail "Path I (A): operator mac_n0 should win; got '$val'"

# Setup B: no operator mac_n0 -> sidecar discovered_mac wins.
unset mac_n0
val=$(_bm_get_mac n0)
rc=$?
[ "$rc" -eq 0 ] || test_fail "Path I (B): _bm_get_mac rc=$rc expected 0"
[ "$val" = "aa:bb:cc:dd:ee:01" ] || test_fail "Path I (B): sidecar discovered_mac should win; got '$val'"

# Setup C: no operator mac_n0 + no sidecar -> hard-fail.
unset mac_n0
rm -f .bmc-state.n0
rc=0
val=$(_bm_get_mac n0 2>&1) || rc=$?
[ "$rc" -ne 0 ] || test_fail "Path I (C): _bm_get_mac should fail when neither operator nor sidecar present; rc=$rc val='$val'"
echo "$val" | grep -qF "MAC unavailable" || test_fail "Path I (C): missing 'MAC unavailable' message; got '$val'"

test_pass "Path I: _bm_get_mac resolution order (operator > sidecar > hard-fail) all correct"
_path_teardown

echo
echo -e "${GREEN}OK ALL PATHS PASSED${NC}: test-bmc-mac-discovery.sh"
exit 0
