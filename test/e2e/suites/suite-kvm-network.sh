#!/usr/bin/env bash
# =============================================================================
# Suite: KVM Network (VLAN + bonding matrix)
# =============================================================================
# Purpose: VLAN and bonding network configuration tests on KVM platform.
#          Uses the pre-populated Quay registry on conN (no save/load needed).
#
# Test matrix:
#   for vlan in 123 ""; do
#     for ctype in sno compact; do
#       1. Single port (ports=enp1s0, vlan=$vlan)     -- ISO, boot, verify UP
#       2. Bonding   (ports=enp1s0,enp2s0, vlan=$vlan) -- ISO, boot, verify UP
#     done
#   done
#
# VLAN tests use VLAN 123 (guest-side tagging on br-lab).  Non-VLAN tests use
# the pool's default machine_network.
#
# Prerequisite:
#   - Internet-connected bastion (conN) with aba installed.
#   - Pre-populated Quay on conN (via setup-pool-registry.sh).
#   - ~/.kvm.conf on conN with LIBVIRT_URI, KVM_STORAGE_POOL, KVM_NETWORK.
#   - KVM host has br-lab.123 (10.10.123.1/24) + ip_forward=1.
#   - conN has route to 10.10.123.0/24 via KVM host.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-ops.sh"
source "$_SUITE_DIR/../lib/setup.sh"
source "$_SUITE_DIR/../lib/suite-helpers.sh"

# --- Configuration ----------------------------------------------------------

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
NTP_IP="${NTP_SERVER:-10.0.1.8}"
KVM_CONF="${KVM_CONF:-~/.kvm.conf}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: ensure pre-populated registry" \
	"Setup: install aba, configure for KVM" \
	"Setup: configure mirror for local registry" \
	"VLAN: verify route to KVM VLAN subnet" \
	"VLAN SNO: single port" \
	"VLAN SNO: bonding" \
	"VLAN compact: single port" \
	"VLAN compact: bonding" \
	"Non-VLAN SNO: bonding" \
	"Non-VLAN compact: bonding" \
	"Cleanup"

suite_begin "kvm-network"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_install_aba
e2e_run "Configure aba.conf (temporary, for version resolution)" \
	"aba --noask --platform kvm --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: version resolved" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
	"test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba, configure for KVM
# ============================================================================
test_begin "Setup: install aba, configure for KVM"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf for KVM" \
	"aba --noask --platform kvm --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

e2e_run "Verify aba.conf: platform=kvm" "grep ^platform=kvm aba.conf"
e2e_run "Verify aba.conf: version format" \
	"grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy kvm.conf from home directory" \
	"cp -v $KVM_CONF kvm.conf"
e2e_run "Verify kvm.conf has LIBVIRT_URI" "grep ^LIBVIRT_URI kvm.conf"
e2e_run "Verify kvm.conf has KVM_NETWORK" "grep ^KVM_NETWORK kvm.conf"

suite_setup_ntp

test_end

# ============================================================================
# 3. Configure mirror to use local pre-populated registry
# ============================================================================
test_begin "Setup: configure mirror for local registry"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set reg_host to local registry" \
	"sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
	"sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
	"sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"
e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"

e2e_run "Generate pool-registry pull secret via aba" \
	"printf 'init\np4ssw0rd\n' | aba -d mirror password && cp ~/.aba/mirror/mirror/pull-secret-mirror.json /tmp/pool-reg-pull-secret.json"

e2e_run "Register pool registry" \
	"aba -d mirror register --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert $POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

test_end

# ============================================================================
# 4. VLAN: verify route to KVM VLAN subnet
# ============================================================================
test_begin "VLAN: verify route to KVM VLAN subnet"

e2e_run "Verify route to KVM VLAN subnet exists" \
	"ip route show 10.10.123.0/24 | grep via"
e2e_run "Ping KVM VLAN gateway (10.10.123.1)" \
	"ping -c 2 -W 3 $(pool_kvm_vlan_gateway)"

test_end

# ============================================================================
# Helper: run a single KVM network config test
# ============================================================================
# Usage: _kvm_net_test LABEL CTYPE CNAME VLAN PORTS IF_CHECK
_kvm_net_test() {
	local label="$1"
	local ctype="$2"
	local cname="$3"
	local vlan="$4"
	local ports="$5"
	local if_check="$6"

	local machine_network next_hop start_ip ntp_ip_test
	local _saved_aba_machine_network
	_saved_aba_machine_network=$(grep '^machine_network=' aba.conf | cut -d= -f2 | awk '{print $1}')

	if [ -n "$vlan" ]; then
		machine_network="$(pool_kvm_vlan_network)"
		next_hop="$(pool_kvm_vlan_gateway)"
		start_ip="$(pool_kvm_vlan_node_ip)"
		ntp_ip_test="$(pool_kvm_vlan_gateway)"
	else
		machine_network="$(pool_machine_network)"
		next_hop="${DEFAULT_GATEWAY:-10.0.1.1}"
		start_ip="$(pool_node_ip)"
		ntp_ip_test="$NTP_IP"
	fi

	test_begin "$label"

	if [ -n "$vlan" ]; then
		e2e_run "Set aba.conf machine_network for VLAN ($machine_network)" \
			"sed -i \"s#^machine_network=.*#machine_network=$machine_network #g\" aba.conf"
		e2e_run "Set aba.conf ntp_servers for VLAN (reachable from VLAN subnet)" \
			"aba --ntp $ntp_ip_test"
	fi

	e2e_run "Delete any leftover $cname cluster" \
		"_e2e_delete_leftover_cluster $cname"

	e2e_run "Generate cluster.conf for $cname" \
		"aba cluster -n $cname -t $ctype --starting-ip $start_ip --step cluster.conf"

	e2e_run "Set machine_network=$machine_network" \
		"sed -i \"s#^machine_network=.*#machine_network=$machine_network #g\" $cname/cluster.conf"
	e2e_run "Set next_hop_address=$next_hop" \
		"sed -i \"s/^.*next_hop_address=.*/next_hop_address=$next_hop /g\" $cname/cluster.conf"

	if [ -n "$vlan" ] && [ "$ctype" != "sno" ]; then
		local _vlan_api_vip _vlan_apps_vip
		_vlan_api_vip="$(pool_kvm_vlan_api_vip)"
		_vlan_apps_vip="$(pool_kvm_vlan_apps_vip)"
		e2e_run "Set VLAN api_vip=$_vlan_api_vip" \
			"sed -i \"s/^api_vip=.*/api_vip=$_vlan_api_vip /g\" $cname/cluster.conf"
		e2e_run "Set VLAN ingress_vip=$_vlan_apps_vip" \
			"sed -i \"s/^ingress_vip=.*/ingress_vip=$_vlan_apps_vip /g\" $cname/cluster.conf"
	fi

	e2e_run "Set ports=$ports" \
		"sed -i 's/^.*ports=.*/ports=$ports /g' $cname/cluster.conf"

	e2e_run "Set vlan=$vlan" \
		"sed -i \"s/^.*vlan=.*/vlan=$vlan /g\" $cname/cluster.conf"

	if [ -n "$vlan" ]; then
		local _vlan_dns
		_vlan_dns="$(pool_kvm_vlan_dns)"
		e2e_run "Set VLAN dns_servers=$_vlan_dns" \
			"sed -i \"s/^dns_servers=.*/dns_servers=$_vlan_dns /g\" $cname/cluster.conf"
	fi

	assert_file_exists "$cname/cluster.conf"
	e2e_diag "Show cluster.conf" "grep -E '^\w' $cname/cluster.conf"

	e2e_run "Create ISO for $cname" "aba --dir $cname iso"
	e2e_run "Upload ISO for $cname" "aba --dir $cname upload"
	e2e_add_to_cluster_cleanup "$PWD/$cname"
	e2e_run "Boot VMs for $cname" "aba --dir $cname refresh"

	e2e_run -r 1 1 "Wait for node0 SSH ($cname)" \
		"timeout 8m bash -c 'until aba --dir $cname ssh --cmd hostname; do sleep 10; done'"

	if echo "$if_check" | grep -q bond0; then
		e2e_run -q "Wait for bond0 to settle" "sleep 30"
	fi

	e2e_diag "Show ip a on $cname node" \
		"aba --dir $cname ssh --cmd 'ip a'"

	e2e_run "Verify $if_check on $cname" \
		"timeout 8m bash -c 'until aba --dir $cname ssh --cmd \"ip a\" | grep \"$if_check\"; do sleep 10; done'"

	e2e_run "Verify NTP on $cname" \
		"timeout 8m bash -c 'until aba --dir $cname ssh --cmd \"chronyc -N sources\" | grep ${ntp_ip_test}; do sleep 10; done'"

	e2e_run "Delete $cname VMs" "aba --dir $cname delete"
	e2e_remove_from_cluster_cleanup "$PWD/$cname"
	e2e_run "Clean $cname cluster files" "aba -d $cname clean"

	if [ -n "$vlan" ]; then
		e2e_run "Restore aba.conf machine_network ($_saved_aba_machine_network)" \
			"sed -i \"s#^machine_network=.*#machine_network=$_saved_aba_machine_network #g\" aba.conf"
		e2e_run "Restore aba.conf ntp_servers" \
			"aba --ntp $NTP_IP ntp.example.com"
	fi

	test_end
}

# ============================================================================
# 5-8. VLAN tests (vlan=123, guest-side tagging on br-lab)
# ============================================================================

_SNO_VLAN="$(pool_cluster_name kvm-sno-vlan)"
_COMPACT_VLAN="$(pool_cluster_name kvm-compact-vlan)"
_SNO="$(pool_cluster_name sno)"
_COMPACT="$(pool_cluster_name compact)"

# 5. VLAN SNO: single port
_kvm_net_test "VLAN SNO: single port" \
	sno "$_SNO_VLAN" 123 "enp1s0" "enp1s0.123@enp1s0:.*state UP"

# 6. VLAN SNO: bonding
_kvm_net_test "VLAN SNO: bonding" \
	sno "$_SNO_VLAN" 123 "enp1s0,enp2s0" "bond0.123@bond0:.*state UP"

# 7. VLAN compact: single port
_kvm_net_test "VLAN compact: single port" \
	compact "$_COMPACT_VLAN" 123 "enp1s0" "enp1s0.123@enp1s0:.*state UP"

# 8. VLAN compact: bonding
_kvm_net_test "VLAN compact: bonding" \
	compact "$_COMPACT_VLAN" 123 "enp1s0,enp2s0" "bond0.123@bond0:.*state UP"

# ============================================================================
# 9-10. Non-VLAN bonding tests (pool default network)
#       Single-port non-VLAN is already tested by kvm-lifecycle.
# ============================================================================

# 9. Non-VLAN SNO: bonding
_kvm_net_test "Non-VLAN SNO: bonding" \
	sno "$_SNO" "" "enp1s0,enp2s0" "bond0: .* state UP"

# 10. Non-VLAN compact: bonding
_kvm_net_test "Non-VLAN compact: bonding" \
	compact "$_COMPACT" "" "enp1s0,enp2s0" "bond0: .* state UP"

# ============================================================================
# 11. Cleanup
# ============================================================================
test_begin "Cleanup"

e2e_diag "Show remaining cluster dirs" "ls -d e2e-sno* e2e-compact* || echo 'none'"

for _cdir in $_SNO_VLAN $_COMPACT_VLAN $_SNO $_COMPACT; do
	e2e_run "Cleanup $_cdir" \
		"_e2e_delete_leftover_cluster $_cdir"
done

e2e_run "Unregister pool registry" \
	"aba -d mirror unregister"

test_end

# ============================================================================

suite_end; _rc=$?

exit $_rc
