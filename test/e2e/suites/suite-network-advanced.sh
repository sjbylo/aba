#!/bin/bash
# =============================================================================
# Suite: Network Advanced (new, extracted from test2/test5)
# =============================================================================
# Purpose: VLAN and bonding network configuration tests. These are separated
#          because they need special infra (VLAN-capable switches) and are slow.
#
# Extracted from test2 (VLAN/bonding sections) and test5 (network-related).
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
    "VLAN SNO: boot and verify interface" \
    "VLAN compact: boot and verify interface" \
    "Bonding SNO: boot and verify bond0" \
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
# 5. VLAN SNO: boot and verify interface (no full install -- just SSH check)
#    Creates ISO, boots VM, waits for SSH, checks ens160 is UP on VLAN.
#    Saves ~40 min by not waiting for full cluster install.
# ============================================================================
test_begin "VLAN SNO: boot and verify interface"

e2e_run_remote "Clean sno dir" "cd ~/aba && rm -rf sno"

# Create SNO on VLAN network
e2e_run_remote "Create SNO config for VLAN" \
    "cd ~/aba && aba cluster -n sno -t sno --starting-ip $(pool_vlan_node_ip) --machine-network '$(pool_vlan_network)' --gateway-ip $(pool_vlan_gateway) --dns $(pool_dns_server) --step cluster.conf"

# Configure VLAN in cluster.conf
e2e_run_remote "Set VLAN and ports in cluster.conf" \
    "cd ~/aba && grep -q '^#\\?vlan_id=' sno/cluster.conf && sed -i 's/^#\\?vlan_id=.*/vlan_id=10/' sno/cluster.conf || echo 'vlan_id=10' >> sno/cluster.conf; grep -q '^.*ports=' sno/cluster.conf && sed -i 's/^.*ports=.*/ports=ens160/' sno/cluster.conf || echo 'ports=ens160' >> sno/cluster.conf"

# Generate ISO, upload to VMware, and boot VMs (but don't wait for full install)
e2e_run_remote "Create ISO" "cd ~/aba && aba --dir sno iso"
e2e_run_remote "Upload ISO to VMware" "cd ~/aba && aba --dir sno upload"
e2e_run_remote "Boot VMs" "cd ~/aba && aba --dir sno refresh"

# Wait for node to be SSH-reachable, then check network interface
e2e_run_remote -r 1 1 "Wait for node0 SSH (VLAN)" \
    "cd ~/aba && timeout 8m bash -c 'until aba --dir sno ssh --cmd hostname; do sleep 10; done'"
e2e_run_remote "Verify ens160 is UP on VLAN" \
    "cd ~/aba && aba --dir sno ssh --cmd 'ip a' | grep 'ens160:.*state UP'"
e2e_run_remote "Verify NTP on VLAN node" \
    "cd ~/aba && timeout 8m bash -c 'until aba --dir sno ssh --cmd \"chronyc sources\" | grep ${NTP_IP}; do sleep 10; done'"

# Cleanup: delete VMs, clean dir
# -i: VMs may not exist if boot failed
e2e_run_remote -i "Delete VLAN SNO VMs" \
    "cd ~/aba && aba --dir sno delete"
e2e_run_remote "Clean sno dir" "cd ~/aba && rm -rf sno"

test_end

# ============================================================================
# 6. VLAN compact: boot and verify interface (multi-node VLAN test)
#    Same approach: ISO + boot + SSH check. No full cluster install.
# ============================================================================
test_begin "VLAN compact: boot and verify interface"

e2e_run_remote "Clean compact dir" "cd ~/aba && rm -rf compact"

# Create compact on VLAN network (3 master/worker combo nodes)
e2e_run_remote "Create compact config for VLAN" \
    "cd ~/aba && aba cluster -n compact -t compact --starting-ip $(pool_vlan_node_ip) --machine-network '$(pool_vlan_network)' --gateway-ip $(pool_vlan_gateway) --dns $(pool_dns_server) --step cluster.conf"

# Configure VLAN in cluster.conf
e2e_run_remote "Set VLAN and ports in compact cluster.conf" \
    "cd ~/aba && grep -q '^#\\?vlan_id=' compact/cluster.conf && sed -i 's/^#\\?vlan_id=.*/vlan_id=10/' compact/cluster.conf || echo 'vlan_id=10' >> compact/cluster.conf; grep -q '^.*ports=' compact/cluster.conf && sed -i 's/^.*ports=.*/ports=ens160/' compact/cluster.conf || echo 'ports=ens160' >> compact/cluster.conf"

# Generate ISO, upload, and boot VMs
e2e_run_remote "Create ISO" "cd ~/aba && aba --dir compact iso"
e2e_run_remote "Upload ISO to VMware" "cd ~/aba && aba --dir compact upload"
e2e_run_remote "Boot VMs" "cd ~/aba && aba --dir compact refresh"

# Wait for first node (node0) SSH, then check network
e2e_run_remote -r 1 1 "Wait for node0 SSH (compact VLAN)" \
    "cd ~/aba && timeout 8m bash -c 'until aba --dir compact ssh --cmd hostname; do sleep 10; done'"
e2e_run_remote "Verify ens160 is UP on compact VLAN node" \
    "cd ~/aba && aba --dir compact ssh --cmd 'ip a' | grep 'ens160:.*state UP'"

# Cleanup
# -i: VMs may not exist if boot failed
e2e_run_remote -i "Delete VLAN compact VMs" \
    "cd ~/aba && aba --dir compact delete"
e2e_run_remote "Clean compact dir" "cd ~/aba && rm -rf compact"

test_end

# ============================================================================
# 7. Bonding SNO: boot and verify bond0 (no full install -- just SSH check)
#    Creates ISO with bonding config, boots VM, checks bond0 is UP.
# ============================================================================
test_begin "Bonding SNO: boot and verify bond0"

e2e_run_remote "Clean sno dir" "cd ~/aba && rm -rf sno"

# Create cluster with bonding configuration
e2e_run_remote "Create SNO config for bonding" \
    "cd ~/aba && aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

# Configure bonding: multiple ports + bond name
e2e_run_remote "Set bonding in cluster.conf" \
    "cd ~/aba && grep -q '^.*ports=' sno/cluster.conf && sed -i 's/^.*ports=.*/ports=ens160,ens192,ens224/' sno/cluster.conf || echo 'ports=ens160,ens192,ens224' >> sno/cluster.conf; echo 'bond=bond0' >> sno/cluster.conf"

# Generate ISO, upload, and boot VMs
e2e_run_remote "Create ISO" "cd ~/aba && aba --dir sno iso"
e2e_run_remote "Upload ISO to VMware" "cd ~/aba && aba --dir sno upload"
e2e_run_remote "Boot VMs" "cd ~/aba && aba --dir sno refresh"

# Wait for node SSH, then check bond0 interface
e2e_run_remote -r 1 1 "Wait for node0 SSH (bonding)" \
    "cd ~/aba && timeout 8m bash -c 'until aba --dir sno ssh --cmd hostname; do sleep 10; done'"
# Wait a bit for bonding to fully come up
e2e_run -q "Wait for bond0 to settle" "sleep 30"
e2e_run_remote "Show ip a output" \
    "cd ~/aba && aba --dir sno ssh --cmd 'ip a'"
e2e_run_remote "Verify bond0 is UP" \
    "cd ~/aba && aba --dir sno ssh --cmd 'ip a' | grep 'bond0:.*state UP'"
e2e_run_remote "Verify NTP on bonded node" \
    "cd ~/aba && timeout 8m bash -c 'until aba --dir sno ssh --cmd \"chronyc sources\" | grep ${NTP_IP}; do sleep 10; done'"

# Cleanup
# -i: VMs may not exist if boot failed
e2e_run_remote -i "Delete bonding SNO VMs" \
    "cd ~/aba && aba --dir sno delete"
e2e_run_remote "Clean sno dir" "cd ~/aba && rm -rf sno"

test_end

# ============================================================================
# 8. Cleanup
# ============================================================================
test_begin "Cleanup"

# -i: registry may not be installed if earlier steps failed
e2e_run_remote -i "Uninstall registry" \
    "cd ~/aba && aba -d mirror uninstall"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-network-advanced.sh"
