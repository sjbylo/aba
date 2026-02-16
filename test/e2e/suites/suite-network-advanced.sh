#!/bin/bash
# =============================================================================
# Suite: Network Advanced (VLAN + bonding matrix)
# =============================================================================
# Purpose: VLAN and bonding network configuration tests for all cluster types.
#          Replicates the old test2 VLAN/bonding matrix using the E2E framework.
#
# Test matrix (matching old test2-airgapped-existing-reg.sh):
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
# L commands run on conN (this host). R commands SSH to disN.

DIS_HOST="dis${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Setup: reset internal bastion" \
    "Setup: save and load images" \
    "VLAN: verify interface on bastion" \
    "VLAN SNO: single port" \
    "VLAN SNO: bonding + balance-xor" \
    "VLAN compact: single port" \
    "VLAN compact: bonding + balance-xor" \
    "VLAN standard: single port" \
    "VLAN standard: bonding + balance-xor" \
    "Non-VLAN SNO: bonding + balance-xor" \
    "Non-VLAN compact: bonding + balance-xor" \
    "Non-VLAN standard: bonding + balance-xor" \
    "Cleanup"

suite_begin "network-advanced"

# Pre-flight: abort immediately if the internal bastion (disN) is unreachable
preflight_ssh

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l} --base-domain $(pool_domain)"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror host" \
    "sed -i 's/registry.example.com/${DIS_HOST} /g' ./mirror/mirror.conf"

test_end

# ============================================================================
# 2. Reset internal bastion (reuse clone-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end

# ============================================================================
# 3. Save, transfer, and load images
# ============================================================================
test_begin "Setup: save and load images"

e2e_run -r 3 2 "Save images" "aba -d mirror save --retry"
e2e_run -r 3 2 "Transfer to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'mkdir -p ~/aba && cd ~/aba && tar xf -'"
e2e_run_remote "Install aba on bastion" \
    "cd ~/aba && ./install"
e2e_run_remote "Install registry" \
    "cd ~/aba && aba -d mirror install"
e2e_run_remote -r 3 2 "Load images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 4. VLAN: verify interface on bastion
# ============================================================================
test_begin "VLAN: verify interface on bastion"

e2e_run_remote "Verify VLAN interface ens224.10 exists" \
    "ip addr show ens224.10"
e2e_run_remote "Verify VLAN IP $(pool_vlan_gateway)" \
    "ip addr show ens224.10 | grep '$(pool_vlan_gateway)'"
e2e_run_remote "Check VLAN connection details" \
    "nmcli -f GENERAL,IP4 connection show ens224.10"

test_end

# ============================================================================
# Helper: run a single network config test (single-port or bonding)
# ============================================================================
# Usage: _net_test LABEL CTYPE CNAME VLAN PORTS IF_CHECK [BALANCE_XOR]
#
#   LABEL       = test_begin label (e.g. "VLAN SNO: single port")
#   CTYPE       = sno | compact | standard
#   CNAME       = cluster directory name (e.g. sno-vlan, compact, standard)
#   VLAN        = VLAN tag (e.g. 10) or "" for no VLAN
#   PORTS       = ports= value (e.g. "ens160" or "ens160,ens192,ens224")
#   IF_CHECK    = interface pattern to verify (e.g. "ens160:.*state UP" or "bond0:.*state UP")
#   BALANCE_XOR = "yes" to set balance-xor bonding mode (optional, default "no")
#
_net_test() {
    local label="$1"
    local ctype="$2"
    local cname="$3"
    local vlan="$4"
    local ports="$5"
    local if_check="$6"
    local balance_xor="${7:-no}"

    # Determine network parameters based on VLAN
    local govc_network machine_network next_hop start_ip
    if [ -n "$vlan" ]; then
        govc_network="PRIVATE-DPG"
        machine_network="$(pool_vlan_network)"
        next_hop="$(pool_vlan_gateway)"
        case "$ctype" in
            sno)      start_ip="$(pool_vlan_node_ip)" ;;
            compact)  start_ip="$(pool_vlan_node_ip)" ;;
            standard) start_ip="$(pool_vlan_node_ip)" ;;
        esac
    else
        govc_network="VMNET-DPG"
        machine_network="$(pool_machine_network)"
        next_hop="10.0.1.1"
        start_ip="$(pool_node_ip)"
    fi

    test_begin "$label"

    # Switch GOVC_NETWORK on disN
    e2e_run_remote "Set GOVC_NETWORK=$govc_network" \
        "cd ~/aba && sed -i 's/^.*GOVC_NETWORK=.*/GOVC_NETWORK=$govc_network /g' vmware.conf"

    # Clean previous cluster dir
    e2e_run_remote "Clean $cname dir" "cd ~/aba && rm -rfv $cname"

    # Generate cluster.conf
    e2e_run_remote "Generate cluster.conf for $cname" \
        "cd ~/aba && aba cluster -n $cname -t $ctype --starting-ip $start_ip --step cluster.conf"

    # Set machine_network and next_hop_address
    e2e_run_remote "Set machine_network=$machine_network" \
        "cd ~/aba && sed -i \"s#^machine_network=.*#machine_network=$machine_network #g\" $cname/cluster.conf"
    e2e_run_remote "Set next_hop_address=$next_hop" \
        "cd ~/aba && sed -i \"s/^.*next_hop_address=.*/next_hop_address=$next_hop /g\" $cname/cluster.conf"

    # Set ports
    e2e_run_remote "Set ports=$ports" \
        "cd ~/aba && sed -i 's/^.*ports=.*/ports=$ports /g' $cname/cluster.conf"

    # Set vlan (empty string clears it)
    e2e_run_remote "Set vlan=$vlan" \
        "cd ~/aba && sed -i \"s/^.*vlan=.*/vlan=$vlan /g\" $cname/cluster.conf"

    # Show config for debugging
    e2e_diag_remote "Show cluster.conf" \
        "cd ~/aba && grep -e ^vlan= -e ^ports= -e ^port1= $cname/cluster.conf | awk '{print \$1}'"

    # For bonding with balance-xor: generate agent-config.yaml first, then edit mode
    if [ "$balance_xor" = "yes" ]; then
        e2e_run_remote "Generate agent-config.yaml" \
            "cd ~/aba && aba --dir $cname agent-config.yaml"
        e2e_run_remote "Set bonding mode to balance-xor" \
            "cd ~/aba && sed -i 's/mode: active-backup/mode: balance-xor/g' $cname/agent-config.yaml"
    fi

    # Create ISO, upload, boot
    e2e_run_remote "Create ISO for $cname" "cd ~/aba && aba --dir $cname iso"
    e2e_run_remote "Upload ISO for $cname" "cd ~/aba && aba --dir $cname upload"
    e2e_run_remote "Boot VMs for $cname" "cd ~/aba && aba --dir $cname refresh"

    # Wait for node SSH
    e2e_run_remote -r 1 1 "Wait for node0 SSH ($cname)" \
        "cd ~/aba && timeout 8m bash -c 'until aba --dir $cname ssh --cmd hostname; do sleep 10; done'"

    # For bonding, wait for bond to settle
    if echo "$if_check" | grep -q bond0; then
        e2e_run -q "Wait for bond0 to settle" "sleep 30"
    fi

    # Show ip a for debugging
    e2e_diag_remote "Show ip a on $cname node" \
        "cd ~/aba && aba --dir $cname ssh --cmd 'ip a'"

    # Verify expected interface is UP
    e2e_run_remote "Verify $if_check on $cname" \
        "cd ~/aba && timeout 8m bash -c 'until aba --dir $cname ssh --cmd \"ip a\" | grep \"$if_check\"; do sleep 10; done'"

    # Verify NTP
    e2e_run_remote "Verify NTP on $cname" \
        "cd ~/aba && timeout 8m bash -c 'until aba --dir $cname ssh --cmd \"chronyc sources\" | grep ${NTP_IP}; do sleep 10; done'"

    # Cleanup: delete VMs, clean dir
    e2e_run_remote "Delete $cname VMs" \
        "cd ~/aba && aba --dir $cname delete"
    e2e_run_remote "Clean $cname dir" "cd ~/aba && aba -d $cname clean"

    test_end
}

# ============================================================================
# 5-10. VLAN tests (GOVC_NETWORK=PRIVATE-DPG)
# ============================================================================

# 5. VLAN SNO: single port
_net_test "VLAN SNO: single port" \
    sno sno-vlan 10 "ens160" "ens160: .*state UP"

# 6. VLAN SNO: bonding + balance-xor
_net_test "VLAN SNO: bonding + balance-xor" \
    sno sno-vlan 10 "ens160,ens192,ens224" "bond0: .* state UP" yes

# 7. VLAN compact: single port
_net_test "VLAN compact: single port" \
    compact compact-vlan 10 "ens160" "ens160: .*state UP"

# 8. VLAN compact: bonding + balance-xor
_net_test "VLAN compact: bonding + balance-xor" \
    compact compact-vlan 10 "ens160,ens192,ens224" "bond0: .* state UP" yes

# 9. VLAN standard: single port
_net_test "VLAN standard: single port" \
    standard standard-vlan 10 "ens160" "ens160: .*state UP"

# 10. VLAN standard: bonding + balance-xor
_net_test "VLAN standard: bonding + balance-xor" \
    standard standard-vlan 10 "ens160,ens192,ens224" "bond0: .* state UP" yes

# ============================================================================
# 11-13. Non-VLAN bonding tests (GOVC_NETWORK=VMNET-DPG)
#         Single-port non-VLAN is already tested by connected-sync suite.
# ============================================================================

# 11. Non-VLAN SNO: bonding + balance-xor
_net_test "Non-VLAN SNO: bonding + balance-xor" \
    sno sno "" "ens160,ens192,ens224" "bond0: .* state UP" yes

# 12. Non-VLAN compact: bonding + balance-xor
_net_test "Non-VLAN compact: bonding + balance-xor" \
    compact compact "" "ens160,ens192,ens224" "bond0: .* state UP" yes

# 13. Non-VLAN standard: bonding + balance-xor
_net_test "Non-VLAN standard: bonding + balance-xor" \
    standard standard "" "ens160,ens192,ens224" "bond0: .* state UP" yes

# ============================================================================
# 14. Cleanup
# ============================================================================
test_begin "Cleanup"

e2e_run_remote "Uninstall registry" \
    "cd ~/aba && aba -d mirror uninstall"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-network-advanced.sh"
