#!/bin/bash
# =============================================================================
# Suite: Network Advanced (VLAN + bonding matrix)
# =============================================================================
# Purpose: VLAN and bonding network configuration tests for all cluster types.
#          Uses the pre-populated Quay registry on conN (no save/load needed).
#
# Test matrix:
#   for vlan in 10 ""; do
#     for ctype in sno compact standard; do
#       1. Single port (ports=ens160, vlan=$vlan) -- ISO, boot, verify ens160 UP
#       2. Bonding + balance-xor (ports=ens160,ens192,ens224, vlan=$vlan)
#          -- agent-config.yaml, sed balance-xor, ISO, boot, verify bond0 UP
#     done
#   done
#
# VLAN tests use GOVC_NETWORK=PRIVATE-DPG (VLAN-capable port group).
# Non-VLAN tests use GOVC_NETWORK=VMNET-DPG (regular lab network).
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

CON_HOST="con${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
DIS_HOST="dis${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"
POOL_REG_DIR="$HOME/.e2e-pool-registry"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba and configure" \
    "Setup: configure mirror for local registry" \
    "VLAN: verify interface" \
    "VLAN SNO: single port" \
    "VLAN SNO: bonding" \
    "VLAN compact: single port" \
    "VLAN compact: bonding" \
    "VLAN standard: single port" \
    "VLAN standard: bonding" \
    "Non-VLAN SNO: bonding" \
    "Non-VLAN compact: bonding" \
    "Non-VLAN standard: bonding" \
    "Cleanup"

suite_begin "network-advanced"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_run "Install aba (needed for version resolution)" "./install"
e2e_run "Configure aba.conf (temporary, for version resolution)" \
    "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_run "Remove RPMs for clean install test" \
    "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y"
e2e_run "Remove oc-mirror caches" \
    "sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rfv"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"

# Simulate manual edit: override dns_servers to point to pool dnsmasq
e2e_run "Set dns_servers via sed" \
    "sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

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

e2e_run "Create regcreds directory" "mkdir -p mirror/regcreds"
e2e_run "Copy Quay root CA to regcreds" \
    "cp -v ~/quay-install/quay-rootCA/rootCA.pem mirror/regcreds/"

e2e_run "Generate mirror pull secret" \
    "enc_pw=\$(echo -n 'init:p4ssw0rd' | base64 -w0) && cat > mirror/regcreds/pull-secret-mirror.json <<EOPS
{
  \"auths\": {
    \"${CON_HOST}:8443\": {
      \"auth\": \"\$enc_pw\"
    }
  }
}
EOPS"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

e2e_run "Link oc-mirror working-dir" \
    "mkdir -p mirror/sync && ln -sfn ${POOL_REG_DIR}/sync/working-dir mirror/sync/working-dir"

e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

test_end

# ============================================================================
# 4. VLAN: verify interface on bastion
# ============================================================================
test_begin "VLAN: verify interface"

e2e_run_remote "Verify VLAN interface ens224.10 exists on disN" \
    "ip addr show ens224.10"
e2e_run_remote "Verify VLAN IP $(pool_vlan_gateway) on disN" \
    "ip addr show ens224.10 | grep '$(pool_vlan_gateway)'"

test_end

# ============================================================================
# Helper: run a single network config test (single-port or bonding)
# ============================================================================
# Usage: _net_test LABEL CTYPE CNAME VLAN PORTS IF_CHECK
#
#   LABEL       = test_begin label (e.g. "VLAN SNO: single port")
#   CTYPE       = sno | compact | standard
#   CNAME       = cluster directory name (e.g. sno-vlan, compact, standard)
#   VLAN        = VLAN tag (e.g. 10) or "" for no VLAN
#   PORTS       = ports= value (e.g. "ens160" or "ens160,ens192,ens224")
#   IF_CHECK    = interface pattern to verify (e.g. "ens160:.*state UP" or "bond0:.*state UP")
#
_net_test() {
    local label="$1"
    local ctype="$2"
    local cname="$3"
    local vlan="$4"
    local ports="$5"
    local if_check="$6"

    local govc_network machine_network next_hop start_ip
    local _saved_aba_machine_network
    _saved_aba_machine_network="$(pool_machine_network)"

    if [ -n "$vlan" ]; then
        govc_network="PRIVATE-DPG"
        machine_network="$(pool_vlan_network)"
        next_hop="$(pool_vlan_gateway)"
        start_ip="$(pool_vlan_node_ip)"
    else
        govc_network="VMNET-DPG"
        machine_network="$(pool_machine_network)"
        next_hop="10.0.1.1"
        start_ip="$(pool_node_ip)"
    fi

    test_begin "$label"

    e2e_run "Set GOVC_NETWORK=$govc_network" \
        "sed -i 's/^.*GOVC_NETWORK=.*/GOVC_NETWORK=$govc_network /g' vmware.conf"

    if [ -n "$vlan" ]; then
        # aba validates starting_ip against aba.conf's machine_network during iso/refresh
        e2e_run "Set aba.conf machine_network for VLAN ($machine_network)" \
            "sed -i \"s#^machine_network=.*#machine_network=$machine_network #g\" aba.conf"
    fi

    e2e_run "Clean $cname dir" "rm -rfv $cname"

    e2e_run "Generate cluster.conf for $cname" \
        "aba cluster -n $cname -t $ctype --starting-ip $start_ip --step cluster.conf"

    e2e_run "Set machine_network=$machine_network" \
        "sed -i \"s#^machine_network=.*#machine_network=$machine_network #g\" $cname/cluster.conf"
    e2e_run "Set next_hop_address=$next_hop" \
        "sed -i \"s/^.*next_hop_address=.*/next_hop_address=$next_hop /g\" $cname/cluster.conf"

    if [ -n "$vlan" ] && [ "$ctype" != "sno" ]; then
        local _vlan_api_vip _vlan_apps_vip
        _vlan_api_vip="$(pool_vlan_api_vip)"
        _vlan_apps_vip="$(pool_vlan_apps_vip)"
        e2e_run "Set VLAN api_ip=$_vlan_api_vip" \
            "sed -i \"s/^api_ip=.*/api_ip=$_vlan_api_vip /g\" $cname/cluster.conf"
        e2e_run "Set VLAN ingress_ip=$_vlan_apps_vip" \
            "sed -i \"s/^ingress_ip=.*/ingress_ip=$_vlan_apps_vip /g\" $cname/cluster.conf"
    fi

    e2e_run "Set ports=$ports" \
        "sed -i 's/^.*ports=.*/ports=$ports /g' $cname/cluster.conf"

    e2e_run "Set vlan=$vlan" \
        "sed -i \"s/^.*vlan=.*/vlan=$vlan /g\" $cname/cluster.conf"

    if [ -n "$vlan" ]; then
        local _vlan_dns
        _vlan_dns="$(pool_vlan_dns)"
        e2e_run "Set VLAN dns_servers=$_vlan_dns (reachable from VLAN network)" \
            "sed -i \"s/^dns_servers=.*/dns_servers=$_vlan_dns /g\" $cname/cluster.conf"
    fi

    e2e_diag "Show cluster.conf" \
        "grep -e ^vlan= -e ^ports= -e ^port1= $cname/cluster.conf | awk '{print \$1}'"

    e2e_run "Create ISO for $cname" "aba --dir $cname iso"
    e2e_run "Upload ISO for $cname" "aba --dir $cname upload"
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
        "timeout 8m bash -c 'until aba --dir $cname ssh --cmd \"chronyc sources\" | grep ${NTP_IP}; do sleep 10; done'"

    e2e_run "Delete $cname VMs" "aba --dir $cname delete"
    e2e_run "Clean $cname dir" "aba -d $cname clean"

    if [ -n "$vlan" ]; then
        e2e_run "Restore aba.conf machine_network ($_saved_aba_machine_network)" \
            "sed -i \"s#^machine_network=.*#machine_network=$_saved_aba_machine_network #g\" aba.conf"
    fi

    test_end
}

# ============================================================================
# 5-10. VLAN tests (GOVC_NETWORK=PRIVATE-DPG)
# ============================================================================

# Pool-unique cluster names
_SNO_VLAN="$(pool_cluster_name sno-vlan)"
_COMPACT_VLAN="$(pool_cluster_name compact-vlan)"
_STANDARD_VLAN="$(pool_cluster_name standard-vlan)"
_SNO="$(pool_cluster_name sno)"
_COMPACT="$(pool_cluster_name compact)"
_STANDARD="$(pool_cluster_name standard)"

# 5. VLAN SNO: single port
_net_test "VLAN SNO: single port" \
    sno "$_SNO_VLAN" 10 "ens160" "ens160: .*state UP"

# 6. VLAN SNO: bonding
_net_test "VLAN SNO: bonding" \
    sno "$_SNO_VLAN" 10 "ens160,ens192,ens224" "bond0: .* state UP"

# 7. VLAN compact: single port
_net_test "VLAN compact: single port" \
    compact "$_COMPACT_VLAN" 10 "ens160" "ens160: .*state UP"

# 8. VLAN compact: bonding
_net_test "VLAN compact: bonding" \
    compact "$_COMPACT_VLAN" 10 "ens160,ens192,ens224" "bond0: .* state UP"

# 9. VLAN standard: single port
_net_test "VLAN standard: single port" \
    standard "$_STANDARD_VLAN" 10 "ens160" "ens160: .*state UP"

# 10. VLAN standard: bonding
_net_test "VLAN standard: bonding" \
    standard "$_STANDARD_VLAN" 10 "ens160,ens192,ens224" "bond0: .* state UP"

# ============================================================================
# 11-13. Non-VLAN bonding tests (GOVC_NETWORK=VMNET-DPG)
#         Single-port non-VLAN is already tested by cluster-ops/mirror-sync suites.
# ============================================================================

# 11. Non-VLAN SNO: bonding
_net_test "Non-VLAN SNO: bonding" \
    sno "$_SNO" "" "ens160,ens192,ens224" "bond0: .* state UP"

# 12. Non-VLAN compact: bonding
_net_test "Non-VLAN compact: bonding" \
    compact "$_COMPACT" "" "ens160,ens192,ens224" "bond0: .* state UP"

# 13. Non-VLAN standard: bonding
_net_test "Non-VLAN standard: bonding" \
    standard "$_STANDARD" "" "ens160,ens192,ens224" "bond0: .* state UP"

# ============================================================================
# 14. Cleanup
# ============================================================================
test_begin "Cleanup"

e2e_diag "Show remaining cluster dirs" "ls -d sno* compact* standard* 2>/dev/null || echo 'none'"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-network-advanced.sh"
