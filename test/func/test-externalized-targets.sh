#!/bin/bash
# Test: Verify Phase 1 externalized targets dispatch correctly
# Validates guard checks, dispatch routing, script existence, and HV readiness.
# No running cluster or network access required.

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; ((pass++)); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; ((fail++)); FAILURES=1; }

echo
echo "=== Testing: Phase 1 Externalized Targets ==="
echo

# All 19 externalized targets
ALL_TARGETS="info login shell getco day2 day2-ntp day2-osus shutdown startup rescue create ls start stop kill poweroff delete refresh upload"

# ─────────────────────────────────────────────────────────────────────────────
# Group 1: Cluster directory guard (static + runtime)
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Group 1: Cluster directory guard ---"

# 1a. Static: Verify all 19 targets appear in the guard case block.
# The guard has the target list on a line preceding the cluster.conf check.
guard_block=$(awk '/case \$cur_target in/{found=1} found && /cluster\.conf/{print prev; print; found=0} {prev=$0}' scripts/aba.sh)
missing_guard=""
for t in $ALL_TARGETS; do
	if ! echo "$guard_block" | grep -qw "$t"; then
		missing_guard="$missing_guard $t"
	fi
done
if [ -z "$missing_guard" ]; then
	test_pass "Guard case covers all 19 targets"
else
	test_fail "Guard case missing targets:$missing_guard"
fi

# 1b. Static: Verify all 19 targets appear in the dispatch bypass list.
# The bypass comment is on the line after the target list.
bypass_block=$(grep -B1 'bypassing Make' scripts/aba.sh)
missing_bypass=""
for t in $ALL_TARGETS; do
	if ! echo "$bypass_block" | grep -qw "$t"; then
		missing_bypass="$missing_bypass $t"
	fi
done
if [ -z "$missing_bypass" ]; then
	test_pass "Dispatch bypass covers all 19 targets"
else
	test_fail "Dispatch bypass missing targets:$missing_bypass"
fi

# 1c. Runtime: Test representative targets from repo root (no cluster.conf here).
for target in info day2 create ls; do
	out=$(aba "$target" 2>&1 || true)
	if echo "$out" | grep -q "Not in a cluster directory"; then
		test_pass "Guard rejects 'aba $target' from repo root"
	else
		test_fail "Guard did NOT reject 'aba $target' from repo root. Output: $(echo "$out" | tail -3)"
	fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Group 2: Safe dispatch from cluster dir
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Group 2: Dispatch from cluster dir (sno/) ---"

# 2a. 'aba shell' outputs the KUBECONFIG export
out=$(aba --dir sno shell 2>&1 || true)
if echo "$out" | grep -q "export KUBECONFIG=.*iso-agent-based/auth/kubeconfig"; then
	test_pass "'aba --dir sno shell' outputs KUBECONFIG path"
else
	test_fail "'aba --dir sno shell' unexpected output: $(echo "$out" | tail -3)"
fi

# 2b. 'aba info' from sno/ should NOT say "Not in a cluster directory"
out=$(aba --dir sno info 2>&1 || true)
if echo "$out" | grep -q "Not in a cluster directory"; then
	test_fail "'aba --dir sno info' wrongly rejected as not in cluster dir"
else
	test_pass "'aba --dir sno info' dispatched correctly (no guard rejection)"
fi

# 2c. 'aba ls' from sno/ should reach vmw-ls.sh (may fail at govc, but should
#     NOT fail with guard or dispatch errors)
out=$(aba --dir sno ls 2>&1 || true)
if echo "$out" | grep -q "Not in a cluster directory"; then
	test_fail "'aba --dir sno ls' wrongly rejected as not in cluster dir"
elif echo "$out" | grep -q "vmware.conf not found"; then
	test_fail "'aba --dir sno ls' can't find vmware.conf (dispatch error)"
elif echo "$out" | grep -q "agent-config.yaml not found"; then
	test_fail "'aba --dir sno ls' can't find agent-config.yaml (dispatch error)"
else
	test_pass "'aba --dir sno ls' dispatched to vmw-ls.sh (no guard/dispatch errors)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Group 3: Script existence
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Group 3: Script existence ---"

REQUIRED_SCRIPTS="
scripts/cluster-info.sh
scripts/show-cluster-login.sh
scripts/day2.sh
scripts/day2-config-ntp.sh
scripts/day2-config-osus.sh
scripts/cluster-graceful-shutdown.sh
scripts/cluster-startup.sh
scripts/cluster-rescue.sh
scripts/vmw-exists.sh
scripts/vmw-create.sh
scripts/vmw-ls.sh
scripts/vmw-start.sh
scripts/vmw-stop.sh
scripts/vmw-kill.sh
scripts/vmw-delete.sh
scripts/vmw-refresh.sh
scripts/vmw-upload.sh
"

for script in $REQUIRED_SCRIPTS; do
	if [ -f "$script" ] && [ -x "$script" ]; then
		test_pass "Exists and executable: $script"
	elif [ -f "$script" ]; then
		test_fail "Exists but NOT executable: $script"
	else
		test_fail "MISSING: $script"
	fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Group 4: _ensure_hv_ready validation
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Group 4: _ensure_hv_ready validation ---"

# 4a. From sno/ (platform=vmw, vmware.conf present): no platform error
out=$(aba --dir sno ls 2>&1 || true)
if echo "$out" | grep -q "Unknown platform"; then
	test_fail "_ensure_hv_ready rejects platform=vmw in sno/"
else
	test_pass "_ensure_hv_ready accepts platform=vmw in sno/"
fi

# 4b. From a temp dir with cluster.conf but no vmware.conf: should fail
TMPDIR_TEST=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

cp sno/cluster.conf "$TMPDIR_TEST/"
cp sno/agent-config.yaml "$TMPDIR_TEST/"
ln -sf "$(pwd)/aba.conf" "$TMPDIR_TEST/aba.conf"
ln -sf "$(pwd)/scripts" "$TMPDIR_TEST/scripts"
ln -sf "$(pwd)/templates" "$TMPDIR_TEST/templates"
ln -sf "$(pwd)/cli" "$TMPDIR_TEST/cli"
ln -sf "$(pwd)/Makefile" "$TMPDIR_TEST/Makefile"

out=$(aba --dir "$TMPDIR_TEST" ls 2>&1 || true)
if echo "$out" | grep -q "vmware.conf not found"; then
	test_pass "_ensure_hv_ready rejects missing vmware.conf"
else
	test_fail "_ensure_hv_ready did NOT reject missing vmware.conf. Output: $(echo "$out" | tail -3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="

if [ "$FAILURES" ]; then
	echo -e "${RED}SOME TESTS FAILED${NC}"
	exit 1
fi

echo -e "${GREEN}=== All Tests Passed ===${NC}"
echo
