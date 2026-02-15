#!/bin/bash
# =============================================================================
# Suite: VM clone lifecycle and internal bastion configuration (~15 min)
# =============================================================================
# Purpose: Quick validation of VM clone lifecycle and configuration code.
#          No images, no mirrors, no bundles, no clusters.
#          Tests govc connectivity, VM cloning from template, and the full
#          configure_internal_bastion() pipeline.
#
# What it tests:
#   - govc VMware connectivity (list VMs, verify template exists)
#   - VM clone: clone template -> dis1 (destroy old clone first)
#   - VM boot: power on, DHCP/DNS, wait for SSH
#   - configure_internal_bastion: SSH keys, time/NTP, dnf update, network,
#     firewall/NAT, cache cleanup, podman cleanup, RPM removal, proxy
#     removal, test user creation
#   - Verify the configured VM is usable (SSH, basic commands, user access)
#   - Cleanup: destroy the clone
#
# Prerequisites:
#   - ~/.vmware.conf must exist (govc config)
#   - Template VM (e.g. bastion-internal-rhel9) must exist in VMware
#   - Network connectivity to ESXi/vCenter and to the bastion VMs
#   - DHCP + DNS must resolve the clone's hostname
#
# Runtime: ~10-15 minutes (mostly dnf update + reboot)
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"

# --- Configuration ----------------------------------------------------------

TEMPLATE="${VM_TEMPLATES[${INTERNAL_BASTION_RHEL_VER:-rhel9}]:-bastion-internal-rhel9}"
CLONE_NAME="${CLONE_NAME:-dis1}"
CLONE_HOST="${CLONE_NAME}.${VM_BASE_DOMAIN:-example.com}"
DEF_USER="${VM_DEFAULT_USER:-steve}"
TEST_USER_NAME="${TEST_USER:-steve}"
VF="${VMWARE_CONF:-~/.vmware.conf}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Prereqs: govc and VMware connectivity" \
    "Clone: $TEMPLATE -> $CLONE_NAME" \
    "Boot: power on and wait for SSH" \
    "Configure: full internal bastion setup" \
    "Verify: SSH, users, network, firewall" \
    "Cleanup: destroy clone"

suite_begin "vm-smoke"

# ============================================================================
# 1. Prerequisites: govc works, VMware is reachable, template exists
# ============================================================================
test_begin "Prereqs: govc and VMware connectivity"

# Ensure we have aba installed (needed for govc download)
e2e_run -q "Install aba (if needed)" "./install"

# Copy vmware.conf so govc can authenticate
e2e_run "Copy vmware.conf" "cp -v $VF vmware.conf"
e2e_run -q "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

# Source vmware.conf to set GOVC_* env vars
source <(normalize-vmware-conf) || { echo "WARNING: normalize-vmware-conf failed" >&2; }
_e2e_log "GOVC vars loaded from vmware.conf"

# Install govc binary
e2e_run "Install govc" "aba --dir cli ~/bin/govc"

# Verify VMware connectivity and template existence
e2e_run "List VMs in vCenter" "govc ls vm"
e2e_run "Verify template VM exists: $TEMPLATE" "govc vm.info $TEMPLATE"

test_end

# ============================================================================
# 2. Clone: destroy old clone, clone template -> dis1
# ============================================================================
test_begin "Clone: $TEMPLATE -> $CLONE_NAME"

e2e_run "Clone VM from template" \
    "clone_vm $TEMPLATE $CLONE_NAME"

# Verify the clone was created
e2e_run "Verify clone exists" "govc vm.info $CLONE_NAME"

test_end

# ============================================================================
# 3. Boot: wait for SSH via DHCP/DNS
# ============================================================================
test_begin "Boot: power on and wait for SSH"

# Wait for SSH to come up (clone was powered on by clone_vm)
e2e_run "Wait for SSH on $DEF_USER@$CLONE_HOST" \
    "_vm_wait_ssh $CLONE_HOST $DEF_USER"

# Quick sanity checks
e2e_run "Verify SSH: hostname" "ssh -o StrictHostKeyChecking=no $DEF_USER@$CLONE_HOST hostname"
e2e_run "Verify SSH: date" "ssh $DEF_USER@$CLONE_HOST date"
e2e_run "Show OS version" "ssh $DEF_USER@$CLONE_HOST cat /etc/redhat-release"

test_end

# ============================================================================
# 4. Configure: run the full configure_internal_bastion pipeline
# ============================================================================
test_begin "Configure: full internal bastion setup"

# This is the main thing we're testing -- the full modular pipeline:
#   _vm_setup_ssh_keys  -> root SSH access
#   _vm_setup_time      -> chrony/NTP
#   _vm_dnf_update      -> dnf update + reboot
#   _vm_setup_network   -> VLAN, MTU
#   _vm_setup_firewall  -> firewalld + NAT masquerade
#   _vm_cleanup_caches  -> remove agent cache, oc-mirror cache
#   _vm_cleanup_podman  -> prune all containers/images
#   _vm_cleanup_home    -> wipe home directory
#   _vm_setup_vmware_conf -> copy vmware.conf
#   _vm_remove_rpms     -> remove git, make, jq, etc.
#   _vm_remove_pull_secret -> remove pull-secret
#   _vm_remove_proxy    -> disable proxy in .bashrc
#   _vm_create_test_user -> create 'testy' with SSH key + sudo

e2e_run "Run configure_internal_bastion" \
    "configure_internal_bastion $CLONE_HOST $DEF_USER $TEST_USER_NAME $CLONE_NAME"

test_end

# ============================================================================
# 5. Verify: check that everything was configured correctly
# ============================================================================
test_begin "Verify: SSH, users, network, firewall"

# Verify SSH as default user
e2e_run "SSH as $DEF_USER" \
    "ssh $DEF_USER@$CLONE_HOST whoami"

# Verify SSH as root
e2e_run "SSH as root" \
    "ssh root@$CLONE_HOST whoami"

# Verify testy user was created
e2e_run "SSH as testy" \
    "ssh -i ~/.ssh/testy_rsa testy@$CLONE_HOST whoami"
e2e_run "Verify testy has sudo" \
    "ssh -i ~/.ssh/testy_rsa testy@$CLONE_HOST sudo whoami | grep root"

# Verify NTP is configured
e2e_run "Verify chrony is running" \
    "ssh $DEF_USER@$CLONE_HOST systemctl is-active chronyd"
e2e_run "Show chrony sources" \
    "ssh $DEF_USER@$CLONE_HOST chronyc sources"

# Verify firewall is up with NAT
e2e_run "Verify firewalld is running" \
    "ssh $DEF_USER@$CLONE_HOST sudo systemctl is-active firewalld"
e2e_run "Show firewall rules" \
    "ssh $DEF_USER@$CLONE_HOST sudo firewall-cmd --list-all --zone=public"
e2e_run "Verify IP forwarding" \
    "ssh $DEF_USER@$CLONE_HOST cat /proc/sys/net/ipv4/ip_forward | grep 1"

# Verify network (VLAN interface should exist)
e2e_run "Show network interfaces" \
    "ssh $DEF_USER@$CLONE_HOST ip -br addr"

# Verify RPMs were removed (git should NOT be installed)
e2e_run "Verify git is NOT installed" \
    "ssh $DEF_USER@$CLONE_HOST '! which git 2>/dev/null'"

# Verify pull-secret was removed
e2e_run "Verify pull-secret removed" \
    "ssh $DEF_USER@$CLONE_HOST '! test -f ~/.pull-secret.json'"

# Verify proxy was disabled
e2e_run "Verify proxy disabled in .bashrc" \
    "ssh $DEF_USER@$CLONE_HOST 'grep -q \"aba-test.*proxy\" ~/.bashrc || ! grep -q \"source.*proxy-set\" ~/.bashrc'"

# Verify vmware.conf was copied
e2e_run "Verify vmware.conf on VM" \
    "ssh $DEF_USER@$CLONE_HOST 'test -s ~/.vmware.conf'"

test_end

# ============================================================================
# 6. Cleanup: destroy the clone
# ============================================================================
test_begin "Cleanup: destroy clone"

e2e_run "Destroy clone $CLONE_NAME" \
    "destroy_vm $CLONE_NAME"

# Verify it's gone
e2e_run "Verify clone destroyed" \
    "! govc vm.info $CLONE_NAME 2>/dev/null"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-vm-smoke.sh"
