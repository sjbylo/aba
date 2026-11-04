#!/bin/bash
# Test: install guard detects VMs deleted outside ABA
# Regression test for: UX dead-end loop when .install-complete exists but VMs are gone.
#
# When a cluster is installed via VMs (vmw/kvm) and the VMs are later deleted
# outside ABA, the .install-complete marker becomes stale. The install guard
# must detect this and suggest 'delete' then 'install' (not a misleading
# 'already installed' / 'shut down' loop). Clean is refused while installed —
# 'aba delete' is the recovery path (passes force=1 to clean after VMs go).
#
# Also verifies that cluster-clean.sh removes externalized state via the
# clusterstate symlink (Makefile.cluster delegates clean to that script).
# Full refuse/force coverage lives in test-cluster-clean-gate.sh.

set -euo pipefail

_aba_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$_aba_root"
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

echo "=== Install guard: stale VM markers ==="

# Fake aba root so SCRIPTS=../scripts and source scripts/include_all.sh resolve
mkdir -p "$_tmp/cluster"
ln -sfn "$_aba_root/scripts" "$_tmp/scripts"
ln -sfn "$_aba_root/templates" "$_tmp/templates"
ln -sfn "../templates/Makefile.cluster" "$_tmp/cluster/Makefile"
ln -sfn ../scripts "$_tmp/cluster/scripts"
ln -sfn ../templates "$_tmp/cluster/templates"
ln -sfn "$_aba_root/aba.conf" "$_tmp/aba.conf" 2>/dev/null || touch "$_tmp/aba.conf"

_cluster_dir="$_tmp/cluster"

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

# --- Test 1: cluster-clean.sh removes externalized state via clusterstate symlink ---
echo ""
echo "--- Test 1: cluster-clean.sh removes externalized state ---"

if [ -d "$_ext_state" ] && [ -f "$_ext_state/state.sh" ]; then
	_pass "Pre-check: externalized state exists before clean"
else
	_fail "Pre-check: externalized state exists before clean"
fi

if [ -L "$_cluster_dir/clusterstate" ]; then
	_pass "Pre-check: clusterstate symlink exists before clean"
else
	_fail "Pre-check: clusterstate symlink exists before clean"
fi

# Without force, clean must refuse while .install-complete exists
_refuse_out=$(cd "$_cluster_dir" && bash scripts/cluster-clean.sh 2>&1) && _refuse_rc=0 || _refuse_rc=$?
if [ "$_refuse_rc" -ne 0 ] && echo "$_refuse_out" | grep -qi 'Refusing to clean'; then
	_pass "cluster-clean.sh refuses while .install-complete (no force)"
else
	_fail "cluster-clean.sh refuses while .install-complete (no force) (rc=$_refuse_rc)"
	echo "$_refuse_out"
fi

# force=1: removes markers + follows clusterstate symlink (post-delete path)
(cd "$_cluster_dir" && bash scripts/cluster-clean.sh force=1)

if [ ! -d "$_ext_state" ]; then
	_pass "cluster-clean.sh force=1 removed externalized state directory"
else
	_fail "cluster-clean.sh force=1 removed externalized state directory (still exists: $_ext_state)"
fi

if [ ! -L "$_cluster_dir/clusterstate" ]; then
	_pass "cluster-clean.sh force=1 removed clusterstate symlink"
else
	_fail "cluster-clean.sh force=1 removed clusterstate symlink"
fi

if [ ! -f "$_cluster_dir/.install-complete" ]; then
	_pass "cluster-clean.sh force=1 removed .install-complete marker"
else
	_fail "cluster-clean.sh force=1 removed .install-complete marker"
fi

if [ ! -f "$_cluster_dir/.shutdown.log" ]; then
	_pass "cluster-clean.sh force=1 removed .shutdown.log"
else
	_fail "cluster-clean.sh force=1 removed .shutdown.log"
fi

if [ -f "$_cluster_dir/cluster.conf" ]; then
	_pass "cluster-clean.sh preserved cluster.conf"
else
	_fail "cluster-clean.sh preserved cluster.conf"
fi

# --- Test 2: clean is a no-op when clusterstate symlink doesn't exist ---
echo ""
echo "--- Test 2: clean with no clusterstate symlink ---"

touch "$_cluster_dir/.install-complete"
(cd "$_cluster_dir" && bash scripts/cluster-clean.sh force=1)

if [ ! -f "$_cluster_dir/.install-complete" ]; then
	_pass "cluster-clean.sh works without clusterstate symlink"
else
	_fail "cluster-clean.sh works without clusterstate symlink"
fi

# --- Test 3: install guard code path (aba.sh logic) ---
echo ""
echo "--- Test 3: install guard detects stale markers on vmw/kvm ---"

# Recovery is delete then install (clean alone is refused while installed).
if grep -q '_install_vms_gone' scripts/aba.sh && \
   grep -q 'exists.sh' scripts/aba.sh && \
   grep -q "delete' then 'aba -d" scripts/aba.sh; then
	_pass "aba.sh install guard checks VM existence and suggests delete then install"
else
	_fail "aba.sh install guard checks VM existence and suggests delete then install"
fi

if grep -A5 '_install_vms_gone=' scripts/aba.sh | grep -q 'vmw|kvm'; then
	_pass "install guard VM check scoped to vmw/kvm only"
else
	_fail "install guard VM check scoped to vmw/kvm only"
fi

# --- Test 4: Makefile.cluster clean delegates; cluster-clean.sh owns clusterstate ---
echo ""
echo "--- Test 4: clean target / cluster-clean.sh ---"

if grep -q 'cluster-clean\.sh' templates/Makefile.cluster; then
	_pass "Makefile.cluster clean target delegates to cluster-clean.sh"
else
	_fail "Makefile.cluster clean target delegates to cluster-clean.sh"
fi

if grep -q 'clusterstate' scripts/cluster-clean.sh && \
   grep 'clusterstate' scripts/cluster-clean.sh | grep -q 'readlink'; then
	_pass "cluster-clean.sh resolves symlink via readlink before removal"
else
	_fail "cluster-clean.sh resolves symlink via readlink before removal"
fi

if grep -q 'Refusing to clean' scripts/cluster-clean.sh; then
	_pass "cluster-clean.sh refuses clean while installed (unless force)"
else
	_fail "cluster-clean.sh refuses clean while installed (unless force)"
fi

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
