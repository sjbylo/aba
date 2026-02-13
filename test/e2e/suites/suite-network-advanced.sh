#!/bin/bash
# =============================================================================
# Suite: Network Advanced (new, extracted from test2/test5)
# =============================================================================
# Purpose: VLAN and bonding network configuration tests. These are separated
#          because they need special infra (VLAN-capable switches) and are slow.
#
# Extracted from test2 (VLAN/bonding sections) and test5 (network-related).
# =============================================================================

set -euo pipefail

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
    "VLAN: install SNO cluster on VLAN" \
    "VLAN: verify cluster" \
    "Bonding: install SNO with bond0" \
    "Bonding: verify cluster" \
    "Cleanup"

suite_begin "network-advanced"

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch --platform vmw --op-sets abatest

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l}"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror host" \
    "sed -i 's/registry.example.com/${DIS_HOST} /g' ./mirror/mirror.conf"

test_end 0

# ============================================================================
# 2. Reset internal bastion (reuse clone-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end 0

# ============================================================================
# 3. Save, transfer, and load images
# ============================================================================
test_begin "Setup: save and load images"

e2e_run -r 15 3 "Save images" "aba -d mirror save --retry"
e2e_run -r 3 3 "Transfer to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'mkdir -p ~/aba && cd ~/aba && tar xf -'"
e2e_run_remote "Install aba on bastion" \
    "cd ~/aba && ./install"
e2e_run_remote "Install registry" \
    "cd ~/aba && aba -d mirror install"
e2e_run_remote -r 15 3 "Load images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 4. VLAN: verify interface on bastion
# ============================================================================
test_begin "VLAN: verify interface on bastion"

e2e_run_remote "Verify VLAN interface ens224.10 exists" \
    "ip addr show ens224.10"
e2e_run_remote "Verify VLAN IP 10.10.10.1" \
    "ip addr show ens224.10 | grep '10.10.10.1'"
e2e_run_remote "Check VLAN connection details" \
    "nmcli -f GENERAL,IP4 connection show ens224.10"

test_end 0

# ============================================================================
# 5. VLAN: install SNO cluster on VLAN network
# ============================================================================
test_begin "VLAN: install SNO cluster on VLAN"

e2e_run_remote "Clean sno dir" "cd ~/aba && rm -rf sno"

# Create SNO on VLAN network (10.10.10.x)
e2e_run_remote "Create SNO config for VLAN" \
    "cd ~/aba && aba cluster -n sno -t sno --starting-ip 10.10.10.201 --machine-network '10.10.10.0/24' --gateway-ip 10.10.10.1 --dns 10.0.1.8 --step cluster.conf"

# Configure VLAN in cluster.conf
e2e_run_remote "Set VLAN config in cluster.conf" \
    "cd ~/aba && sed -i 's/^#vlan_id=.*/vlan_id=10/' sno/cluster.conf 2>/dev/null || echo 'vlan_id=10' >> sno/cluster.conf"

e2e_run_remote "Install SNO on VLAN" \
    "cd ~/aba && aba --dir sno install"

test_end 0

# ============================================================================
# 6. VLAN: verify cluster
# ============================================================================
test_begin "VLAN: verify cluster"

e2e_run_remote "Verify VLAN cluster operators" \
    "cd ~/aba && aba --dir sno run"
e2e_run_remote "Check cluster operators" \
    "cd ~/aba && aba --dir sno cmd 'oc get co'"

# Cleanup VLAN cluster
e2e_run_remote -i "Delete VLAN SNO" \
    "cd ~/aba && aba --dir sno delete || true"
e2e_run_remote "Clean sno dir" "cd ~/aba && rm -rf sno"

test_end 0

# ============================================================================
# 7. Bonding: install SNO with bond0
# ============================================================================
test_begin "Bonding: install SNO with bond0"

# Create cluster with bonding configuration
e2e_run_remote "Create SNO config for bonding" \
    "cd ~/aba && aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

# Configure bonding in cluster.conf
e2e_run_remote "Set bond config in cluster.conf" \
    "cd ~/aba && echo 'bond=bond0' >> sno/cluster.conf 2>/dev/null || true"

e2e_run_remote "Install SNO with bonding" \
    "cd ~/aba && aba --dir sno install"

test_end 0

# ============================================================================
# 8. Bonding: verify cluster
# ============================================================================
test_begin "Bonding: verify cluster"

e2e_run_remote "Verify bonded cluster operators" \
    "cd ~/aba && aba --dir sno run"
e2e_run_remote "Check cluster operators" \
    "cd ~/aba && aba --dir sno cmd 'oc get co'"

# Cleanup bonding cluster
e2e_run_remote -i "Delete bonding SNO" \
    "cd ~/aba && aba --dir sno delete || true"

test_end 0

# ============================================================================
# 9. Cleanup
# ============================================================================
test_begin "Cleanup"

e2e_run_remote -i "Uninstall registry" \
    "cd ~/aba && aba -d mirror uninstall || true"
e2e_run_remote -i "Shutdown cluster if running" \
    "cd ~/aba && yes | aba --dir sno shutdown --wait 2>/dev/null || true"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-network-advanced.sh"
