#!/bin/bash
# Test: Verify scripts/preflight-check-vsphere.sh structure, coding standards, and runtime behaviour.
# Unit test (fast, static assertions + in-process behavioural smoke; no network).

set -e

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
aba_info()      { echo "INFO: $*"; }
aba_info_ok()   { echo "OK: $*"; }
aba_warning()   { echo "WARN: $*"; }
aba_abort()     { echo "ABORT: $*"; return 0; }
aba_debug()     { :; }
# Stub normalize-vmware-conf: the function is invoked as a command inside source <(...)
# The process substitution runs normalize-vmware-conf and sources its stdout as shell code.
# Outputting nothing from the stub produces a source of an empty stream (no-op).
normalize-vmware-conf() { :; }
# Stub govc: 'command -v govc' succeeds when a shell function named govc exists.
# This avoids a PATH-based govc install requirement in the test environment.
govc() { :; }
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
warn_count=$(grep -c '^WARN: vSphere: required field' "$_smoke_out" || true)
if [ "$warn_count" -eq 7 ] && [ "$_preflight_errors" -eq 7 ]; then
	test_pass "Path B: 7 missing fields produce 7 warnings + _preflight_errors=7"
else
	test_fail "Path B broken: warn_count=$warn_count errors=$_preflight_errors out='$_path_b_out'"
fi

# 20. Path C: platform=vmw + all fields present -> 1 OK line, _preflight_errors=0
# Stub the Phase 2 Layer 1/2 probes so Path C exercises ONLY the field-presence
# gate + the OK line, without reaching the network. Phase 2 Plan 02-05 adds
# dedicated behavioural paths (D-P) that exercise the probes with fixtures.
_vsphere_probe_tcp()  { :; }
_vsphere_probe_tls()  { :; }
_vsphere_probe_auth() { :; }
export GOVC_URL=x GOVC_USERNAME=x GOVC_PASSWORD=x GOVC_DATACENTER=x GOVC_CLUSTER=x GOVC_DATASTORE=x GOVC_NETWORK=x
_preflight_errors=0
preflight_check_vsphere >"$_smoke_out" 2>&1
_path_c_out=$(cat "$_smoke_out")
ok_count=$(grep -c '^OK: vSphere: configuration fields present' "$_smoke_out" || true)
if [ "$ok_count" -eq 1 ] && [ "$_preflight_errors" -eq 0 ]; then
	test_pass "Path C: all fields present produces 1 OK line + no errors"
else
	test_fail "Path C broken: ok_count=$ok_count errors=$_preflight_errors out='$_path_c_out'"
fi

echo
echo -e "${GREEN}=== All Tests Passed ===${NC}"
echo
