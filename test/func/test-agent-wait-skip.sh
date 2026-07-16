#!/bin/bash
# Test: .auto-agent-up file target skips agent wait on retry
#
# Validates that the Makefile correctly skips wait-agent-up.sh when
# .auto-agent-up already exists and no prerequisites are newer.
# Tests both bare-metal and VMware/KVM flows.

set -e

PASS=0
FAIL=0
TESTS=0

_assert() {
	local desc="$1" result="$2"
	TESTS=$(( TESTS + 1 ))
	if [ "$result" = "pass" ]; then
		echo "  PASS: $desc"
		PASS=$(( PASS + 1 ))
	else
		echo "  FAIL: $desc"
		FAIL=$(( FAIL + 1 ))
	fi
}

# Create a temporary cluster directory with minimal scaffolding
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CLUSTER="$TMPDIR/testcluster"
mkdir -p "$CLUSTER/iso-agent-based"

# Create minimal cluster.conf
cat > "$CLUSTER/cluster.conf" <<'CONF'
cluster_name=testcluster
base_domain=example.com
machine_network=10.0.0.0/24
starting_ip=10.0.0.100
gateway=10.0.0.1
dns_server=10.0.0.1
master_count=1
worker_count=0
CONF

# Symlink Makefile (bare-metal uses Makefile.cluster)
ln -s "$(pwd)/templates/Makefile.cluster" "$CLUSTER/Makefile"

# Create symlinks that the Makefile expects
ln -s "$(pwd)/scripts" "$CLUSTER/scripts"
ln -s "$(pwd)/templates" "$CLUSTER/templates"

# Create a minimal aba.conf
cat > "$TMPDIR/aba.conf" <<'CONF'
platform=bm
ocp_version=4.22.4
CONF

# Create the full marker chain so make sees everything as up-to-date.
# Makefile dependency order (each must be newer than its prerequisites):
#   .init → cluster.conf/mirror.conf → install-config.yaml → ISO
# Use current timestamps with sleep to guarantee ordering.
# Must be newer than real files like /home/steve/bin/openshift-install.
touch "$CLUSTER/.init"
sleep 0.2
touch "$CLUSTER/mirror.conf" "$CLUSTER/cluster.conf" "$CLUSTER/.cli"
sleep 0.2
touch "$CLUSTER/install-config.yaml" "$CLUSTER/agent-config.yaml" "$CLUSTER/.preflight-done"
sleep 0.2
touch "$CLUSTER/iso-agent-based/agent.$(uname -m).iso"

# We need .bm-message and .bm-nextstep to reach the agent/mon flow
touch "$CLUSTER/.bm-message"
touch "$CLUSTER/.bm-nextstep"

echo
echo "=== Test: Bare-metal .auto-agent-up skip logic ==="
echo

# -------------------------------------------------------
# Test 1: make -n should run wait-agent-up.sh when .auto-agent-up does NOT exist
# -------------------------------------------------------
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "BM: agent wait runs when .auto-agent-up missing" "pass"
else
	_assert "BM: agent wait runs when .auto-agent-up missing" "fail"
fi

# -------------------------------------------------------
# Test 2: after touching .auto-agent-up (newer than ISO), make should skip
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/.auto-agent-up"
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "BM: agent wait skipped when .auto-agent-up exists (ISO unchanged)" "fail"
else
	_assert "BM: agent wait skipped when .auto-agent-up exists (ISO unchanged)" "pass"
fi

# -------------------------------------------------------
# Test 3: after rebuilding ISO (ISO newer), make should re-run agent wait
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/iso-agent-based/agent.$(uname -m).iso"
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "BM: agent wait re-runs after ISO rebuild" "pass"
else
	_assert "BM: agent wait re-runs after ISO rebuild" "fail"
fi

# -------------------------------------------------------
# Test 4: re-touch .auto-agent-up (newer than ISO again), should skip
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/.auto-agent-up"
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "BM: agent wait skipped again after re-touch" "fail"
else
	_assert "BM: agent wait skipped again after re-touch" "pass"
fi

echo
echo "=== Test: VMware .auto-agent-up skip logic ==="
echo

# Reconfigure for VMware
cat > "$TMPDIR/aba.conf" <<'CONF'
platform=vmw
ocp_version=4.22.4
CONF

# Create vmware.conf (required by hv_conf_dep)
touch "$CLUSTER/vmware.conf"

# Re-create full marker chain for VMware with correct timestamp ordering.
# Must be newer than real files like /home/steve/bin/openshift-install.
touch "$CLUSTER/.init"
sleep 0.2
touch "$CLUSTER/vmware.conf" "$CLUSTER/mirror.conf" "$CLUSTER/cluster.conf" "$CLUSTER/.cli"
sleep 0.2
touch "$CLUSTER/install-config.yaml" "$CLUSTER/agent-config.yaml" "$CLUSTER/.preflight-done"
sleep 0.2
touch "$CLUSTER/iso-agent-based/agent.$(uname -m).iso"
sleep 0.2
touch "$CLUSTER/.autopoweroff"
sleep 0.2
touch "$CLUSTER/.autoupload"
sleep 0.2
touch "$CLUSTER/.autorefresh"

# Remove .auto-agent-up for clean test
rm -f "$CLUSTER/.auto-agent-up"

# -------------------------------------------------------
# Test 5: VMware: agent wait runs when .auto-agent-up missing
# -------------------------------------------------------
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "VMW: agent wait runs when .auto-agent-up missing" "pass"
else
	_assert "VMW: agent wait runs when .auto-agent-up missing" "fail"
fi

# -------------------------------------------------------
# Test 6: VMware: agent wait skipped when .auto-agent-up exists and .autorefresh is older
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/.auto-agent-up"
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "VMW: agent wait skipped when .auto-agent-up newer than .autorefresh" "fail"
else
	_assert "VMW: agent wait skipped when .auto-agent-up newer than .autorefresh" "pass"
fi

# -------------------------------------------------------
# Test 7: VMware: agent wait re-runs when .autorefresh is newer (VM refresh)
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/.autorefresh"
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "VMW: agent wait re-runs after VM refresh (.autorefresh newer)" "pass"
else
	_assert "VMW: agent wait re-runs after VM refresh (.autorefresh newer)" "fail"
fi

# -------------------------------------------------------
# Test 8: VMware: agent wait re-runs when ISO is newer (even if .autorefresh is older)
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/.auto-agent-up"
sleep 0.5
touch "$CLUSTER/iso-agent-based/agent.$(uname -m).iso"
_output=$(make -n -C "$CLUSTER" .auto-agent-up 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "VMW: agent wait re-runs after ISO rebuild" "pass"
else
	_assert "VMW: agent wait re-runs after ISO rebuild" "fail"
fi

echo
echo "=== Test: TARGET_DEPENDENCIES uses .auto-agent-up (not PHONY agent) ==="
echo

# Reconfigure for bare-metal
cat > "$TMPDIR/aba.conf" <<'CONF'
platform=bm
ocp_version=4.22.4
CONF

# Reset state — rebuild marker chain with BM timestamps
rm -f "$CLUSTER/.auto-agent-up" "$CLUSTER/.autopoweroff" "$CLUSTER/.autoupload" "$CLUSTER/.autorefresh" "$CLUSTER/vmware.conf"
touch "$CLUSTER/.init"
sleep 0.2
touch "$CLUSTER/mirror.conf" "$CLUSTER/cluster.conf" "$CLUSTER/.cli"
sleep 0.2
touch "$CLUSTER/install-config.yaml" "$CLUSTER/agent-config.yaml" "$CLUSTER/.preflight-done"
sleep 0.2
touch "$CLUSTER/iso-agent-based/agent.$(uname -m).iso"
touch "$CLUSTER/.bm-message" "$CLUSTER/.bm-nextstep"

# -------------------------------------------------------
# Test 9: bare-metal install target includes .auto-agent-up in dry-run
# -------------------------------------------------------
_output=$(make -n -C "$CLUSTER" install 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "BM install target runs agent wait via .auto-agent-up" "pass"
else
	_assert "BM install target runs agent wait via .auto-agent-up" "fail"
fi

# -------------------------------------------------------
# Test 10: bare-metal install retry skips agent wait when .auto-agent-up exists
# -------------------------------------------------------
sleep 0.5
touch "$CLUSTER/.auto-agent-up"
_output=$(make -n -C "$CLUSTER" install 2>&1) || true
if echo "$_output" | grep -q "wait-agent-up.sh"; then
	_assert "BM install retry skips agent wait (.auto-agent-up exists)" "fail"
else
	_assert "BM install retry skips agent wait (.auto-agent-up exists)" "pass"
fi

echo
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed (of $TESTS)"
echo "==========================================="
echo

[ "$FAIL" -eq 0 ] || exit 1
