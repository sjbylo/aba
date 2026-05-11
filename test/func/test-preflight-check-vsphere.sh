#!/bin/bash
# Test: Verify scripts/preflight-check-vsphere.sh structure, coding standards, and runtime behaviour.
# Unit test (fast, static assertions + in-process behavioural smoke; no network).

set -e

# ============================================================================
# TEST-02 negative-path matrix: 7 scenarios -> existing lettered Paths.
# ============================================================================
# Each scenario asserts a non-zero exit (via `_preflight_errors` > 0 at the
# summary-emit site) PLUS a scenario-distinguishing substring match. Assertions
# use substring matches on key tokens (D-03) and counter-delta checks (D-04);
# they do NOT use exact-line equality or `^vSphere:` regex anchors.
#
# | Scenario                    | Path  | Distinguishing substring + counter-delta |
# |-----------------------------|-------|------------------------------------------|
# | Unreachable vCenter (TCP)   | D     | 'cannot reach'             + errors += 1 |
# | Untrusted CA (TLS)          | E     | 'trust chain failure'      + errors += 1 |
# | Wrong password (auth)       | G     | 'authentication to'        + errors += 1 |
# | Missing datastore           | J     | 'datastore ... not found'  + errors += 1 |
# | Missing network             | I     | 'network ... not attached' + errors += 1 |
# | Missing folder              | H+AA  | 'datacenter not found' DC-cascade (Path H); dedicated folder-missing Path AA added |
# | Missing privilege           | Q-Z   | "missing privilege '..."   + errors += N |
#
# Traceability: grep this file for 'Path <letter>:' to reach each assertion.
# ============================================================================

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }

SCRIPT="scripts/preflight-check-vsphere.sh"

echo
echo "=== Testing: $SCRIPT ==="
echo

# 1. File exists
[ -f "$SCRIPT" ] && test_pass "File exists" || test_fail "File not found: $SCRIPT"

# 2. Syntax check
bash -n "$SCRIPT" && test_pass "Syntax check passed" || test_fail "Syntax check failed"

# 3. Defines preflight_check_vsphere function
grep -q '^preflight_check_vsphere()' "$SCRIPT" && \
	test_pass "Defines function: preflight_check_vsphere" || \
	test_fail "Missing function: preflight_check_vsphere"

# 4. Does NOT re-source scripts/include_all.sh (parent preflight-check.sh already did)
if grep -q 'source scripts/include_all.sh' "$SCRIPT"; then
	test_fail "Sourced file must not re-source include_all.sh"
else
	test_pass "Does not re-source include_all.sh"
fi

# 5. Uses TABS for indentation (project standard; see CLAUDE.md)
# Match lines that start with one or more spaces but are NOT pure comment lines.
if grep -Pn '^ +[^#]' "$SCRIPT" >/dev/null; then
	test_fail "Uses spaces for indentation (should use tabs)"
else
	test_pass "Uses tabs for indentation"
fi

# 6. No $ABA_ROOT usage (only scripts/aba.sh uses $ABA_ROOT per CLAUDE.md)
if grep -q '\$ABA_ROOT' "$SCRIPT"; then
	test_fail "Uses \$ABA_ROOT (only scripts/aba.sh should)"
else
	test_pass "No \$ABA_ROOT usage"
fi

# 7. No broken $(<file 2>/dev/null) pattern
if grep -q '\$(<.*2>/dev/null)' "$SCRIPT"; then
	test_fail "Uses broken \$(<file 2>/dev/null) pattern"
else
	test_pass "No broken \$(<file 2>/dev/null) pattern"
fi

# 8. NOT executable (sourced file, not exec'd)
if [ -x "$SCRIPT" ]; then
	test_fail "Sourced file must not be executable"
else
	test_pass "Not executable (sourced file)"
fi

# 9. NO shebang as first line (sourced file)
first_line=$(head -1 "$SCRIPT")
case "$first_line" in
	'#!'*) test_fail "Sourced file must not have a shebang (got: $first_line)" ;;
	*) test_pass "No shebang (sourced file)" ;;
esac

# 10. Uses the safe counter-bump idiom (CLAUDE.md: never (( var++ )) )
if grep -q '_preflight_errors=$(( _preflight_errors + 1 ))' "$SCRIPT"; then
	test_pass "Uses safe counter-bump idiom"
else
	test_fail "Missing safe counter-bump idiom: _preflight_errors=\$(( _preflight_errors + 1 ))"
fi

# 11. No (( var++ )) or (( var-- )) anywhere (CLAUDE.md)
if grep -Pn '\(\(\s*\w+\s*(\+\+|--)\s*\)\)' "$SCRIPT" >/dev/null; then
	test_fail "Uses banned (( var++ )) / (( var-- )) arithmetic"
else
	test_pass "No (( var++ )) / (( var-- )) arithmetic"
fi

# 12. No trailing whitespace on any line
if grep -Pn '\s+$' "$SCRIPT" >/dev/null; then
	test_fail "Contains lines with trailing whitespace"
else
	test_pass "No trailing whitespace on any line"
fi

# 13. No banned stderr-suppression patterns (CLAUDE.md).
# Narrow exceptions (each matched by its own grep -v filter):
#   - 'command -v <tool> >/dev/null'  (stdout-only, Phase 1 D-15)
#   - '/dev/tcp/...'  (the NTP-probe idiom at scripts/preflight-check.sh:75 -
#     2>/dev/null is INSIDE the bash -c subshell to suppress bash's own
#     "connect: Connection refused" stderr noise; Phase 2 Pitfall 6 in RESEARCH.md)
# We reject any '2>/dev/null', '&>/dev/null', '>/dev/null 2>&1', or '2>&1 |' outside these.
banned=$(grep -nE '(2>/dev/null|&>/dev/null|>/dev/null 2>&1|2>&1 \|)' "$SCRIPT" \
	| grep -Pv '^\d+:\s*#' \
	| grep -v 'command -v' \
	| grep -v '/dev/tcp/' \
	|| true)
if [ -n "$banned" ]; then
	test_fail "Contains banned stderr-suppression patterns"
else
	test_pass "No banned stderr-suppression patterns"
fi

# 14. Every aba_* user-visible call passes a message starting with "vSphere:" (D-12, UX-03).
# Collect all aba_* output calls; flag any whose first string arg does NOT start with 'vSphere:'.
calls=$(grep -nE 'aba_(info|info_ok|warning|abort|debug)[[:space:]]+"' "$SCRIPT" || true)
bad_prefix=$(echo "$calls" | grep -vE 'aba_(info|info_ok|warning|abort|debug)[[:space:]]+"vSphere:' || true)
[ -z "$calls" ] && bad_prefix=""
if [ -n "$bad_prefix" ]; then
	test_fail "aba_* calls found that don't prefix message with 'vSphere:'"
else
	test_pass "All aba_* messages are prefixed with vSphere:"
fi

# 15. No internal-ticket tokens in the shipped code (DOC-03)
# Matches JIRA-style IDs: 4-7 uppercase letters, a dash, and digits (e.g. PROJ-123)
if grep -Eq '\b[A-Z]{4,7}-[0-9]+\b' "$SCRIPT"; then
	test_fail "Contains internal-ticket reference (matched [A-Z]{4,7}-[0-9]+)"
else
	test_pass "No internal-ticket references"
fi

# 16. Uses normalize-vmware-conf (INT-05)
if grep -q 'source <(normalize-vmware-conf)' "$SCRIPT"; then
	test_pass "Loads vmware.conf via normalize-vmware-conf"
else
	test_fail "Missing normalize-vmware-conf invocation"
fi

# 17. Uses the allowed narrow exception for govc probe (comment required)
if grep -q 'command -v govc >/dev/null' "$SCRIPT"; then
	test_pass "Probes govc via allowed narrow exception"
else
	test_fail "Missing 'command -v govc >/dev/null' probe"
fi

# -------- Behavioural smoke (three runtime paths) ----------------------------
# Source the file in this process with stub aba_* helpers and exercise the three paths.
# Functions are called directly (not via subshell $(...)) so that _preflight_errors
# mutations propagate correctly to this shell - matching real usage in preflight-check.sh.

# Stub aba_* helpers so messages become predictable strings.
# aba_warning honours the same -p PREFIX / -c COLOR / -n flags the production helper
# accepts (scripts/include_all.sh aba_warning), so callers using `-p Error` produce
# ERROR-prefixed lines, matching the label the user sees in the real install flow.
aba_info()      { echo "INFO: $*"; }
aba_info_ok()   { echo "OK: $*"; }
aba_warning() {
	local prefix=WARN
	while [ $# -gt 0 ]; do
		case "$1" in
			-p) prefix=$(echo "$2" | tr '[:lower:]' '[:upper:]'); shift 2 ;;
			-c) shift 2 ;;
			-n) shift ;;
			*) break ;;
		esac
	done
	echo "$prefix: $*"
}
aba_abort()     { echo "ABORT: $*"; return 0; }
aba_debug()     { :; }
# Stub normalize-vmware-conf: the function is invoked as a command inside source <(...)
# The process substitution runs normalize-vmware-conf and sources its stdout as shell code.
# Outputting nothing from the stub produces a source of an empty stream (no-op).
normalize-vmware-conf() { :; }

# -------- Phase 2 stubs (argument-dispatch govc + openssl + helpers) ---------
# Each stub reads test-controlled env vars to decide behaviour, so Path D-P can
# configure failure modes without rewriting the stub. Defaults emit canned success.
#
# govc() dispatches on $1 (subcommand). For object.collect, parses argv for -s <path>.
# Path shape conventions used by Path D-P below:
#   /MissingDC/*                         -> return 1 ("not found")
#   /GoodDC/host/Missing*                -> return 1 ("not found")
#   /GoodDC/datastore/Missing*           -> return 1 ("not found")
#   /GoodDC/network/Missing*             -> return 1 ("not found")
#   /MissingFolder*                      -> return 1 ("not found")
#   /GoodDC/network/*    (prop=host)     -> emit "HostSystem:host-1"
#   /GoodDC/network/WrongCluster* (host) -> emit "HostSystem:host-99" (no overlap)
#   /GoodDC/*            (prop=name)     -> emit "GoodName"
#
# find -i -type h /GoodDC/host/GoodCluster -> "HostSystem:host-1"
#
# permissions.ls dispatches via GOVC_STUB_PERMS_OUT (full captured output) + GOVC_STUB_PERMS_RC.
# role.ls dispatches via GOVC_STUB_ROLE_OUT + GOVC_STUB_ROLE_RC.
# about dispatches via GOVC_STUB_ABOUT_RC.
govc() {
	case "$1" in
		about)
			return "${GOVC_STUB_ABOUT_RC:-0}"
			;;
		object.collect)
			# Parse for -s <path> [property]. We tolerate the argument order
			# used by production: `govc object.collect -s <path> <property>`.
			local path="" prop=""
			shift
			while [ $# -gt 0 ]; do
				case "$1" in
					-s) path="$2"; shift 2 ;;
					*)  prop="$1"; shift ;;
				esac
			done
			# For RES-04 attachment check (prop == "host"), emit host morefs.
			if [ "$prop" = "host" ]; then
				case "$path" in
					*/network/WrongCluster*) echo "HostSystem:host-99"; return 0 ;;
					*/network/*)             echo "HostSystem:host-1";  return 0 ;;
				esac
			fi
			# Generic existence probe (prop == "name").
			case "$path" in
				/MissingDC*)                 return 1 ;;
				/MissingPool*)               return 1 ;;
				/GoodDC/datastore/Missing*)  return 1 ;;
				/GoodDC/host/Missing*)       return 1 ;;
				/GoodDC/network/Missing*)    return 1 ;;
				/MissingFolder*)             return 1 ;;
				/GoodDC*)                    echo "GoodName"; return 0 ;;
				*)                           return 1 ;;
			esac
			;;
		find)
			# govc find -i -type h /GoodDC/host/GoodCluster -> one cluster host moref.
			echo "HostSystem:host-1"
			return 0
			;;
		permissions.ls)
			# Phase 3 extension: per-scope-path dispatch via
			# GOVC_STUB_PERMS_OUT_<sanitized-path>; falls back to the flat
			# GOVC_STUB_PERMS_OUT for backward-compat with Paths M/N/O/P.
			# Use `printf '%s'` (not `echo`): echo appends a trailing newline,
			# which `tr -c '[:alnum:]' '_'` maps to `_`, producing wrong keys.
			local scope_arg="$2"
			local out_key="GOVC_STUB_PERMS_OUT_$(printf '%s' "$scope_arg" | tr -c '[:alnum:]' '_')"
			if [ -n "${!out_key:-}" ]; then
				echo "${!out_key}"
			else
				echo "${GOVC_STUB_PERMS_OUT:-}"
			fi
			local rc_key="GOVC_STUB_PERMS_RC_$(printf '%s' "$scope_arg" | tr -c '[:alnum:]' '_')"
			if [ -n "${!rc_key:-}" ]; then
				return "${!rc_key}"
			fi
			return "${GOVC_STUB_PERMS_RC:-0}"
			;;
		role.ls)
			# Phase 3 extension: per-role dispatch via
			# GOVC_STUB_ROLE_OUT_<role>; falls back to the flat GOVC_STUB_ROLE_OUT.
			local role_arg="$2"
			local role_out_key="GOVC_STUB_ROLE_OUT_$(printf '%s' "$role_arg" | tr -c '[:alnum:]' '_')"
			if [ -n "${!role_out_key:-}" ]; then
				echo "${!role_out_key}"
			else
				echo "${GOVC_STUB_ROLE_OUT:-}"
			fi
			local role_rc_key="GOVC_STUB_ROLE_RC_$(printf '%s' "$role_arg" | tr -c '[:alnum:]' '_')"
			if [ -n "${!role_rc_key:-}" ]; then
				return "${!role_rc_key}"
			fi
			return "${GOVC_STUB_ROLE_RC:-0}"
			;;
		*)
			return 0
			;;
	esac
}

# openssl stub: honours OPENSSL_STUB_RC (exit code) and OPENSSL_STUB_OUT (stdout/stderr body).
openssl() {
	if [ -n "${OPENSSL_STUB_OUT:-}" ]; then
		echo "$OPENSSL_STUB_OUT"
	fi
	return "${OPENSSL_STUB_RC:-0}"
}

# timeout stub: the production TCP probe runs `timeout 3 bash -c "..."`; the TLS
# probe runs `timeout 5 openssl s_client ...`. In both cases we shift off the
# seconds argument and dispatch based on the first remaining token.
#   - If first remaining token is `bash` AND TCP_STUB_RC is set, short-circuit
#     with that RC (avoids a real `/dev/tcp` network call).
#   - Otherwise, exec the remaining args so our `openssl` / `govc` stubs run.
timeout() {
	shift   # drop the seconds argument (e.g. 3, 5)
	if [ "${1:-}" = "bash" ] && [ -n "${TCP_STUB_RC:-}" ]; then
		return "$TCP_STUB_RC"
	fi
	"$@"
}

# resolve-default-resource-pool shell-function stub (mirrors include_all.sh helper).
# Tests stay self-contained; no sourcing of scripts/include_all.sh.
resolve-default-resource-pool() {
	if [ -n "${GOVC_RESOURCE_POOL:-}" ]; then
		echo "$GOVC_RESOURCE_POOL"
	else
		echo "/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources"
	fi
}

# Global counters (parent owns these in real flow).
_preflight_errors=0
_preflight_warnings=0

# Source the file under test (in THIS process; set -e is active).
source "$SCRIPT"

# Temporary file for output capture (avoids subshell counter loss).
_smoke_out=$(mktemp)
trap 'rm -f "$_smoke_out"' EXIT

# 18. Path A: non-vmw platform -> silent return 0, counter untouched
platform=kvm
_preflight_errors=0
preflight_check_vsphere >"$_smoke_out" 2>&1
_path_a_out=$(cat "$_smoke_out")
if [ -z "$_path_a_out" ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path A: non-vmw platform is silent, no counter mutation"
else
	test_fail "Path A broken: output='$_path_a_out' errors=$_preflight_errors"
fi

# 19. Path B: platform=vmw + all fields missing -> 7 warnings + _preflight_errors=7
platform=vmw
unset GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_DATACENTER GOVC_CLUSTER GOVC_DATASTORE GOVC_NETWORK
_preflight_errors=0
preflight_check_vsphere >"$_smoke_out" 2>&1
_path_b_out=$(cat "$_smoke_out")
err_count=$(grep -c '^ERROR: vSphere: required field' "$_smoke_out" || true)
if [ "$err_count" -eq 7 ] && [ "$_preflight_errors" -eq 7 ]; then
	test_pass "Path B: 7 missing fields produce 7 ERROR lines + _preflight_errors=7"
else
	test_fail "Path B broken: err_count=$err_count errors=$_preflight_errors out='$_path_b_out'"
fi

# 20. Path C: platform=vmw + all fields present -> 1 OK line, _preflight_errors=0, 0 warnings.
# With Phase 2 extensions, Path C now passes through Layer 1-4 (TCP/TLS/auth/resources/
# write-access) using the argument-dispatch stubs above. All stubs are set to
# all-green defaults so the full pipeline produces exactly one OK line and no warnings.
export GOVC_URL=https://vcenter.example.com
export GOVC_USERNAME=admin@vsphere.local
export GOVC_PASSWORD=secret
export GOVC_DATACENTER=GoodDC
export GOVC_CLUSTER=GoodCluster
export GOVC_DATASTORE=GoodDS
export GOVC_NETWORK=GoodNet
export VC_FOLDER=/GoodDC/vm/folder
unset GOVC_INSECURE ISO_DATASTORE GOVC_RESOURCE_POOL
TCP_STUB_RC=0
OPENSSL_STUB_RC=0
OPENSSL_STUB_OUT="Verify return code: 0 (ok)"
GOVC_STUB_ABOUT_RC=0
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nAdmin\t/GoodDC/vm/folder\tadmin@vsphere.local\tYes\n'
GOVC_STUB_PERMS_RC=0
_preflight_errors=0
_preflight_warnings=0
preflight_check_vsphere >"$_smoke_out" 2>&1
_path_c_out=$(cat "$_smoke_out")
ok_count=$(grep -c '^OK: vSphere: configuration fields present' "$_smoke_out" || true)
warn_count=$(grep -cE '^(WARN|ERROR):' "$_smoke_out" || true)
if [ "$ok_count" -eq 1 ] && [ "$_preflight_errors" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
	test_pass "Path C: all fields present produces 1 OK line + no errors + no warnings"
else
	test_fail "Path C broken: ok_count=$ok_count warns_or_errs=$warn_count errors=$_preflight_errors out='$_path_c_out'"
fi

# -------- Phase 2 Layer 1-4 behavioural paths (D through P) ------------------
# Each path configures stubs to reach a specific failure branch, invokes
# preflight_check_vsphere directly (NOT in a subshell - counter mutations
# must propagate), captures output to $_smoke_out, and asserts exact message
# patterns + exact counter deltas.

# Reset test state between paths. Defaults clear Layer 1-4 gates to success;
# callers override only what the path under test needs to break.
_reset_path_state() {
	_preflight_errors=0
	_preflight_warnings=0
	export platform=vmw
	export GOVC_URL=https://vcenter.example.com
	export GOVC_USERNAME=admin@vsphere.local
	export GOVC_PASSWORD=secret
	export GOVC_DATACENTER=GoodDC
	export GOVC_CLUSTER=GoodCluster
	export GOVC_DATASTORE=GoodDS
	export GOVC_NETWORK=GoodNet
	export VC_FOLDER=/GoodDC/vm/folder
	unset GOVC_INSECURE ISO_DATASTORE GOVC_RESOURCE_POOL
	TCP_STUB_RC=0
	OPENSSL_STUB_RC=0
	OPENSSL_STUB_OUT="Verify return code: 0 (ok)"
	GOVC_STUB_ABOUT_RC=0
	GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nAdmin\t/GoodDC/vm/folder\tadmin@vsphere.local\tYes\n'
	GOVC_STUB_PERMS_RC=0
	GOVC_STUB_ROLE_OUT=""
	GOVC_STUB_ROLE_RC=0
	# Phase 3 per-scope "found" flags. Production file defaults them to 0 at file
	# scope; per-path presets in Paths Q-Z flip to 1 before invoking the sequencer.
	_vsphere_dc_found=0
	_vsphere_cluster_found=0
	_vsphere_datastore_found=0
	_vsphere_iso_datastore_found=0
	_vsphere_network_found=0
	_vsphere_folder_found=0
	_vsphere_resource_pool_found=0
	# D-12 counter - reset so it doesn't carry across paths.
	_vsphere_d12_count=0
}

# (TEST-02 scenario: Unreachable vCenter)
# 21. Path D: Layer 1 TCP failure -> 1 "cannot reach" warning + errors=1.
_reset_path_state
TCP_STUB_RC=1
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
warn=$(grep -c '^ERROR: vSphere: cannot reach' "$_smoke_out" || true)
if [ "$warn" -eq 1 ] && [ "$_preflight_errors" -eq 1 ]; then
	test_pass "Path D: TCP failure -> 1 cannot-reach warning + errors=1"
else
	test_fail "Path D broken: warn=$warn errors=$_preflight_errors out='$(cat "$_smoke_out")'"
fi

# (TEST-02 scenario: Untrusted CA)
# 22. Path E: Layer 1 TLS failure (GOVC_INSECURE unset) -> 1 trust-chain warning
# + 2 remediation lines (GOVC_INSECURE=1 hint FIRST, CA-trust-store hint SECOND)
# + errors=1. Production emits a multi-arg aba_warning; our stub joins args with
# space, so the three pieces appear on the same WARN line.
_reset_path_state
OPENSSL_STUB_RC=1
OPENSSL_STUB_OUT="depth=0 verify error:num=18:self-signed certificate"
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
trust_line=$(grep -c '^ERROR: vSphere: TLS trust chain failure talking to' "$_smoke_out" || true)
insecure_hint=$(grep -c 'GOVC_INSECURE=1 in vmware.conf' "$_smoke_out" || true)
ca_hint=$(grep -c 'add the vCenter CA certificate to the system trust store' "$_smoke_out" || true)
if [ "$trust_line" -eq 1 ] && [ "$insecure_hint" -ge 1 ] && [ "$ca_hint" -ge 1 ] && [ "$_preflight_errors" -eq 1 ]; then
	test_pass "Path E: TLS failure -> trust-chain warning + 2 remediation lines + errors=1"
else
	test_fail "Path E broken: trust=$trust_line insecure=$insecure_hint ca=$ca_hint errors=$_preflight_errors"
fi

# 23. Path F: TLS skipped (GOVC_INSECURE=1) -> no TLS call, proceeds to auth;
# errors=0 when downstream layers succeed. OPENSSL_STUB_RC=99 is a canary that
# would fail loudly if openssl WERE called - the whole point is it is not.
_reset_path_state
export GOVC_INSECURE=1
OPENSSL_STUB_RC=99
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
tls_warn=$(grep -c 'TLS trust chain failure' "$_smoke_out" || true)
if [ "$tls_warn" -eq 0 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path F: GOVC_INSECURE=1 skips TLS; no TLS warning; errors=0"
else
	test_fail "Path F broken: tls_warn=$tls_warn errors=$_preflight_errors"
fi

# (TEST-02 scenario: Wrong password)
# 24. Path G: Layer 2 auth failure -> 1 "authentication to" warning + errors=1;
# no Layer 3 probes reached.
_reset_path_state
GOVC_STUB_ABOUT_RC=1
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
auth_line=$(grep -c '^ERROR: vSphere: authentication to' "$_smoke_out" || true)
ds_line=$(grep -c 'datastore' "$_smoke_out" || true)
if [ "$auth_line" -eq 1 ] && [ "$_preflight_errors" -eq 1 ] && [ "$ds_line" -eq 0 ]; then
	test_pass "Path G: auth failure -> 1 auth warning + errors=1 + no Layer 3 probes"
else
	test_fail "Path G broken: auth=$auth_line ds=$ds_line errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing folder / missing datacenter cascade)
# 25. Path H: Layer 3 DC missing -> 1 "datacenter not found" WARNING + 1 cascade
# INFO + errors=1 (not 2: the cascade note must NOT bump the counter).
# Downstream Layer 3 probes (cluster, datastore, network, folder, RP) must be
# skipped entirely.
_reset_path_state
export GOVC_DATACENTER=MissingDC
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
dc_warn=$(grep -c "^ERROR: vSphere: datacenter '/MissingDC' not found" "$_smoke_out" || true)
cascade_info=$(grep -c '^INFO: vSphere: skipping cluster/datastore/network/folder/resource-pool' "$_smoke_out" || true)
cluster_probe=$(grep -c "cluster '/MissingDC" "$_smoke_out" || true)
if [ "$dc_warn" -eq 1 ] && [ "$cascade_info" -eq 1 ] && [ "$_preflight_errors" -eq 1 ] && [ "$cluster_probe" -eq 0 ]; then
	test_pass "Path H: DC missing -> 1 warning + 1 cascade info + errors=1 (no downstream Layer 3 probes)"
else
	test_fail "Path H broken: dc_warn=$dc_warn cascade=$cascade_info cluster_probe=$cluster_probe errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing network)
# 26. Path I: Network exists but is NOT attached to cluster -> 1 attachment
# warning + errors=1. Stub dispatches /GoodDC/network/WrongCluster* to host-99,
# cluster-host query returns host-1 -> no overlap.
_reset_path_state
export GOVC_NETWORK=WrongCluster
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
attach_warn=$(grep -c "is not attached to any host in cluster 'GoodCluster'" "$_smoke_out" || true)
if [ "$attach_warn" -eq 1 ] && [ "$_preflight_errors" -eq 1 ]; then
	test_pass "Path I: network-on-wrong-cluster -> 1 attachment warning + errors=1"
else
	test_fail "Path I broken: attach_warn=$attach_warn errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing datastore)
# 27. Path J: ISO_DATASTORE equals GOVC_DATASTORE -> dedup guard must skip the
# second probe. Set both to Missing; assert exactly 1 "not found" line for the
# datastore path (not 2).
_reset_path_state
export GOVC_DATASTORE=Missing
export ISO_DATASTORE=Missing
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
ds_warn=$(grep -c "^ERROR: vSphere: datastore '/GoodDC/datastore/Missing' not found" "$_smoke_out" || true)
if [ "$ds_warn" -eq 1 ]; then
	test_pass "Path J: ISO_DATASTORE equals GOVC_DATASTORE -> dedup; 1 probe only"
else
	test_fail "Path J broken: ds_warn=$ds_warn out='$(cat "$_smoke_out")'"
fi

# 28. Path K: GOVC_RESOURCE_POOL unset + default exists -> visible OK line
# via aba_info_ok (verbose-on-success convention: users asked to see every
# check pass, not just failures) + errors=0.
_reset_path_state
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
rp_ok=$(grep -c "^OK: vSphere: using default resource pool '/GoodDC/host/GoodCluster/Resources'" "$_smoke_out" || true)
if [ "$rp_ok" -eq 1 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path K: default RP used -> aba_info_ok line + errors=0"
else
	test_fail "Path K broken: rp_ok=$rp_ok errors=$_preflight_errors"
fi

# 29. Path L: GOVC_RESOURCE_POOL unset + default missing -> D-15 wording:
# "default resource pool '...' not found - verify the cluster is properly
# configured". Must NOT hint at setting GOVC_RESOURCE_POOL (would mask the
# real cluster-configuration fault). With GOVC_CLUSTER=MissingCluster the
# RP path /GoodDC/host/MissingCluster/Resources hits the Missing* stub branch.
_reset_path_state
export GOVC_CLUSTER=MissingCluster
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
d15=$(grep -c "default resource pool '.*' not found - verify the cluster is properly configured" "$_smoke_out" || true)
hint=$(grep -c 'set GOVC_RESOURCE_POOL' "$_smoke_out" || true)
if [ "$d15" -eq 1 ] && [ "$hint" -eq 0 ] && [ "$_preflight_errors" -ge 1 ]; then
	test_pass "Path L: default RP missing -> D-15 wording + no 'set GOVC_RESOURCE_POOL' hint"
else
	test_fail "Path L broken: d15=$d15 hint=$hint errors=$_preflight_errors"
fi

# 30. Path M: Admin role across all 7 Phase 3 scopes -> fast-path; 0 warnings,
# 0 error bumps, 0 warning-counter bumps. Mirrors the Phase 2 Path M but now
# exercises the full 7-scope iteration shipped in Plan 03-02.
_reset_path_state
_vsphere_dc_found=1
_vsphere_cluster_found=1
_vsphere_datastore_found=1
_vsphere_network_found=1
_vsphere_folder_found=1
_vsphere_resource_pool_found=1
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nAdmin\t/scope\tadmin@vsphere.local\tYes\n'
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
warn=$(grep -c '^WARN:' "$_smoke_out" || true)
if [ "$warn" -eq 0 ] && [ "$_preflight_errors" -eq 0 ] && [ "$_preflight_warnings" -eq 0 ]; then
	test_pass "Path M: Admin across 7 scopes -> 0 warnings, 0 errors, 0 warning-counter bumps"
else
	test_fail "Path M broken: warn=$warn errors=$_preflight_errors warnings=$_preflight_warnings"
fi

# 31. Path N: No-access role across all 7 Phase 3 scopes -> every priv in every
# scope's VSPHERE_PRIVS_<SCOPE> array is missing. Flat sum of array lengths:
# ROOT(11) + DC(30) + CLUSTER(5) + DS(3) + NET(1) + FOLDER(28) + RP(5) = 83.
# ISO_DATASTORE is unset so no 8th scope.
_reset_path_state
_vsphere_dc_found=1
_vsphere_cluster_found=1
_vsphere_datastore_found=1
_vsphere_network_found=1
_vsphere_folder_found=1
_vsphere_resource_pool_found=1
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nNo access\t/scope\tadmin@vsphere.local\tYes\n'
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
miss=$(grep -c "missing privilege '" "$_smoke_out" || true)
if [ "$miss" -eq 83 ] && [ "$_preflight_errors" -eq 83 ]; then
	test_pass "Path N: No-access across 7 scopes -> 83 missing-priv warnings + errors=83"
else
	test_fail "Path N broken: miss=$miss errors=$_preflight_errors out-tail='$(tail -5 "$_smoke_out")'"
fi

# 32. Path O: permissions.ls fails on all 7 Phase 3 scopes -> D-12 "cannot
# verify write-access" warning per scope + _preflight_warnings bumped per
# scope. _preflight_errors stays 0 (query-level failure is a warning, not an
# error; Phase 3 may still catch genuine gaps on other scopes).
_reset_path_state
_vsphere_dc_found=1
_vsphere_cluster_found=1
_vsphere_datastore_found=1
_vsphere_network_found=1
_vsphere_folder_found=1
_vsphere_resource_pool_found=1
GOVC_STUB_PERMS_RC=1
GOVC_STUB_PERMS_OUT="permission denied: user lacks read right"
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
d12=$(grep -c "^WARN: vSphere: cannot verify write-access on " "$_smoke_out" || true)
if [ "$d12" -eq 7 ] && [ "$_preflight_warnings" -eq 7 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path O: permissions.ls fails all 7 scopes -> 7 D-12 warnings + warnings=7 + errors=0"
else
	test_fail "Path O broken: d12=$d12 warnings=$_preflight_warnings errors=$_preflight_errors"
fi

# 33. Path P: Custom role "VMBuilder" grants exactly VirtualMachine.Inventory.Create.
# Layer 3 sets all 6 non-root found flags to 1 (all Good* objects resolve via the
# argument-dispatch stub), so Layer 4 iterates every scope. VirtualMachine.Inventory.Create
# appears in VSPHERE_PRIVS_DATACENTER and VSPHERE_PRIVS_FOLDER but not in the
# other 5 scopes. Missing counts per scope: ROOT 11, DC 30-1=29, CLUSTER 5,
# DATASTORE 3, NETWORK 1, FOLDER 28-1=27, RP 5. Total 11+29+5+3+1+27+5 = 81.
# The test codifies OBSERVED behaviour (Plan 02-05 "tests document behaviour"
# convention): the one priv VMBuilder grants is never reported as missing on
# DC or FOLDER, and appears missing on every scope that does not include it.
_reset_path_state
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nVMBuilder\t/scope\tadmin@vsphere.local\tYes\n'
GOVC_STUB_ROLE_OUT=$'VirtualMachine.Inventory.Create\n'
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
miss=$(grep -c "missing privilege '" "$_smoke_out" || true)
inv_create=$(grep -c "missing privilege 'VirtualMachine.Inventory.Create'" "$_smoke_out" || true)
dc_missing=$(grep -c "^ERROR: vSphere: datacenter '/GoodDC' missing privilege '" "$_smoke_out" || true)
folder_missing=$(grep -c "^ERROR: vSphere: folder '/GoodDC/vm/folder' missing privilege '" "$_smoke_out" || true)
if [ "$miss" -eq 81 ] && [ "$inv_create" -eq 0 ] && [ "$dc_missing" -eq 29 ] && [ "$folder_missing" -eq 27 ] && [ "$_preflight_errors" -eq 81 ]; then
	test_pass "Path P: VMBuilder with only Inventory.Create -> 81 missing (DC 29 + FOLDER 27 dedupe the one granted priv) + errors=81"
else
	test_fail "Path P broken: miss=$miss inv_create=$inv_create dc_missing=$dc_missing folder_missing=$folder_missing errors=$_preflight_errors"
fi

# -------- Phase 3 Layer 4 behavioural paths (Q through Z) --------------------
# Paths Q-Z exercise the 7-scope privilege sequencer directly via
# _vsphere_probe_privileges (not through the full preflight_check_vsphere).
# This lets each path control the 6 non-root found-flags precisely without
# Layer 3 clobbering them from the argument-dispatch object.collect stub.
# Paths Q-Z pre-source and pre-normalise vmware.conf via _reset_path_state so
# GOVC_* env vars and resolve-default-resource-pool are already in scope.

# (TEST-02 scenario: Missing privilege)
# 34. Path Q: ROOT priv gap (D-09 unconditional). Custom role "RootOnly"
# returns 10 of 11 VSPHERE_PRIVS_ROOT privs; Sessions.ValidateSession is
# missing. All other found flags stay 0 so no other scope check fires (only
# aba_debug skip lines, which the silent stub drops). Expected: exactly 1
# missing-priv warning + errors=1 + D-17 summary '1 privilege gap(s) across
# 1 scope(s)'.
_reset_path_state
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nRootOnly\t/\tadmin@vsphere.local\tYes\n'
GOVC_STUB_ROLE_OUT=$'Cns.Searchable\nInventoryService.Tagging.AttachTag\nInventoryService.Tagging.CreateCategory\nInventoryService.Tagging.CreateTag\nInventoryService.Tagging.DeleteCategory\nInventoryService.Tagging.DeleteTag\nInventoryService.Tagging.EditCategory\nInventoryService.Tagging.EditTag\nStorageProfile.Update\nStorageProfile.View\n'
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
miss=$(grep -c "root '/' missing privilege 'Sessions.ValidateSession'" "$_smoke_out" || true)
summary=$(grep -c "vSphere: 1 privilege gap(s) across 1 scope(s)" "$_smoke_out" || true)
if [ "$miss" -eq 1 ] && [ "$summary" -eq 1 ] && [ "$_preflight_errors" -eq 1 ]; then
	test_pass "Path Q: ROOT priv gap -> 1 missing + errors=1 + D-17 summary '1 across 1'"
else
	test_fail "Path Q broken: miss=$miss summary=$summary errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 35. Path R: multi-scope gaps - Admin at ROOT, No-access at DATACENTER. Uses
# per-scope permissions.ls dispatch (GOVC_STUB_PERMS_OUT_<path-key>). Only
# ROOT + DATACENTER scope checks fire (DC flag on; other 5 non-root flags
# stay off and emit silent aba_debug skip lines). Expected: 0 ROOT missings
# (Admin fast-path) + 30 DC missings (full VSPHERE_PRIVS_DATACENTER array) +
# D-17 summary '30 privilege gap(s) across 1 scope(s)'.
_reset_path_state
_vsphere_dc_found=1
export GOVC_STUB_PERMS_OUT__=$'Role\tEntity\tPrincipal\tPropagate\nAdmin\t/\tadmin@vsphere.local\tYes\n'
export GOVC_STUB_PERMS_OUT__GoodDC=$'Role\tEntity\tPrincipal\tPropagate\nNo access\t/GoodDC\tadmin@vsphere.local\tYes\n'
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
dc_miss=$(grep -c "datacenter '/GoodDC' missing privilege '" "$_smoke_out" || true)
root_miss=$(grep -c "root '/' missing privilege '" "$_smoke_out" || true)
summary=$(grep -c "vSphere: 30 privilege gap(s) across 1 scope(s)" "$_smoke_out" || true)
unset GOVC_STUB_PERMS_OUT__ GOVC_STUB_PERMS_OUT__GoodDC
if [ "$dc_miss" -eq 30 ] && [ "$root_miss" -eq 0 ] && [ "$summary" -eq 1 ] && [ "$_preflight_errors" -eq 30 ]; then
	test_pass "Path R: Admin@ROOT + No-access@DC -> 30 DC-only missings + D-17 '30 across 1'"
else
	test_fail "Path R broken: dc_miss=$dc_miss root_miss=$root_miss summary=$summary errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 36. Path S: missing-object skip emits aba_debug, NOT aba_warning (D-06
# no-conflation decision: do not confuse "privilege not granted" with
# "object not found"). All 6 non-root found flags stay 0. Temporarily
# override aba_debug to observe the skip line. Expected: exactly 1
# 'skipping privilege check for missing datacenter' DEBUG line + 0
# aba_warning for DATACENTER privileges + counters unchanged for DC scope.
_reset_path_state
aba_debug() { echo "DEBUG: $*"; }
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nAdmin\t/\tadmin@vsphere.local\tYes\n'
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
skip_dc=$(grep -c "^DEBUG: vSphere: skipping privilege check for missing datacenter" "$_smoke_out" || true)
warn_dc=$(grep -c "datacenter '/GoodDC' missing privilege" "$_smoke_out" || true)
if [ "$skip_dc" -eq 1 ] && [ "$warn_dc" -eq 0 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path S: DC found=0 -> aba_debug skip (NOT aba_warning) + errors=0"
else
	test_fail "Path S broken: skip_dc=$skip_dc warn_dc=$warn_dc errors=$_preflight_errors"
fi
aba_debug() { :; }    # restore silent stub before Path T

# (TEST-02 scenario: Missing privilege)
# 37. Path T: ISO_DATASTORE dedup when ISO_DATASTORE == GOVC_DATASTORE. Both
# DS flags set. Force permissions.ls failure globally (GOVC_STUB_PERMS_RC=1).
# Expected: exactly 1 D-12 'cannot verify write-access' warning for the
# primary DS path; NO second D-12 for the ISO path (D-11 dedup guard
# suppressed the repeat probe, carried forward from Phase 2 Pitfall 5).
_reset_path_state
_vsphere_datastore_found=1
_vsphere_iso_datastore_found=1
export ISO_DATASTORE=GoodDS
GOVC_STUB_PERMS_RC=1
GOVC_STUB_PERMS_OUT="permission denied"
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
ds_d12=$(grep -c "cannot verify write-access on '/GoodDC/datastore/GoodDS'" "$_smoke_out" || true)
unset ISO_DATASTORE
if [ "$ds_d12" -eq 1 ]; then
	test_pass "Path T: ISO_DATASTORE == GOVC_DATASTORE -> dedup; single DS D-12 warning"
else
	test_fail "Path T broken: ds_d12=$ds_d12"
fi

# (TEST-02 scenario: Missing privilege)
# 38. Path U: Admin 7-scope fast-path -> D-17 summary suppressed (D-14
# quiet-on-success). Asserts the summary headline ('privilege gap(s) across')
# does NOT appear in output.
_reset_path_state
_vsphere_dc_found=1
_vsphere_cluster_found=1
_vsphere_datastore_found=1
_vsphere_network_found=1
_vsphere_folder_found=1
_vsphere_resource_pool_found=1
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nAdmin\t/scope\tadmin@vsphere.local\tYes\n'
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
summary=$(grep -c 'privilege gap(s) across' "$_smoke_out" || true)
warn=$(grep -c '^WARN:' "$_smoke_out" || true)
if [ "$summary" -eq 0 ] && [ "$warn" -eq 0 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path U: Admin 7-scope -> D-17 summary suppressed (quiet-on-success)"
else
	test_fail "Path U broken: summary=$summary warn=$warn errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 39. Path V: role.ls failure on FOLDER scope -> 1 'cannot resolve' warning
# + _preflight_warnings bumped + _preflight_errors=0 on that scope (D-12
# semantics: query-level failure is a warning, not an error).
_reset_path_state
_vsphere_folder_found=1
export GOVC_STUB_PERMS_OUT__GoodDC_vm_folder=$'Role\tEntity\tPrincipal\tPropagate\nCustomRole\t/GoodDC/vm/folder\tadmin@vsphere.local\tYes\n'
export GOVC_STUB_ROLE_OUT="dummy-priv-list"
export GOVC_STUB_ROLE_RC_CustomRole=1
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
cannot=$(grep -c "cannot resolve privileges for role 'CustomRole' on '/GoodDC/vm/folder'" "$_smoke_out" || true)
unset GOVC_STUB_PERMS_OUT__GoodDC_vm_folder GOVC_STUB_ROLE_RC_CustomRole
if [ "$cannot" -eq 1 ] && [ "$_preflight_warnings" -ge 1 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path V: role.ls fails on folder -> 1 'cannot resolve' warning + warnings>=1 + errors=0"
else
	test_fail "Path V broken: cannot=$cannot warnings=$_preflight_warnings errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 40. Path W: D-17 summary silence on clean pass with a custom role that grants
# every required priv. FOLDER scope active + ROOT (unconditional). role.ls
# returns the union of VSPHERE_PRIVS_ROOT + VSPHERE_PRIVS_FOLDER (sourced by
# awk from scripts/vmware-required-privileges.sh). Expected: 0 missing-priv
# warnings + no D-17 summary headline.
_reset_path_state
_vsphere_folder_found=1
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nGranted\t/scope\tadmin@vsphere.local\tYes\n'
GOVC_STUB_ROLE_OUT="$(awk '/^VSPHERE_PRIVS_(ROOT|FOLDER)=\(/{take=1;next} take && /^\)/{take=0;next} take {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' scripts/vmware-required-privileges.sh)"
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
miss=$(grep -c "missing privilege '" "$_smoke_out" || true)
summary=$(grep -c 'privilege gap(s) across' "$_smoke_out" || true)
if [ "$miss" -eq 0 ] && [ "$summary" -eq 0 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path W: custom role with all privs -> 0 missings + no D-17 summary"
else
	test_fail "Path W broken: miss=$miss summary=$summary errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 41. Path X: D-17 summary appearance on exactly one gap. NearlyComplete role
# has all 28 FOLDER + 11 ROOT privs EXCEPT VirtualMachine.Provisioning.Clone.
# Expected: exactly 1 missing-priv warning + D-17 headline + next-step line +
# grant-and-rerun line + errors=1 (D-18: summary must NOT double-count).
_reset_path_state
_vsphere_folder_found=1
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nNearlyComplete\t/scope\tadmin@vsphere.local\tYes\n'
GOVC_STUB_ROLE_OUT="$(awk '/^VSPHERE_PRIVS_(ROOT|FOLDER)=\(/{take=1;next} take && /^\)/{take=0;next} take {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' scripts/vmware-required-privileges.sh | grep -vxF 'VirtualMachine.Provisioning.Clone')"
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
miss=$(grep -c "missing privilege 'VirtualMachine.Provisioning.Clone'" "$_smoke_out" || true)
total_miss=$(grep -c "missing privilege '" "$_smoke_out" || true)
summary=$(grep -c 'vSphere: 1 privilege gap(s) across 1 scope(s)' "$_smoke_out" || true)
next_step=$(grep -c 'Next: review the curated list at scripts/vmware-required-privileges.sh' "$_smoke_out" || true)
grant=$(grep -c 'Grant the missing privileges to the vCenter user or role and re-run aba install' "$_smoke_out" || true)
if [ "$miss" -eq 1 ] && [ "$total_miss" -eq 1 ] && [ "$summary" -eq 1 ] && [ "$next_step" -eq 1 ] && [ "$grant" -eq 1 ] && [ "$_preflight_errors" -eq 1 ]; then
	test_pass "Path X: one gap -> 1 per-gap warning + D-17 summary + errors=1 (D-18 no double-count)"
else
	test_fail "Path X broken: miss=$miss total=$total_miss summary=$summary next=$next_step grant=$grant errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 42. Path Y: ISO_DATASTORE present + different + both found. Both DS scopes
# iterate the same VSPHERE_PRIVS_DATASTORE (3 privs). No-access on every scope
# the stub serves - so ROOT also fires (11 missings) since D-09 makes ROOT
# unconditional. Observed: 11 ROOT + 3 primary DS + 3 ISO DS = 17 missings +
# D-17 summary '17 privilege gap(s) across 3 scope(s)'. Test codifies observed
# behaviour (Plan 02-05 "tests document behaviour" convention).
_reset_path_state
_vsphere_datastore_found=1
_vsphere_iso_datastore_found=1
export ISO_DATASTORE=IsoDS
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nNo access\t/scope\tadmin@vsphere.local\tYes\n'
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
primary=$(grep -c "datastore '/GoodDC/datastore/GoodDS' missing privilege" "$_smoke_out" || true)
iso=$(grep -c "datastore '/GoodDC/datastore/IsoDS' missing privilege" "$_smoke_out" || true)
root_miss=$(grep -c "root '/' missing privilege" "$_smoke_out" || true)
summary=$(grep -c 'vSphere: 17 privilege gap(s) across 3 scope(s)' "$_smoke_out" || true)
unset ISO_DATASTORE
if [ "$primary" -eq 3 ] && [ "$iso" -eq 3 ] && [ "$root_miss" -eq 11 ] && [ "$summary" -eq 1 ] && [ "$_preflight_errors" -eq 17 ]; then
	test_pass "Path Y: ISO!=GOVC both found + ROOT No-access -> 11+3+3 missings + D-17 '17 across 3'"
else
	test_fail "Path Y broken: primary=$primary iso=$iso root_miss=$root_miss summary=$summary errors=$_preflight_errors"
fi

# (TEST-02 scenario: Missing privilege)
# 43. Path Z: D-18 explicit no-double-count. Reuses Path X's one-gap shape;
# captures _preflight_errors BEFORE and AFTER the call; asserts the delta
# equals the per-gap warning count (i.e. the D-17 summary did NOT bump
# _preflight_errors an extra time).
_reset_path_state
_vsphere_folder_found=1
GOVC_STUB_PERMS_OUT=$'Role\tEntity\tPrincipal\tPropagate\nNearlyComplete\t/scope\tadmin@vsphere.local\tYes\n'
GOVC_STUB_ROLE_OUT="$(awk '/^VSPHERE_PRIVS_(ROOT|FOLDER)=\(/{take=1;next} take && /^\)/{take=0;next} take {gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' scripts/vmware-required-privileges.sh | grep -vxF 'VirtualMachine.Provisioning.Clone')"
err_before=$_preflight_errors
_vsphere_probe_privileges >"$_smoke_out" 2>&1 || true
err_after=$_preflight_errors
delta=$(( err_after - err_before ))
gap_warns=$(grep -c "missing privilege '" "$_smoke_out" || true)
if [ "$delta" -eq "$gap_warns" ] && [ "$delta" -eq 1 ]; then
	test_pass "Path Z: D-18 summary does not double-count - delta=$delta matches gap_warns=$gap_warns"
else
	test_fail "Path Z broken: delta=$delta gap_warns=$gap_warns"
fi

# (TEST-02 scenario: Missing folder)
# 44. Path AA: VC_FOLDER points at a folder that does not exist on an otherwise
# healthy DC -> 1 "folder ... not found" warning + errors=1. Proves the missing-
# folder scenario is detectable independent of the DC-cascade (Path H).
_reset_path_state
export VC_FOLDER=/MissingFolder
err_before=$_preflight_errors
preflight_check_vsphere >"$_smoke_out" 2>&1 || true
err_after=$_preflight_errors
delta=$(( err_after - err_before ))
folder_warn=$(grep -cE "^WARN: vSphere: .*folder.*not found|folder '/MissingFolder' not found" "$_smoke_out" || true)
if [ "$folder_warn" -ge 1 ] && [ "$delta" -eq 1 ]; then
	test_pass "Path AA: missing folder -> 'folder ... not found' warning + errors delta=1"
else
	test_fail "Path AA broken: folder_warn=$folder_warn delta=$delta out='$(cat "$_smoke_out")'"
fi
# Restore VC_FOLDER to the default known-good value for any subsequent Paths.
export VC_FOLDER=/GoodDC/vm/folder

echo
echo -e "${GREEN}=== All Tests Passed ===${NC}"
echo
