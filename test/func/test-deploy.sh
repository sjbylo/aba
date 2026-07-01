#!/bin/bash
# Unit tests for the 'aba deploy' orchestrator (scripts/deploy.sh).
#
# deploy_run() runs the air-gapped install as an ordered, idempotent, resumable
# pipeline: config import -> mirror install -> mirror load -> iso -> (boot) ->
# monitor -> day2. Steps are wrapped in run_once -S so a re-run skips completed
# steps (resume). ABA_DEPLOY_DRY_RUN=1 prints the plan and executes nothing.
#
# No real cluster/registry: 'make' is stubbed via a PATH shim and the aba
# sub-scripts are stubbed under a temp ABA_ROOT; run_once state is isolated via
# RUN_ONCE_DIR.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

source scripts/include_all.sh dummy_arg 2>/dev/null
export INFO_ABA=1   # deploy_run uses aba_info (gated on INFO_ABA); enable it for plan capture

if [ ! -f scripts/deploy.sh ]; then
	echo "FATAL: scripts/deploy.sh does not exist yet (red)" >&2
	echo "=== Results: 0 passed, 1 failed ==="
	exit 1
fi
eval "$(sed -n '/^deploy_run() {/,/^}/p' scripts/deploy.sh)"
if ! type deploy_run >/dev/null 2>&1; then
	echo "FATAL: could not extract deploy_run() from scripts/deploy.sh" >&2
	exit 1
fi

# --- fake ABA_ROOT with stub sub-scripts + PATH-stubbed make ------------------
_root="$_tmp/aba"
mkdir -p "$_root/scripts" "$_root/mirror" "$_root/mycluster" "$_tmp/bin" "$_tmp/runner"
: > "$_root/mycluster/cluster.conf"
export ABA_ROOT="$_root"
export RUN_ONCE_DIR="$_tmp/runner"
export DEPLOY_LOG="$_tmp/order.log"

cat > "$_root/scripts/config-import.sh" <<'EOF'
#!/bin/bash
echo "config-import $*" >> "$DEPLOY_LOG"
EOF
cat > "$_root/scripts/day2.sh" <<'EOF'
#!/bin/bash
echo "day2 $*" >> "$DEPLOY_LOG"
EOF
chmod +x "$_root/scripts/config-import.sh" "$_root/scripts/day2.sh"

cat > "$_tmp/bin/make" <<'EOF'
#!/bin/bash
echo "make $*" >> "$DEPLOY_LOG"
if [ -n "$MAKE_FAIL_ON" ]; then
	case "$*" in *"$MAKE_FAIL_ON"*) exit 1 ;; esac
fi
exit 0
EOF
chmod +x "$_tmp/bin/make"
export PATH="$_tmp/bin:$PATH"

_reset_state() { : > "$DEPLOY_LOG"; rm -rf "$RUN_ONCE_DIR"; mkdir -p "$RUN_ONCE_DIR"; rm -f "$_root/mycluster/.aba-deploy-await-boot"; }
_line() { grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }        # first line matching $2 in file $1
_before() {			# name  file  patA  patB
	local la lb; la="$(_line "$2" "$3")"; lb="$(_line "$2" "$4")"
	if [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; then test_pass "$1"; else test_fail "$1" "$3(=$la) not before $4(=$lb)"; fi
}
_has() { if grep -q "$3" "$2"; then test_pass "$1"; else test_fail "$1" "missing: $3"; fi; }
_hasnot() { if grep -q "$3" "$2"; then test_fail "$1" "unexpected: $3"; else test_pass "$1"; fi; }

echo
echo "=== Testing: aba deploy orchestrator ==="
echo

# --- Test 1: DRY RUN prints the full ordered plan and executes nothing --------
echo "--- dry-run plan (bare-metal) ---"
_reset_state
_plan="$_tmp/plan-bm.txt"
( ABA_DEPLOY_DRY_RUN=1 deploy_run "$_root" "site" "mycluster" "bm" ) > "$_plan" 2>&1
_before "plan: config-import before mirror-install" "$_plan" 'config-import' 'mirror-install'
_before "plan: mirror-install before mirror-load"   "$_plan" 'mirror-install' 'mirror-load'
_before "plan: mirror-load before iso"              "$_plan" 'mirror-load' 'iso'
_before "plan: iso before monitor"                  "$_plan" '\[iso\]' 'monitor'
_before "plan: monitor before day2"                 "$_plan" 'monitor' 'day2'
_has    "plan: bare-metal boot pause noted"         "$_plan" 'boot'
if [ ! -s "$DEPLOY_LOG" ]; then test_pass "dry-run executes nothing (no make/sub-scripts)"; else test_fail "dry-run side effects" "$(tr '\n' '|' <"$DEPLOY_LOG")"; fi
if [ ! -d "$RUN_ONCE_DIR" ] || [ -z "$(ls -A "$RUN_ONCE_DIR" 2>/dev/null)" ]; then test_pass "dry-run creates no run_once state"; else test_fail "dry-run run_once state" "state created"; fi

# --- Test 2: hypervisor plan uses 'make install' (auto VM boot), no pause -----
echo "--- dry-run plan (hypervisor) ---"
_reset_state
_planv="$_tmp/plan-vmw.txt"
( ABA_DEPLOY_DRY_RUN=1 deploy_run "$_root" "site" "mycluster" "vmw" ) > "$_planv" 2>&1
_has "vmw plan: uses 'make ... install' for bring-up" "$_planv" 'install'
_before "vmw plan: iso before install" "$_planv" '\[iso\]' '\[install\]'
_before "vmw plan: install before day2" "$_planv" '\[install\]' 'day2'

# --- Test 3: real execution order (hypervisor, straight through) --------------
echo "--- execution order (vmw) ---"
_reset_state
( deploy_run "$_root" "site" "mycluster" "vmw" ) >/dev/null 2>&1
_before "exec: config-import first"        "$DEPLOY_LOG" 'config-import' 'mirror install'
_before "exec: mirror install before load" "$DEPLOY_LOG" 'mirror install' 'mirror load'
_before "exec: mirror load before iso"     "$DEPLOY_LOG" 'mirror load' 'mycluster iso'
_before "exec: iso before cluster install" "$DEPLOY_LOG" 'mycluster iso' 'mycluster install'
_before "exec: cluster install before day2" "$DEPLOY_LOG" 'mycluster install' 'day2'

# --- Test 4: resume - re-run skips completed steps (run_once -S) --------------
echo "--- resume (idempotent) ---"
_reset_state
( deploy_run "$_root" "site" "mycluster" "vmw" ) >/dev/null 2>&1
_n1=$(wc -l < "$DEPLOY_LOG")
( deploy_run "$_root" "site" "mycluster" "vmw" ) >/dev/null 2>&1
_n2=$(wc -l < "$DEPLOY_LOG")
if [ "$_n1" -gt 0 ] && [ "$_n2" -eq "$_n1" ]; then
	test_pass "re-run skips completed steps (no re-execution): $_n1 == $_n2"
else
	test_fail "resume" "expected no growth; first=$_n1 second=$_n2"
fi

# --- Test 5: a failed step halts the pipeline ---------------------------------
echo "--- failure stops pipeline ---"
_reset_state
( MAKE_FAIL_ON="mirror load" deploy_run "$_root" "site" "mycluster" "vmw" ) >/dev/null 2>&1
_drc=$?
_has    "failure: reached mirror load"        "$DEPLOY_LOG" 'mirror load'
_hasnot "failure: iso NOT run after failure"  "$DEPLOY_LOG" 'mycluster iso'
_hasnot "failure: day2 NOT run after failure" "$DEPLOY_LOG" 'day2'
[ "$_drc" -ne 0 ] && test_pass "deploy_run returns non-zero on step failure" || test_fail "failure rc" "expected non-zero"

# --- Test 6: bare-metal pause then resume -------------------------------------
echo "--- bare-metal pause/resume ---"
_reset_state
( deploy_run "$_root" "site" "mycluster" "bm" ) >/dev/null 2>&1
_has    "bm run 1: iso generated"                 "$DEPLOY_LOG" 'mycluster iso'
_hasnot "bm run 1: pauses before monitor"         "$DEPLOY_LOG" 'mycluster mon'
_hasnot "bm run 1: pauses before day2"            "$DEPLOY_LOG" 'day2'
[ -f "$_root/mycluster/.aba-deploy-await-boot" ] && test_pass "bm run 1: await-boot marker created" || test_fail "bm marker" "no marker"
( deploy_run "$_root" "site" "mycluster" "bm" ) >/dev/null 2>&1
_has "bm run 2: resumes into monitor" "$DEPLOY_LOG" 'mycluster mon'
_has "bm run 2: runs day2 after monitor" "$DEPLOY_LOG" 'day2'

# --- Test 6b: a fixed step retries on re-run (not stuck on cached failure) -----
echo "--- fix-and-resume (retry a failed step) ---"
_reset_state
( MAKE_FAIL_ON="mirror load" deploy_run "$_root" "site" "mycluster" "vmw" ) >/dev/null 2>&1
_hasnot "fix-resume run 1: iso not reached (load failed)" "$DEPLOY_LOG" 'mycluster iso'
( deploy_run "$_root" "site" "mycluster" "vmw" ) >/dev/null 2>&1
_has "fix-resume run 2: previously-failed load retried, iso reached" "$DEPLOY_LOG" 'mycluster iso'
_has "fix-resume run 2: pipeline completes through day2"             "$DEPLOY_LOG" 'day2'

# --- Test 7: CLI dispatch wiring ----------------------------------------------
echo "--- dispatch wiring ---"
grep -q '|deploy|' "$REPO_ROOT/scripts/aba.sh" && test_pass "'deploy' in direct-dispatch allow-list" || test_fail "allow-list" "deploy missing"
grep -qE '^[[:space:]]*deploy\)' "$REPO_ROOT/scripts/aba.sh" && test_pass "aba.sh has a 'deploy)' arm" || test_fail "arm" "no deploy) arm"
grep -q 'scripts/deploy.sh' "$REPO_ROOT/scripts/aba.sh" && test_pass "deploy) arm invokes deploy.sh" || test_fail "arm target" "no deploy.sh call"
grep -q 'aba deploy' "$REPO_ROOT/others/help-aba.txt" && test_pass "help-aba.txt documents 'aba deploy'" || test_fail "help" "not documented"

echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
