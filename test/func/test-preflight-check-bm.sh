#!/bin/bash
# Test: scripts/preflight-check-bm.sh - bare-metal preflight functional test
# Integration test (offline; uses test/func/lib/bmc-redfish-stub.sh; no real BMC)
# Covers TEST-01 (positive L1-L4) + TEST-03 scenarios 1-5 (L1 unreachable, L2 wrong password,
# L3 missing license, L4 forbidden target, PRE-05 query-params URL) + 5 L5 hard-fail Paths

set -e

cd "$(dirname "$0")/../.."

REPO_ROOT=$(pwd)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}OK PASS${NC}: $1"; }
test_skip() { echo -e "${YELLOW}SKIP${NC}: $1"; }
test_fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

# TEST-01 + TEST-03 scenario matrix
#
# | Scenario                              | Path | REQ      | Token to match                      |
# |---------------------------------------|------|----------|-------------------------------------|
# | Positive: L1-L4 all pass (irmc)       | A    | TEST-01  | L1=ok L2=ok L3=ok L4=ok             |
# | L1 unreachable BMC                    | B    | TEST-03  | cannot reach                        |
# | L2 wrong password                     | C    | TEST-03  | L2=FAIL                             |
# | L3 VirtualMedia not licensed          | D    | TEST-03  | VirtualMedia not licensed           |
# | L4 forbidden boot target              | E    | TEST-03  | neither Cd nor UsbCd                |
# | PRE-05 query-params URL               | F    | TEST-03  | iso_url must not contain            |
# | L5 VEN-07 unshipped vendor            | G    | TEST-03  | not certified in this release       |
# | L5 iDRAC10 hard-fail                  | H    | TEST-03  | iDRAC10 not yet supported           |
# | L5 iDRAC9 firmware floor              | I    | TEST-03  | below v1.1 minimum                  |
# | L5 iLO 4 hard-fail                    | J    | TEST-03  | iLO 4 not supported                 |
# | L5 Lenovo Enterprise license missing  | K    | TEST-03  | Lenovo XCC license tier missing     |
#
# Traceability: grep this file for '# Path <letter>:' to see each assertion.

# ---------------------------------------------------------------------------
# Source shared stub library (provides _bmc_stub_curl + _bmc_stub_reset_globals)
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/test/func/lib/bmc-redfish-stub.sh"

# ---------------------------------------------------------------------------
# Source runtime helpers (aba_info_ok / aba_warning / aba_abort / aba_debug
# + normalize-bmc-conf + bmc_redact_env). Must come before preflight script.
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/scripts/include_all.sh"

# ---------------------------------------------------------------------------
# Source the script under test READ-ONLY.
# preflight_check_bm() and all helpers are loaded into this process.
# ---------------------------------------------------------------------------
source "${REPO_ROOT}/scripts/preflight-check-bm.sh"

# ---------------------------------------------------------------------------
# Shared output capture file + top-level temp directory
# ---------------------------------------------------------------------------
_out=$(mktemp)
_top_dir=$(mktemp -d)
trap 'rm -f "$_out"; rm -rf "$_top_dir"' EXIT

echo
echo "=== BMC Preflight Functional Tests (test-preflight-check-bm.sh) ==="
echo

# ---------------------------------------------------------------------------
# _path_setup: prepare a clean isolated workdir for each Path.
#
# Each Path runs from a temp subdirectory that contains a minimal bmc.conf
# (mode 0600). preflight_check_bm reads bmc.conf relative to CWD; by cd-ing
# here we avoid polluting the repo root and support concurrent test runs.
#
# normalize-bmc-conf is overridden in _path_setup so it reads from the per-path
# bmc.conf in the temp dir rather than the repo root (which has none).
#
# Platform=bm must be exported so preflight_check_bm does not short-circuit.
# iso_url uses an IP literal (127.0.0.1) so PRE-05 sub-check 3 (hostname DNS)
# is bypassed and sub-check 4 (HEAD) is served by the stub catch-all.
# ---------------------------------------------------------------------------
_path_setup() {
	_bmc_stub_reset_globals
	_STUB_CALL_LOG=$(mktemp)
	# Override curl() so all Redfish calls go through the stub
	curl() { _bmc_stub_curl "$@"; }
	export -f curl

	_preflight_errors=0
	_preflight_warnings=0
	: > "$_out"

	# Per-path temp workdir with bmc.conf
	_path_dir=$(mktemp -d "${_top_dir}/path.XXXXXX")
	cat > "${_path_dir}/bmc.conf" <<'BMCEOF'
bmc_type_master0=irmc
bmc_host_master0=127.0.0.1
bmc_user_master0=aba-installer
bmc_password_master0=testpass-PLACEHOLDER
bmc_insecure_master0=true
BMCEOF
	chmod 600 "${_path_dir}/bmc.conf"

	# Override normalize-bmc-conf to read from the per-path dir.
	# This avoids the mode-0600 check on a repo-root bmc.conf (which does not exist)
	# while still populating the process env via eval exactly as the real function does.
	normalize-bmc-conf() {
		[ -f "${_path_dir}/bmc.conf" ] || return 0
		local mode
		mode=$(stat -c '%a' "${_path_dir}/bmc.conf")
		case "$mode" in
			*00) : ;;
			*) aba_abort "bmc.conf must be mode 0600 (found: $mode)" ;;
		esac
		local vars
		vars=$(sed -E \
			-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' \
			-e "s/^[ \t]*//g" \
			-e "s/[ \t]*$//g" \
			"${_path_dir}/bmc.conf" | sed -e "s/^/export /g")
		eval "$vars"
		echo "$vars" | grep -v '^export bmc_password_'
	}

	# cd to the path workdir so preflight_check_bm finds bmc.conf via [ -f bmc.conf ]
	pushd "${_path_dir}" > /dev/null

	platform=bm
	export platform
	iso_url=http://127.0.0.1:8080/agent.x86_64.iso
	export iso_url

	# Export bmc vars directly into the current shell.
	# source <(normalize-bmc-conf) evaluates in a process substitution subshell;
	# only the filtered stdout (without bmc_password_*) is sourced back, so
	# bmc_type/host/user/insecure vars set via eval inside the subshell do NOT
	# propagate. Exporting them here ensures preflight_check_bm and all probe
	# helpers (_bm_node_list reads bmc.conf; _bm_build_auth reads bmc_password_*)
	# can access them via ${!varname} indirection.
	bmc_type_master0=irmc
	bmc_host_master0=127.0.0.1
	bmc_user_master0=aba-installer
	bmc_password_master0=testpass-PLACEHOLDER
	bmc_insecure_master0=true
	export bmc_type_master0 bmc_host_master0 bmc_user_master0 bmc_password_master0 bmc_insecure_master0

	# Override _bm_probe_l1 by default for all Paths.
	# _bm_probe_l1 uses bash /dev/tcp which requires a live TCP target (port 443).
	# This test is OFFLINE (no real BMC); overriding L1 to pass keeps every Path
	# focused on the layer it is designed to test.
	# Path B re-overrides _bm_probe_l1 to emit the L1-fail message and test that
	# preflight_check_bm handles L1 failure correctly.
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }

	# Override _bm_discover_macs by default for all Paths.
	# Phase 10 wired _bm_discover_macs into the per-node loop after L1-L5. Paths
	# that don't exercise MAC discovery (Path A-K, the pre-Phase-10 paths) get a
	# pass-through stub so the per-node loop completes cleanly. The dedicated
	# MAC-* Paths (added by Plan 10-03) re-source preflight-check-bm.sh to
	# restore the real helper, then re-stub L1.
	_bm_discover_macs() { aba_debug "BMC: $1 MAC discovery stub-pass (default Path setup)"; return 0; }

	# Pre-populate SYSTEM_ID_master0 + SESSION_TOKEN_master0 so the real
	# _bm_discover_macs (used by mac_* Paths) bypasses bmc_discover_ids and
	# passes _redfish_request's "no active session" guard. The test fixture's
	# L1-L4 use direct curl rather than _redfish_request, so no real Redfish
	# session exists; pre-seeding both caches keeps the mac_* Paths focused on
	# _bm_get_ethernetinterfaces and _bm_resolve_mac (Plan 10-01) without
	# dragging Phase 7 session login into scope.
	SYSTEM_ID_master0="0"
	SESSION_TOKEN_master0="stub-token"
	export SYSTEM_ID_master0 SESSION_TOKEN_master0
}

_path_teardown() {
	popd > /dev/null
	unset -f curl
	unset -f normalize-bmc-conf
	# Restore the real _bm_probe_l* implementations from the sourced script.
	# _path_setup overrides _bm_probe_l1 (default stub-pass); individual Paths
	# may also override _bm_probe_l2/l3/l4. Re-sourcing restores all of them
	# without permanently unsetting functions from the script under test.
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"
	unset platform iso_url
	unset bmc_type_master0 bmc_host_master0 bmc_user_master0 bmc_password_master0 bmc_insecure_master0
	rm -f "$_STUB_CALL_LOG"
}

# ---------------------------------------------------------------------------
# Path A: Positive - L1-L4 all pass with bmc_type=irmc
# TEST-01 satisfied: preflight_check_bm runs end-to-end against the stub
# with no errors; output contains the verbatim L1=ok L2=ok L3=ok L4=ok token.
# ---------------------------------------------------------------------------
# Path A: Positive L1-L4 happy path (irmc)
_path_setup
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -eq 0 ] || test_fail "Path A: expected 0 _preflight_errors delta, got $((_post - _pre))"
grep -qF "L1=ok L2=ok L3=ok L4=ok" "$_out" || test_fail "Path A: missing 'L1=ok L2=ok L3=ok L4=ok' substring; output was: $(cat "$_out")"
test_pass "Path A: positive L1-L4 happy path"
_path_teardown

# ---------------------------------------------------------------------------
# Path B: L1 unreachable BMC (TEST-03 scenario 1, PRE-01)
# Override _bm_probe_l1 to emit the L1=FAIL message and bump _preflight_errors,
# exactly as the real probe does when bash /dev/tcp connection is refused.
# This keeps the test offline (no real TCP required) while exercising the
# preflight_check_bm orchestration path that handles an L1 failure.
# ---------------------------------------------------------------------------
# Path B: L1 unreachable BMC (TEST-03 scenario 1)
_path_setup
_bm_probe_l1() {
	local node="$1"
	local host_var="bmc_host_${node}"
	local host="${!host_var}"
	aba_warning "BMC: $node L1=FAIL reason=\"cannot reach $host:443 (TCP): Connection refused - check DNS/firewall/bmc_host_${node}\""
	_preflight_errors=$(( _preflight_errors + 1 ))
	return 1
}
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path B: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "cannot reach" "$_out" || test_fail "Path B: missing 'cannot reach' substring; output was: $(cat "$_out")"
test_pass "Path B: L1 unreachable -> _preflight_errors increment + 'cannot reach' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path C: L2 wrong password (TEST-03 scenario 2, PRE-02)
# _STUB_AUTH_FAIL=true makes the stub return 401 on GET /redfish/v1/.
# _bm_probe_l2 detects HTTP 401 and emits the L2=FAIL message.
# bmc_host_master0=127.0.0.1 port 443 must NOT be open; we use
# bmc_host_master0=stub-irmc.lab.example (DNS-unresolvable) so L1 probe
# (bash /dev/tcp) fails at L1 before L2. To force L2, we override _bm_probe_l1
# to pass so the auth test at L2 is reached.
# ---------------------------------------------------------------------------
# Path C: L2 wrong password (TEST-03 scenario 2)
# _path_setup provides a passing _bm_probe_l1 stub; L2 is reached via the curl override.
_path_setup
_STUB_AUTH_FAIL=true
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path C: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "L2=FAIL" "$_out" || test_fail "Path C: missing 'L2=FAIL' substring; output was: $(cat "$_out")"
test_pass "Path C: L2 wrong password -> _preflight_errors increment + 'L2=FAIL' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path D: L3 VirtualMedia not licensed (TEST-03 scenario 3, PRE-03)
# _STUB_LICENSE_MISSING=true returns 403 on GET /Managers/<id>/VirtualMedia.
# _bm_probe_l1 and _bm_probe_l2 are overridden to pass so L3 is reached.
# ---------------------------------------------------------------------------
# Path D: L3 VirtualMedia not licensed (TEST-03 scenario 3)
# _path_setup provides passing L1 stub; L2 stub-pass needed so L3 is reached.
_path_setup
_STUB_LICENSE_MISSING=true
_bm_probe_l2() { aba_debug "BMC: $1 L2 stub-pass"; return 0; }
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path D: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "VirtualMedia not licensed" "$_out" || test_fail "Path D: missing 'VirtualMedia not licensed' substring; output was: $(cat "$_out")"
test_pass "Path D: L3 missing license -> _preflight_errors increment + 'VirtualMedia not licensed' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path E: L4 forbidden boot target (TEST-03 scenario 4, PRE-04)
# _STUB_FORBID_TARGET=Cd removes Cd from BootSourceOverrideTarget AllowableValues.
# L1-L3 are overridden to pass so L4 is reached.
# ---------------------------------------------------------------------------
# Path E: L4 forbidden boot target (TEST-03 scenario 4)
# _path_setup provides passing L1 stub; L2 and L3 also overridden to pass so L4 is reached.
_path_setup
_STUB_FORBID_TARGET=Cd
_bm_probe_l2() { aba_debug "BMC: $1 L2 stub-pass"; return 0; }
_bm_probe_l3() { aba_debug "BMC: $1 L3 stub-pass"; return 0; }
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path E: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "neither Cd nor UsbCd" "$_out" || test_fail "Path E: missing 'neither Cd nor UsbCd' substring; output was: $(cat "$_out")"
test_pass "Path E: L4 forbidden target -> _preflight_errors increment + 'neither Cd nor UsbCd' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path F: PRE-05 iso_url with query params (TEST-03 scenario 5)
# iso_url contains ?foo=bar; _bm_validate_iso_url rejects it with PRE-05 message.
# L1 probe uses 127.0.0.1 which may pass or fail; we only assert the PRE-05
# iso_url message fires. Because _bm_validate_iso_url runs before the per-node
# loop, the PRE-05 error fires even if L1 would also fail.
# ---------------------------------------------------------------------------
# Path F: PRE-05 query-params iso_url (TEST-03 scenario 5)
_path_setup
iso_url='http://127.0.0.1:8080/agent.x86_64.iso?foo=bar'
export iso_url
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path F: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "iso_url must not contain" "$_out" || test_fail "Path F: missing 'iso_url must not contain' substring; output was: $(cat "$_out")"
test_pass "Path F: PRE-05 query-params URL -> _preflight_errors increment + 'iso_url must not contain' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path G: VEN-07 unshipped vendor message
# NOTE: As of Phase 8 Plan 06, _BM_SHIPPED_VENDORS contains all 6 values
# (irmc redfish idrac ilo supermicro lenovo). VEN-07 fires only when bmc_type
# is in the syntactic CFG-03 allowlist but NOT in _BM_SHIPPED_VENDORS.
# Since every allowed type is currently shipped, this path is unreachable
# via bmc_type alone without editing the shipped list.
# This Path uses a direct unit test of _bm_check_shipped_vendors with a
# temporary override of _BM_SHIPPED_VENDORS to demonstrate the VEN-07 message.
# ---------------------------------------------------------------------------
# Path G: VEN-07 unshipped vendor (unit-level override of _BM_SHIPPED_VENDORS)
# _path_setup provides passing L1 stub. Temporarily narrow the shipped list so
# 'irmc' is not in it, triggering _bm_check_shipped_vendors to emit VEN-07 message.
_path_setup
_BM_SHIPPED_VENDORS_ORIG="$_BM_SHIPPED_VENDORS"
_BM_SHIPPED_VENDORS="redfish"
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
_BM_SHIPPED_VENDORS="$_BM_SHIPPED_VENDORS_ORIG"
[ $((_post - _pre)) -ge 1 ] || test_fail "Path G: expected _preflight_errors delta >= 1 (VEN-07 gate), got $((_post - _pre)); output was: $(cat "$_out")"
grep -qF "not certified in this release" "$_out" || test_fail "Path G: missing 'not certified in this release' substring; output was: $(cat "$_out")"
test_pass "Path G: VEN-07 unshipped vendor -> 'not certified in this release' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path H: iDRAC10 hard-fail (Phase 8 D-05a)
# Stub returns Manager .Model="iDRAC10"; _bm_probe_l5_idrac detects the string
# and emits the hard-fail message. L1-L4 are overridden to pass so L5 is reached.
# ---------------------------------------------------------------------------
# Path H: iDRAC10 hard-fail
# _path_setup provides passing L1 stub; L2-L4 also overridden so L5 is reached.
_path_setup
cat > "${_path_dir}/bmc.conf" <<'BMCEOF'
bmc_type_master0=idrac
bmc_host_master0=127.0.0.1
bmc_user_master0=aba-installer
bmc_password_master0=testpass-PLACEHOLDER
bmc_insecure_master0=true
BMCEOF
chmod 600 "${_path_dir}/bmc.conf"
bmc_password_master0=testpass-PLACEHOLDER
export bmc_password_master0
_STUB_MANAGER_ID=iDRAC.Embedded.1
_STUB_VENDOR_MODEL="iDRAC10"
_STUB_FIRMWARE_VERSION="7.00.00.00"
_bm_probe_l2() { aba_debug "BMC: $1 L2 stub-pass"; return 0; }
_bm_probe_l3() { aba_debug "BMC: $1 L3 stub-pass"; return 0; }
_bm_probe_l4() { aba_debug "BMC: $1 L4 stub-pass"; return 0; }
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path H: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "iDRAC10 not yet supported" "$_out" || test_fail "Path H: missing 'iDRAC10 not yet supported' substring; output was: $(cat "$_out")"
test_pass "Path H: iDRAC10 hard-fail -> 'iDRAC10 not yet supported' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path I: iDRAC9 firmware floor below minimum (Phase 8 D-05b)
# Stub returns Manager .Model="Integrated Dell Remote Access Controller"
# (iDRAC9 model string) with .FirmwareVersion="4.00.00.00" which is below the
# minimum 4.40.10.00 floor. L1-L4 overridden to pass.
# ---------------------------------------------------------------------------
# Path I: iDRAC9 firmware floor below v1.1 minimum
# _path_setup provides passing L1 stub; L2-L4 also overridden so L5 is reached.
_path_setup
cat > "${_path_dir}/bmc.conf" <<'BMCEOF'
bmc_type_master0=idrac
bmc_host_master0=127.0.0.1
bmc_user_master0=aba-installer
bmc_password_master0=testpass-PLACEHOLDER
bmc_insecure_master0=true
BMCEOF
chmod 600 "${_path_dir}/bmc.conf"
bmc_password_master0=testpass-PLACEHOLDER
export bmc_password_master0
_STUB_MANAGER_ID=iDRAC.Embedded.1
_STUB_VENDOR_MODEL="Integrated Dell Remote Access Controller"
_STUB_FIRMWARE_VERSION="4.00.00.00"
_bm_probe_l2() { aba_debug "BMC: $1 L2 stub-pass"; return 0; }
_bm_probe_l3() { aba_debug "BMC: $1 L3 stub-pass"; return 0; }
_bm_probe_l4() { aba_debug "BMC: $1 L4 stub-pass"; return 0; }
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path I: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "below v1.1 minimum" "$_out" || test_fail "Path I: missing 'below v1.1 minimum' substring; output was: $(cat "$_out")"
test_pass "Path I: iDRAC9 firmware floor -> 'below v1.1 minimum' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path J: iLO 4 hard-fail (Phase 8 D-08)
# Stub returns Manager .Model="iLO 4"; _bm_probe_l5_ilo matches the string
# (case-insensitive) and emits the hard-fail. L1-L4 overridden to pass.
# ---------------------------------------------------------------------------
# Path J: iLO 4 hard-fail
# _path_setup provides passing L1 stub; L2-L4 also overridden so L5 is reached.
_path_setup
cat > "${_path_dir}/bmc.conf" <<'BMCEOF'
bmc_type_master0=ilo
bmc_host_master0=127.0.0.1
bmc_user_master0=aba-installer
bmc_password_master0=testpass-PLACEHOLDER
bmc_insecure_master0=true
BMCEOF
chmod 600 "${_path_dir}/bmc.conf"
bmc_password_master0=testpass-PLACEHOLDER
export bmc_password_master0
_STUB_MANAGER_ID=1
_STUB_VENDOR_MODEL="iLO 4"
_STUB_FIRMWARE_VERSION="2.78"
_bm_probe_l2() { aba_debug "BMC: $1 L2 stub-pass"; return 0; }
_bm_probe_l3() { aba_debug "BMC: $1 L3 stub-pass"; return 0; }
_bm_probe_l4() { aba_debug "BMC: $1 L4 stub-pass"; return 0; }
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path J: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "iLO 4 not supported" "$_out" || test_fail "Path J: missing 'iLO 4 not supported' substring; output was: $(cat "$_out")"
test_pass "Path J: iLO 4 hard-fail -> 'iLO 4 not supported' substring"
_path_teardown

# ---------------------------------------------------------------------------
# Path K: Lenovo Enterprise license missing (Phase 8 D-13)
# _STUB_LENOVO_LICENSE_TIER=Basic injects Oem.Lenovo.LicenseFeatures=["Basic"]
# into the Manager resource body. Since "Basic" contains neither RemoteMedia nor
# VirtualMedia, _bm_probe_l5_lenovo emits the hard-fail message.
# L1-L4 overridden to pass. _bmc_stub_curl handles the Managers + Manager
# GET calls; _stub_emit_manager_resource injects the OEM block when
# _STUB_LENOVO_LICENSE_TIER is set.
# ---------------------------------------------------------------------------
# Path K: Lenovo Enterprise license tier missing
# _path_setup provides passing L1 stub; L2-L4 also overridden so L5 is reached.
_path_setup
cat > "${_path_dir}/bmc.conf" <<'BMCEOF'
bmc_type_master0=lenovo
bmc_host_master0=127.0.0.1
bmc_user_master0=aba-installer
bmc_password_master0=testpass-PLACEHOLDER
bmc_insecure_master0=true
BMCEOF
chmod 600 "${_path_dir}/bmc.conf"
bmc_password_master0=testpass-PLACEHOLDER
export bmc_password_master0
_STUB_MANAGER_ID=1
_STUB_VENDOR_MODEL="Lenovo XCC"
_STUB_FIRMWARE_VERSION="3.00"
_STUB_LENOVO_LICENSE_TIER=Basic
_bm_probe_l2() { aba_debug "BMC: $1 L2 stub-pass"; return 0; }
_bm_probe_l3() { aba_debug "BMC: $1 L3 stub-pass"; return 0; }
_bm_probe_l4() { aba_debug "BMC: $1 L4 stub-pass"; return 0; }
_pre=$_preflight_errors
preflight_check_bm > "$_out" 2>&1 || true
_post=$_preflight_errors
[ $((_post - _pre)) -ge 1 ] || test_fail "Path K: expected _preflight_errors delta >= 1, got $((_post - _pre))"
grep -qF "Lenovo XCC license tier missing" "$_out" || test_fail "Path K: missing 'Lenovo XCC license tier missing' substring; output was: $(cat "$_out")"
test_pass "Path K: Lenovo Enterprise license missing -> 'Lenovo XCC license tier missing' substring"
_path_teardown

# ===========================================================================
# Phase 10 MAC discovery preflight-integration Paths (Plan 10-03 Task 3).
# These Paths exercise MAC discovery dispatched through the full
# preflight_check_bm entry point (vs. test-bmc-mac-discovery.sh which tests
# the helpers in isolation). Each Path expects _bm_discover_macs to fire
# inside the per-node loop and emit the MAC-NN error line.
#
# _bm_discover_macs is wired into preflight_check_bm by sibling Plan 10-02
# (same wave). At this branch base 10-02 is NOT yet merged; the Paths below
# self-report as SKIP via a declare -F guard so the existing TEST-01..03
# coverage continues to PASS. After the orchestrator merges 10-02 and 10-03,
# all 6 new Paths run and pass.
# ===========================================================================

_mac_disco_wired() {
	declare -F _bm_discover_macs > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Path mac_happy: per-node success line ends with MAC=ok (Plan 10-02 Task 1
# step 5 updates the aba_info_ok format to include MAC=ok).
# ---------------------------------------------------------------------------
# path_mac_happy
_path_setup_mac_happy() {
	_path_setup
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"  # restore real _bm_discover_macs
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }
	_STUB_NIC_SCENARIO=happy
	unset mac_master0
}
_path_assert_mac_happy() {
	grep -qF "MAC=ok" "$_out" || test_fail "Path mac_happy: missing 'MAC=ok' in per-node success line; output: $(cat "$_out")"
	test_pass "Path mac_happy: preflight per-node success line ends with MAC=ok"
}
if _mac_disco_wired; then
	_path_setup_mac_happy
	preflight_check_bm > "$_out" 2>&1 || true
	_path_assert_mac_happy
	_path_teardown
else
	test_skip "Path mac_happy: _bm_discover_macs not wired into preflight_check_bm (Plan 10-02 not yet merged)"
fi

# ---------------------------------------------------------------------------
# Path mac_03: operator mac_master0 set; BMC reports different MAC -> MAC-03.
# ---------------------------------------------------------------------------
# path_mac_03
_path_setup_mac_03() {
	_path_setup
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"  # restore real _bm_discover_macs
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }
	_STUB_NIC_SCENARIO=happy
	mac_master0="99:99:99:99:99:99"
	export mac_master0
}
_path_assert_mac_03() {
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path mac_03: expected _preflight_errors delta >= 1, got $((_post - _pre)); output: $(cat "$_out")"
	grep -qF "BMC: master0 MAC-03" "$_out" || test_fail "Path mac_03: missing 'BMC: master0 MAC-03' prefix; output: $(cat "$_out")"
	grep -qF "operator mac_master0=99:99:99:99:99:99" "$_out" || test_fail "Path mac_03: missing operator MAC echo; output: $(cat "$_out")"
	grep -qF "reported NICs:" "$_out" || test_fail "Path mac_03: missing 'reported NICs:' phrase; output: $(cat "$_out")"
	test_pass "Path mac_03: preflight MAC-03 (operator mismatch) -> 'BMC: master0 MAC-03' line + operator MAC echo"
}
if _mac_disco_wired; then
	_path_setup_mac_03
	_pre=$_preflight_errors
	preflight_check_bm > "$_out" 2>&1 || true
	_post=$_preflight_errors
	_path_assert_mac_03
	_path_teardown
else
	test_skip "Path mac_03: _bm_discover_macs not wired into preflight_check_bm (Plan 10-02 not yet merged)"
fi

# ---------------------------------------------------------------------------
# Path mac_04: stub returns NICs with no LinkUp -> MAC-04.
# ---------------------------------------------------------------------------
# path_mac_04
_path_setup_mac_04() {
	_path_setup
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"  # restore real _bm_discover_macs
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }
	_STUB_NIC_SCENARIO=no-linkup
	unset mac_master0
}
_path_assert_mac_04() {
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path mac_04: expected _preflight_errors delta >= 1, got $((_post - _pre)); output: $(cat "$_out")"
	grep -qF "BMC: master0 MAC-04" "$_out" || test_fail "Path mac_04: missing 'BMC: master0 MAC-04' prefix; output: $(cat "$_out")"
	grep -qF "no enabled NIC with link reported" "$_out" || test_fail "Path mac_04: missing MAC-04 description; output: $(cat "$_out")"
	test_pass "Path mac_04: preflight MAC-04 (no LinkUp NIC) -> 'BMC: master0 MAC-04' line"
}
if _mac_disco_wired; then
	_path_setup_mac_04
	_pre=$_preflight_errors
	preflight_check_bm > "$_out" 2>&1 || true
	_post=$_preflight_errors
	_path_assert_mac_04
	_path_teardown
else
	test_skip "Path mac_04: _bm_discover_macs not wired into preflight_check_bm (Plan 10-02 not yet merged)"
fi

# ---------------------------------------------------------------------------
# Path mac_05: stub returns 2 LinkUp+Enabled NICs -> MAC-05.
# ---------------------------------------------------------------------------
# path_mac_05
_path_setup_mac_05() {
	_path_setup
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"  # restore real _bm_discover_macs
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }
	_STUB_NIC_SCENARIO=ambiguous
	_STUB_NIC_MACS="aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02"
	unset mac_master0
}
_path_assert_mac_05() {
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path mac_05: expected _preflight_errors delta >= 1, got $((_post - _pre)); output: $(cat "$_out")"
	grep -qF "BMC: master0 MAC-05" "$_out" || test_fail "Path mac_05: missing 'BMC: master0 MAC-05' prefix; output: $(cat "$_out")"
	grep -qF "ambiguous" "$_out" || test_fail "Path mac_05: missing 'ambiguous' word; output: $(cat "$_out")"
	grep -qF "set mac_master0=" "$_out" || test_fail "Path mac_05: missing disambiguation hint; output: $(cat "$_out")"
	test_pass "Path mac_05: preflight MAC-05 (ambiguous) -> 'BMC: master0 MAC-05' line + disambiguation hint"
}
if _mac_disco_wired; then
	_path_setup_mac_05
	_pre=$_preflight_errors
	preflight_check_bm > "$_out" 2>&1 || true
	_post=$_preflight_errors
	_path_assert_mac_05
	_path_teardown
else
	test_skip "Path mac_05: _bm_discover_macs not wired into preflight_check_bm (Plan 10-02 not yet merged)"
fi

# ---------------------------------------------------------------------------
# Path mac_08: stub returns 500 on EthernetInterfaces collection -> MAC-08.
# ---------------------------------------------------------------------------
# path_mac_08
_path_setup_mac_08() {
	_path_setup
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"  # restore real _bm_discover_macs
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }
	_STUB_NIC_SCENARIO=http500
	unset mac_master0
}
_path_assert_mac_08() {
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path mac_08: expected _preflight_errors delta >= 1, got $((_post - _pre)); output: $(cat "$_out")"
	grep -qF "BMC: master0 MAC-08" "$_out" || test_fail "Path mac_08: missing 'BMC: master0 MAC-08' prefix; output: $(cat "$_out")"
	grep -qF "Redfish EthernetInterfaces" "$_out" || test_fail "Path mac_08: missing 'Redfish EthernetInterfaces' phrase; output: $(cat "$_out")"
	test_pass "Path mac_08: preflight MAC-08 (Redfish 500) -> 'BMC: master0 MAC-08' line"
}
if _mac_disco_wired; then
	_path_setup_mac_08
	_pre=$_preflight_errors
	preflight_check_bm > "$_out" 2>&1 || true
	_post=$_preflight_errors
	_path_assert_mac_08
	_path_teardown
else
	test_skip "Path mac_08: _bm_discover_macs not wired into preflight_check_bm (Plan 10-02 not yet merged)"
fi

# ---------------------------------------------------------------------------
# Path mac_09: bmc.conf opts out (mac_discovery_master0=disabled) but no
# mac_master0 -> MAC-09 hard-fail.
# ---------------------------------------------------------------------------
# path_mac_09
_path_setup_mac_09() {
	_path_setup
	source "${REPO_ROOT}/scripts/preflight-check-bm.sh"  # restore real _bm_discover_macs
	_bm_probe_l1() { aba_debug "BMC: $1 L1 stub-pass (offline test)"; return 0; }
	# Append the opt-out flag to bmc.conf and export to env so preflight sees it.
	cat >> bmc.conf <<'BMCEOF'
mac_discovery_master0=disabled
BMCEOF
	mac_discovery_master0=disabled
	export mac_discovery_master0
	unset mac_master0
}
_path_assert_mac_09() {
	[ $((_post - _pre)) -ge 1 ] || test_fail "Path mac_09: expected _preflight_errors delta >= 1, got $((_post - _pre)); output: $(cat "$_out")"
	grep -qF "BMC: master0 MAC-09" "$_out" || test_fail "Path mac_09: missing 'BMC: master0 MAC-09' prefix; output: $(cat "$_out")"
	grep -qF "mac_discovery_master0=disabled but mac_master0 not set" "$_out" || test_fail "Path mac_09: missing MAC-09 description; output: $(cat "$_out")"
	test_pass "Path mac_09: preflight MAC-09 (opt-out without mac_<node>) -> 'BMC: master0 MAC-09' line"
}
if _mac_disco_wired; then
	_path_setup_mac_09
	_pre=$_preflight_errors
	preflight_check_bm > "$_out" 2>&1 || true
	_post=$_preflight_errors
	_path_assert_mac_09
	_path_teardown
else
	test_skip "Path mac_09: _bm_discover_macs not wired into preflight_check_bm (Plan 10-02 not yet merged)"
fi

echo
echo -e "${GREEN}OK ALL PATHS PASSED${NC}: test-preflight-check-bm.sh"
exit 0
