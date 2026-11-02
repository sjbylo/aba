#!/bin/bash
# Test: install guard detects VMs deleted outside ABA
# Regression test for: UX dead-end loop when .install-complete exists but VMs are gone.
#
# When a cluster is installed via VMs (vmw/kvm) and the VMs are later deleted
# outside ABA, the .install-complete marker becomes stale. The install guard
# must detect this and suggest 'clean' instead of the misleading 'already
# installed' / 'shut down' messages.
#
# Also verifies that 'make clean' removes externalized state via the
# clusterstate symlink.

set -euo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

echo "=== Install guard: stale VM markers ==="

# --- Setup: create a fake cluster directory with stale state ---
_cluster_dir="$_tmp/testcl"
mkdir -p "$_cluster_dir"

# Minimal cluster.conf
cat > "$_cluster_dir/cluster.conf" <<-EOF
cluster_name=testcl
base_domain=example.com
num_masters=1
num_workers=0
machine_network=10.0.1.0/24
starting_ip=10.0.1.200
EOF

# Simulate an installed cluster: marker + shutdown log
touch "$_cluster_dir/.install-complete"
touch "$_cluster_dir/.shutdown.log"

# Fake externalized state
_ext_state="$_tmp/ext-state/testcl.example.com"
mkdir -p "$_ext_state"
echo "cluster_name=testcl" > "$_ext_state/state.sh"
echo "base_domain=example.com" >> "$_ext_state/state.sh"
touch "$_ext_state/kubeconfig"

# clusterstate symlink (as created by externalize_cluster_state)
ln -sfn "$_ext_state" "$_cluster_dir/clusterstate"

# --- Test 1: Makefile clean removes externalized state via clusterstate symlink ---
echo ""
echo "--- Test 1: make clean removes externalized state ---"

# Create a minimal Makefile with the clean target (printf preserves recipe tabs)
{
	printf '.PHONY: clean\n'
	printf 'clean:\n'
	printf '\trm -f install-config.yaml agent-config.yaml\n'
	printf '\trm -rf iso-agent-based*\n'
	printf '\trm -f .??*\n'
	printf '\trm -f mirror mirror.conf\n'
	printf '\t@[ -L regcreds ] && rm regcreds || true\n'
	printf '\t@if [ -L clusterstate ]; then rm -rf "$$(readlink clusterstate)"; rm -f clusterstate; fi\n'
	printf '\trm -f openshift-install-*-*\n'
} > "$_cluster_dir/Makefile"

# Pre-check: externalized state exists
if [ -d "$_ext_state" ] && [ -f "$_ext_state/state.sh" ]; then
	_pass "Pre-check: externalized state exists before clean"
else
	_fail "Pre-check: externalized state exists before clean"
fi

# Pre-check: clusterstate symlink exists
if [ -L "$_cluster_dir/clusterstate" ]; then
	_pass "Pre-check: clusterstate symlink exists before clean"
else
	_fail "Pre-check: clusterstate symlink exists before clean"
fi

# Run make clean
make -s -C "$_cluster_dir" clean 2>/dev/null

# Post-check: externalized state directory removed
if [ ! -d "$_ext_state" ]; then
	_pass "make clean removed externalized state directory"
else
	_fail "make clean removed externalized state directory (still exists: $_ext_state)"
fi

# Post-check: clusterstate symlink removed
if [ ! -L "$_cluster_dir/clusterstate" ]; then
	_pass "make clean removed clusterstate symlink"
else
	_fail "make clean removed clusterstate symlink"
fi

# Post-check: .install-complete removed (by rm -f .??*)
if [ ! -f "$_cluster_dir/.install-complete" ]; then
	_pass "make clean removed .install-complete marker"
else
	_fail "make clean removed .install-complete marker"
fi

# Post-check: .shutdown.log removed
if [ ! -f "$_cluster_dir/.shutdown.log" ]; then
	_pass "make clean removed .shutdown.log"
else
	_fail "make clean removed .shutdown.log"
fi

# Post-check: cluster.conf preserved
if [ -f "$_cluster_dir/cluster.conf" ]; then
	_pass "make clean preserved cluster.conf"
else
	_fail "make clean preserved cluster.conf"
fi

# --- Test 2: clean is a no-op when clusterstate symlink doesn't exist ---
echo ""
echo "--- Test 2: clean with no clusterstate symlink ---"

# Recreate minimal state (no clusterstate symlink this time)
touch "$_cluster_dir/.install-complete"

make -s -C "$_cluster_dir" clean 2>/dev/null

if [ ! -f "$_cluster_dir/.install-complete" ]; then
	_pass "make clean works without clusterstate symlink"
else
	_fail "make clean works without clusterstate symlink"
fi

# --- Test 3: install guard code path (aba.sh logic) ---
echo ""
echo "--- Test 3: install guard detects stale markers on vmw/kvm ---"

# The install guard checks: .install-complete exists + ${platform}-exists.sh returns 1
# We test the logic by checking the code structure in aba.sh
if grep -q 'install_vms_gone' scripts/aba.sh && \
   grep -q 'exists.sh' scripts/aba.sh && \
   grep -q "clean.*then.*install" scripts/aba.sh; then
	_pass "aba.sh install guard checks VM existence and suggests clean"
else
	_fail "aba.sh install guard checks VM existence and suggests clean"
fi

# Verify the guard only fires for vmw/kvm (not bm)
if grep -A5 '_install_vms_gone=' scripts/aba.sh | grep -q 'vmw|kvm'; then
	_pass "install guard VM check scoped to vmw/kvm only"
else
	_fail "install guard VM check scoped to vmw/kvm only"
fi

# --- Test 4: clean target in Makefile.cluster includes clusterstate removal ---
echo ""
echo "--- Test 4: Makefile.cluster clean target ---"

if grep -q 'clusterstate' templates/Makefile.cluster; then
	_pass "Makefile.cluster clean target handles clusterstate"
else
	_fail "Makefile.cluster clean target handles clusterstate"
fi

# Verify it follows the symlink (readlink) before removing
if grep 'clusterstate' templates/Makefile.cluster | grep -q 'readlink'; then
	_pass "Makefile.cluster resolves symlink via readlink before removal"
else
	_fail "Makefile.cluster resolves symlink via readlink before removal"
fi

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
