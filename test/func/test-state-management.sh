#!/bin/bash
# Unit tests for ADR-007 state management: Phase 3 (drift detection) and Phase 4 (dir recreation)
# No running cluster or mirror required — uses synthetic state/config.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; fail=$(( fail + 1 )); FAILURES=1; }

_cleanup_all() {
	rm -rf "$_test_mirror_dir" "$_test_mirror_state"
	rm -rf "$_test_cluster_dir" "$_test_cluster_state"
	rm -f /tmp/_e2e_drift_stderr*.txt
}
trap _cleanup_all EXIT

echo
echo "=== Testing: ADR-007 State Management (Phases 3-5) ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Mirror drift detection
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Phase 3: Mirror drift detection ---"

_test_mirror_dir="$PWD/_test-drift-mirror"
_test_mirror_state="$HOME/.aba/mirror/_test-drift-mirror"

mkdir -p "$_test_mirror_dir" "$_test_mirror_state"

cat > "$_test_mirror_dir/mirror.conf" <<'CONF'
reg_host=drifted.example.com
reg_port=9999
reg_vendor=docker
CONF

cat > "$_test_mirror_state/state.sh" <<'STATE'
reg_host=original.example.com
reg_port=5000
reg_vendor=docker
STATE

# 3a: state.sh reg_host overrides drifted mirror.conf
_out=$(cd "$_test_mirror_dir" && bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; eval \"\$(normalize-mirror-conf)\"; echo \"\$reg_host\"")
if [ "$_out" = "original.example.com" ]; then
	test_pass "state.sh reg_host overrides drifted mirror.conf"
else
	test_fail "state.sh reg_host should be 'original.example.com', got '$_out'"
fi

# 3b: state.sh reg_port overrides drifted mirror.conf
_out=$(cd "$_test_mirror_dir" && bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; eval \"\$(normalize-mirror-conf)\"; echo \"\$reg_port\"")
if [ "$_out" = "5000" ]; then
	test_pass "state.sh reg_port overrides drifted mirror.conf"
else
	test_fail "state.sh reg_port should be '5000', got '$_out'"
fi

# 3c: drift warning emitted on stderr
_stderr_file="/tmp/_e2e_drift_stderr_mirror.txt"
(cd "$_test_mirror_dir" && bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; normalize-mirror-conf" >/dev/null 2>"$_stderr_file")
if grep -q "reg_host=drifted.example.com differs" "$_stderr_file"; then
	test_pass "Drift warning emitted for reg_host mismatch"
else
	test_fail "Expected drift warning for reg_host in stderr. Got: $(cat "$_stderr_file")"
fi

# 3d: no warning when config matches state
cat > "$_test_mirror_dir/mirror.conf" <<'CONF'
reg_host=original.example.com
reg_port=5000
reg_vendor=docker
CONF

_stderr_file2="/tmp/_e2e_drift_stderr_mirror2.txt"
(cd "$_test_mirror_dir" && bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; normalize-mirror-conf" >/dev/null 2>"$_stderr_file2")
if [ ! -s "$_stderr_file2" ]; then
	test_pass "No drift warning when config matches state"
else
	test_fail "Unexpected warning when config matches state: $(cat "$_stderr_file2")"
fi

rm -rf "$_test_mirror_dir" "$_test_mirror_state"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Cluster drift detection
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Phase 3: Cluster drift detection ---"

_test_cluster_dir="$PWD/_test-drift-cluster"
_test_cluster_state="$HOME/.aba/clusters/_test-drift-cluster"

mkdir -p "$_test_cluster_dir" "$_test_cluster_state"

cat > "$_test_cluster_dir/cluster.conf" <<'CONF'
cluster_name=_test-drift-cluster
base_domain=drifted.example.com
cluster_type=sno
starting_ip=10.0.0.99
machine_network=10.0.0.0
prefix_length=20
platform=vmw
CONF

cat > "$_test_cluster_state/state.sh" <<'STATE'
cluster_name=_test-drift-cluster
base_domain=original.example.com
cluster_type=sno
starting_ip=10.0.0.50
machine_network=10.0.0.0
prefix_length=20
platform=vmw
STATE

# Cluster normalize needs aba.conf in parent
_stderr_file3="/tmp/_e2e_drift_stderr_cluster.txt"
_out=$(cd "$_test_cluster_dir" && bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; eval \"\$(normalize-cluster-conf 2>$_stderr_file3)\"; echo \"\$base_domain\"")
if [ "$_out" = "original.example.com" ]; then
	test_pass "state.sh base_domain overrides drifted cluster.conf"
else
	test_fail "state.sh base_domain should be 'original.example.com', got '$_out'"
fi

if grep -q "base_domain=drifted.example.com differs" "$_stderr_file3"; then
	test_pass "Drift warning emitted for cluster base_domain"
else
	test_fail "Expected drift warning for cluster base_domain. Got: $(cat "$_stderr_file3")"
fi

rm -rf "$_test_cluster_dir" "$_test_cluster_state"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Directory recreation from state backup
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Phase 4: Directory recreation ---"

_test_cluster_dir="$PWD/_test-recreate"
_test_cluster_state="$HOME/.aba/clusters/_test-recreate"

mkdir -p "$_test_cluster_state/backup"
chmod 700 "$_test_cluster_state"

cat > "$_test_cluster_state/state.sh" <<'STATE'
cluster_name=_test-recreate
base_domain=example.com
cluster_type=sno
platform=vmw
starting_ip=10.0.2.10
machine_network=10.0.0.0
prefix_length=20
STATE

cat > "$_test_cluster_state/backup/cluster.conf" <<'CONF'
cluster_name=_test-recreate
base_domain=example.com
starting_ip=10.0.2.10
machine_network=10.0.0.0/20
CONF

touch "$_test_cluster_state/backup/.init"
touch "$_test_cluster_state/backup/.install-complete"

# 4a: dir does not exist yet
if [ ! -d "$_test_cluster_dir" ]; then
	test_pass "Cluster directory does not exist before recreation"
else
	test_fail "Cluster directory already exists before test!"
fi

# 4b: aba --dir triggers recreation
_out=$(aba --dir _test-recreate info 2>&1 || true)
if [ -d "$_test_cluster_dir" ]; then
	test_pass "aba --dir recreated cluster directory"
else
	test_fail "aba --dir did NOT recreate cluster directory"
fi

# 4c: cluster.conf was restored
if [ -s "$_test_cluster_dir/cluster.conf" ] && grep -q "cluster_name=_test-recreate" "$_test_cluster_dir/cluster.conf"; then
	test_pass "cluster.conf restored from backup"
else
	test_fail "cluster.conf not properly restored"
fi

# 4d: Makefile symlink created
if [ -L "$_test_cluster_dir/Makefile" ]; then
	test_pass "Makefile symlink created"
else
	test_fail "Makefile symlink NOT created"
fi

# 4e: .install-complete marker restored
if [ -f "$_test_cluster_dir/.install-complete" ]; then
	test_pass ".install-complete marker restored"
else
	test_fail ".install-complete marker NOT restored"
fi

# 4f: clusterstate symlink
if [ -L "$_test_cluster_dir/clusterstate" ]; then
	_target=$(readlink "$_test_cluster_dir/clusterstate")
	if echo "$_target" | grep -q ".aba/clusters/_test-recreate"; then
		test_pass "clusterstate symlink points to state dir"
	else
		test_fail "clusterstate symlink points to wrong target: $_target"
	fi
else
	test_fail "clusterstate symlink NOT created"
fi

rm -rf "$_test_cluster_dir" "$_test_cluster_state"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: _recreate_cluster_dir helper function
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Phase 4: _recreate_cluster_dir helper ---"

_test_cluster_dir="$PWD/_test-helper-recreate"
_test_cluster_state="$HOME/.aba/clusters/_test-helper-recreate"

mkdir -p "$_test_cluster_state/backup"
chmod 700 "$_test_cluster_state"

cat > "$_test_cluster_state/state.sh" <<'STATE'
cluster_name=_test-helper-recreate
base_domain=test.example.com
STATE

cat > "$_test_cluster_state/backup/cluster.conf" <<'CONF'
cluster_name=_test-helper-recreate
base_domain=test.example.com
CONF

touch "$_test_cluster_state/backup/.init"

# 4g: helper returns 0 on success
_rc=0
bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; _recreate_cluster_dir _test-helper-recreate" || _rc=$?
if [ "$_rc" -eq 0 ] && [ -d "$_test_cluster_dir" ]; then
	test_pass "_recreate_cluster_dir returns 0 and creates dir"
else
	test_fail "_recreate_cluster_dir failed (rc=$_rc, dir exists=$(test -d "$_test_cluster_dir" && echo yes || echo no))"
fi

rm -rf "$_test_cluster_dir" "$_test_cluster_state"

# 4h: helper returns 1 when no state exists
_rc=0
bash -c "source $REPO_ROOT/scripts/include_all.sh noerr; _recreate_cluster_dir _nonexistent_cluster_xyz" || _rc=$?
if [ "$_rc" -eq 1 ]; then
	test_pass "_recreate_cluster_dir returns 1 for missing state"
else
	test_fail "_recreate_cluster_dir should return 1 for missing state, got rc=$_rc"
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
