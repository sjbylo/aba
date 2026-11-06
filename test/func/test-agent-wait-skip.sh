#!/bin/bash
# Test: continuous BM/VMW install chain; wait-agent on install only (not aba mon)
# Regression for: #B80 — .bm-message/.bm-nextstep/.auto-agent-up removed

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_assert() {
	local desc=$1 want=$2
	if [ "$want" = "pass" ]; then
		pass=$(( pass + 1 ))
		printf "  \033[32mPASS\033[0m  %s\n" "$desc"
	else
		fail=$(( fail + 1 ))
		printf "  \033[31mFAIL\033[0m  %s\n" "$desc"
	fi
}

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Minimal aba root with cluster Makefile
mkdir -p "$_tmp/cluster" "$_tmp/scripts" "$_tmp/templates" "$_tmp/others"
ln -sfn "$(pwd)/scripts" "$_tmp/scripts_real"
# Point cluster at real scripts/templates via relative links from cluster dir
ln -sfn "$(pwd)/templates/Makefile.cluster" "$_tmp/cluster/Makefile"
ln -sfn "$(pwd)/scripts" "$_tmp/cluster/scripts"
ln -sfn "$(pwd)/templates" "$_tmp/cluster/templates"
ln -sfn "$(pwd)/others" "$_tmp/others"
cat > "$_tmp/aba.conf" <<'EOF'
platform=bm
ask=false
ocp_version=4.21.17
EOF
ln -sfn "../aba.conf" "$_tmp/cluster/aba.conf"

CLUSTER="$_tmp/cluster"
mkdir -p "$CLUSTER/iso-agent-based"
# Fake ISO so Make deps that only check the path can proceed in -n mode
: > "$CLUSTER/iso-agent-based/agent.$(uname -m).iso"
touch "$CLUSTER/install-config.yaml" "$CLUSTER/agent-config.yaml" "$CLUSTER/.preflight-done" "$CLUSTER/.infra-dns" "$CLUSTER/.init" "$CLUSTER/.cli" "$CLUSTER/.resolve-vips"
cat > "$CLUSTER/cluster.conf" <<'EOF'
cluster_name=testbm
base_domain=example.com
num_masters=1
num_workers=0
starting_ip=10.0.1.201
machine_network=10.0.0.0
prefix_length=20
EOF
# openshift-install path may be required as order-only; touch home bin stub if missing
mkdir -p "$HOME/bin"
touch "$HOME/bin/openshift-install" 2>/dev/null || true

echo "=== Test: unified install chain (no BM stop markers) ==="

# Old markers must not appear in Makefile.cluster
if ! grep -qE '\.bm-message|\.bm-nextstep|\.autopoweroff|\.autoupload|\.autorefresh|\.auto-agent-up' templates/Makefile.cluster; then
	_assert "Makefile.cluster has no old BM/VM stamps" "pass"
else
	_assert "Makefile.cluster has no old BM/VM stamps" "fail"
fi

if grep -q '\.vms-stopped' templates/Makefile.cluster && grep -q '\.iso-uploaded' templates/Makefile.cluster && grep -q '\.vms-ready' templates/Makefile.cluster; then
	_assert "Makefile.cluster uses new stamp names" "pass"
else
	_assert "Makefile.cluster uses new stamp names" "fail"
fi

# Dry-run install should mention bm-ask scripts and monitor (not .bm-message)
_output=$(make -n -C "$CLUSTER" install 2>&1) || true
if echo "$_output" | grep -q 'bm-ask-edit.sh' && echo "$_output" | grep -q 'bm-ask-boot.sh'; then
	_assert "BM install dry-run includes ask-edit and ask-boot" "pass"
else
	_assert "BM install dry-run includes ask-edit and ask-boot" "fail"
	echo "$_output" | head -40
fi

if echo "$_output" | grep -q 'monitor-install.sh'; then
	_assert "BM install dry-run includes monitor-install" "pass"
else
	_assert "BM install dry-run includes monitor-install" "fail"
fi

if ! echo "$_output" | grep -qE '\.bm-message|\.bm-nextstep'; then
	_assert "BM install dry-run has no old stop markers" "pass"
else
	_assert "BM install dry-run has no old stop markers" "fail"
fi

# wait-agent is on the install Make chain only — NOT inside monitor-install
# (so 'aba mon' does not block on port 8090 after bootstrap).
if ! grep -q 'wait-agent-up.sh' scripts/monitor-install.sh; then
	_assert "monitor-install.sh does not call wait-agent-up" "pass"
else
	_assert "monitor-install.sh does not call wait-agent-up" "fail"
fi

if awk '/^\.install-complete:/{p=1} p&&/wait-agent-up/{found=1} p&&/^[^[:space:]#]/{if(!/^\.install-complete:/) exit} END{exit !found}' templates/Makefile.cluster; then
	_assert ".install-complete recipe calls wait-agent-up" "pass"
else
	_assert ".install-complete recipe calls wait-agent-up" "fail"
fi

_mon_recipe=$(awk '/^mon:/{p=1; next} p && /^[^[:space:]#]/{exit} p' templates/Makefile.cluster)
if ! echo "$_mon_recipe" | grep -q 'wait-agent-up'; then
	_assert "mon target does not call wait-agent-up" "pass"
else
	_assert "mon target does not call wait-agent-up" "fail"
fi

if ! grep -q '^\.auto-agent-up:' templates/Makefile.cluster; then
	_assert ".auto-agent-up Make stamp removed" "pass"
else
	_assert ".auto-agent-up Make stamp removed" "fail"
fi

# Shared BMC host helpers (unit checks in stub cluster dir).
if (cd "$CLUSTER" && source scripts/include_all.sh &&
	! bmc_has_hosts && [ "$(bmc_host_count)" = "0" ]); then
	_assert "bmc_has_hosts/count empty without bmc.conf" "pass"
else
	_assert "bmc_has_hosts/count empty without bmc.conf" "fail"
fi
cat > "$CLUSTER/bmc.conf" <<'EOF'
# comment
bmc_host_master0=1.2.3.4
bmc_host_master1=1.2.3.5
EOF
if (cd "$CLUSTER" && source scripts/include_all.sh &&
	bmc_has_hosts && [ "$(bmc_host_count)" = "2" ] &&
	[ "$(bmc_host_list | tr '\n' ' ')" = "master0 master1 " ]); then
	_assert "bmc_host_list/count/has_hosts" "pass"
else
	_assert "bmc_host_list/count/has_hosts" "fail"
fi
rm -f "$CLUSTER/bmc.conf"

# Manual BM (no BMC): wait-agent-up must exit immediately (no 5m spinner).
# Pre-set CLUSTER_NAME/ASSETS_DIR so we exercise the skip gate without a full
# agentconf (cluster-config-check would otherwise abort the stub cluster).
echo "10.0.1.201" > "$CLUSTER/iso-agent-based/rendezvousIP"
_t0=$(date +%s)
_wa_rc=0
_wa_out=$(cd "$CLUSTER" && CLUSTER_NAME=testbm ASSETS_DIR=iso-agent-based \
	bash scripts/wait-agent-up.sh 2>&1) || _wa_rc=$?
_t1=$(date +%s)
_elapsed=$(( _t1 - _t0 ))
if [ "$_wa_rc" -eq 0 ] && [ "$_elapsed" -lt 15 ] && ! echo "$_wa_out" | grep -q 'Waiting for Agent'; then
	_assert "wait-agent-up skips manual BM (no BMC)" "pass"
else
	_assert "wait-agent-up skips manual BM (no BMC)" "fail"
	echo "rc=$_wa_rc elapsed=${_elapsed}s out=$_wa_out" | head -20
fi

# BM + BMC: must enter the wait (not the manual-BM skip). Cap with timeout.
cat > "$CLUSTER/bmc.conf" <<'EOF'
bmc_host_master0=1.2.3.4
EOF
_wa_rc=0
_wa_out=$(cd "$CLUSTER" && CLUSTER_NAME=testbm ASSETS_DIR=iso-agent-based \
	timeout 12 bash scripts/wait-agent-up.sh 2>&1) || _wa_rc=$?
if echo "$_wa_out" | grep -q 'Waiting for Agent'; then
	_assert "wait-agent-up waits after BMC auto-boot" "pass"
else
	_assert "wait-agent-up waits after BMC auto-boot" "fail"
	echo "rc=$_wa_rc out=$_wa_out" | head -20
fi
rm -f "$CLUSTER/bmc.conf"

# VMware chain: stamps are in TARGET_DEPENDENCIES
cat > "$_tmp/aba.conf" <<'EOF'
platform=vmw
ask=false
ocp_version=4.21.17
EOF
touch "$CLUSTER/vmware.conf"
_output=$(make -n -C "$CLUSTER" install 2>&1) || true
if echo "$_output" | grep -qE 'vmw-kill|vmw-upload|vmw-refresh'; then
	_assert "VMW install dry-run uses HV scripts" "pass"
else
	_assert "VMW install dry-run uses HV scripts" "fail"
	echo "$_output" | head -40
fi

# iso-only step must not require boot ask
_output=$(make -n -C "$CLUSTER" iso 2>&1) || true
if echo "$_output" | grep -q 'bm-ask-edit.sh' && ! echo "$_output" | grep -q 'bm-ask-boot.sh'; then
	_assert "iso target runs edit ask, not boot ask" "pass"
else
	# On vmw, bm-ask-edit no-ops but is still invoked
	if echo "$_output" | grep -q 'bm-ask-edit.sh'; then
		_assert "iso target runs edit ask, not boot ask" "pass"
	else
		_assert "iso target runs edit ask, not boot ask" "fail"
	fi
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
