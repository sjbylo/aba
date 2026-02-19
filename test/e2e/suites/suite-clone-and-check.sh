#!/bin/bash
# =============================================================================
# Suite: Clone and configure pool VMs (coordinator-only, needs govc)
# =============================================================================
# Purpose: Clone pool VMs, configure them fully, and verify everything.
#          con# = connected bastion (internet gateway via masquerade)
#          dis# = disconnected bastion (air-gapped, internet via con# VLAN)
#
# Configuration pipeline (order matters for dependencies):
#   Both:  SSH keys, network (role-aware), NTP/time, cleanup, test user
#   con#:  firewall/masquerade (before NTP so dis# can reach NTP), vmware.conf, install aba
#   dis#:  remove RPMs, remove pull-secret, remove proxy
#
# VMware NICs:
#   ethernet-0 / ens192 = VMNET-DPG      (private lab, DHCP)
#   ethernet-1 / ens224 = PRIVATE-DPG    (VLAN, static IP)
#   ethernet-2 / ens256 = VMNET-EXT-DPG  (internet, DHCP)
#
# Usage:
#   test/e2e/run.sh --suite clone-and-check
#   POOL_NUM=2 test/e2e/run.sh --suite clone-and-check
# =============================================================================

set -u

E2E_COORDINATOR_ONLY=true  # Must run on coordinator (creates VMs, needs govc)

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"

# --- Configuration ----------------------------------------------------------

TEMPLATE="${VM_TEMPLATES[${INT_BASTION_RHEL_VER:-rhel8}]:-bastion-internal-rhel8}"
POOL_NUM="${POOL_NUM:-1}"
CON_NAME="con${POOL_NUM}"
DIS_NAME="dis${POOL_NUM}"
CON_HOST="${CON_NAME}.${VM_BASE_DOMAIN:-example.com}"
DIS_HOST="${DIS_NAME}.${VM_BASE_DOMAIN:-example.com}"
DEF_USER="${VM_DEFAULT_USER:-steve}"
VF="${VMWARE_CONF:-~/.vmware.conf}"

# --- Helper: clone one VM with MACs, no power on ---------------------------

clone_with_macs() {
    local clone="$1"

    # VM may not exist on first run -- check before attempting destroy
    e2e_run -q "Destroy old $clone (if exists)" \
        "if vm_exists $clone; then govc vm.power -off $clone 2>&1 || true; govc vm.destroy $clone; else echo 'VM $clone not found -- skipping'; fi"

    # power-off may fail if template is already off -- that's fine
    e2e_run "Revert template to snapshot" \
        "govc vm.power -off $TEMPLATE 2>&1; govc snapshot.revert -vm $TEMPLATE ${VM_SNAPSHOT:-aba-test}"

    local ds_flag=""
    [ -n "${VM_DATASTORE:-}" ] && ds_flag="-ds=${VM_DATASTORE}"
    e2e_run "Clone $TEMPLATE -> $clone (powered off)" \
        "govc vm.clone -vm $TEMPLATE -folder ${VC_FOLDER:-/Datacenter/vm/abatesting} $ds_flag -on=false $clone"

    local mac_entry="${VM_CLONE_MACS[$clone]:-}"
    if [ -n "$mac_entry" ]; then
        local -a macs=($mac_entry)
        local i
        for (( i=0; i<${#macs[@]}; i++ )); do
            local device="ethernet-${i}"
            local mac="${macs[$i]}"
            local nic_net
            nic_net=$(_get_nic_network "$clone" "$device" 2>&1) || true
            if [ -z "$nic_net" ]; then
                # Device might not exist on this template (e.g. 2-NIC template with 3 MACs)
                if ! govc device.info -vm "$clone" "$device" &>/dev/null; then
                    echo "  SKIP: $clone has no $device -- skipping MAC $mac"
                    continue
                fi
                nic_net="${GOVC_NETWORK:-VM Network}"
            fi
            e2e_run "  $clone: $device MAC -> $mac" \
                "govc vm.network.change -vm $clone -net '$nic_net' -net.address $mac $device"
        done
    else
        echo "  WARNING: No MAC addresses defined for '$clone' in VM_CLONE_MACS"
    fi
}

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Prereqs: govc and VMware connectivity" \
    "Clone: $CON_NAME + $DIS_NAME (with MACs)" \
    "Boot: power on and wait for SSH" \
    "SSH keys: root access on both hosts" \
    "Network: role-aware config (connected + disconnected)" \
    "Firewall: masquerade + NAT on $CON_NAME" \
    "DNS: dnsmasq on $CON_NAME for pool $POOL_NUM cluster records" \
    "NTP: chrony and timezone on both hosts" \
    "Cleanup: caches, podman, home on both hosts" \
    "Config: vmware.conf, test user, aba install ($CON_NAME)" \
    "Harden: remove RPMs, pull-secret, proxy ($DIS_NAME)" \
    "Verify: full configuration check"

suite_begin "clone-and-check"

# ============================================================================
# 1. Prerequisites
# ============================================================================
test_begin "Prereqs: govc and VMware connectivity"

e2e_run -q "Install aba (if needed)" "./install"
e2e_run "Copy vmware.conf" "cp -v $VF vmware.conf"
e2e_run -q "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

source <(normalize-vmware-conf) || { echo "WARNING: normalize-vmware-conf failed" >&2; }

e2e_run "Install govc" "aba --dir cli ~/bin/govc"
e2e_run "Verify template exists: $TEMPLATE" "govc vm.info $TEMPLATE"

test_end

# ============================================================================
# 2. Clone both VMs (powered off, MACs set)
# ============================================================================
test_begin "Clone: $CON_NAME + $DIS_NAME (with MACs)"

clone_with_macs "$CON_NAME"
clone_with_macs "$DIS_NAME"

e2e_run "Verify $CON_NAME exists" "govc vm.info $CON_NAME"
e2e_run "Verify $DIS_NAME exists" "govc vm.info $DIS_NAME"

test_end

# ============================================================================
# 3. Power on both and wait for SSH
# ============================================================================
test_begin "Boot: power on and wait for SSH"

e2e_run "Power on $CON_NAME" "govc vm.power -on $CON_NAME"
e2e_run "Power on $DIS_NAME" "govc vm.power -on $DIS_NAME"

echo "  Waiting ${VM_BOOT_DELAY:-8}s for VMs to start ..."
sleep "${VM_BOOT_DELAY:-8}"

e2e_run "Wait for SSH on $CON_HOST" "_vm_wait_ssh $CON_HOST $DEF_USER"
e2e_run "Wait for SSH on $DIS_HOST" "_vm_wait_ssh $DIS_HOST $DEF_USER"

test_end

# ============================================================================
# 4. SSH keys: root access
# ============================================================================
test_begin "SSH keys: root access on both hosts"

e2e_run "SSH keys on $CON_NAME" "_vm_setup_ssh_keys $CON_HOST $DEF_USER"
e2e_run "SSH keys on $DIS_NAME" "_vm_setup_ssh_keys $DIS_HOST $DEF_USER"

e2e_run "Verify root SSH on $CON_HOST" "ssh root@$CON_HOST whoami | grep root"
e2e_run "Verify root SSH on $DIS_HOST" "ssh root@$DIS_HOST whoami | grep root"

test_end

# ============================================================================
# 5. Network config: role-aware (connected vs disconnected)
# ============================================================================
test_begin "Network: role-aware config (connected + disconnected)"

e2e_run "Configure network on $CON_NAME (connected)" \
    "_vm_setup_network $CON_HOST $DEF_USER $CON_NAME"

e2e_run "Configure network on $DIS_NAME (disconnected)" \
    "_vm_setup_network $DIS_HOST $DEF_USER $DIS_NAME"

test_end

# ============================================================================
# 6. Firewall + masquerade on connected bastion
# ============================================================================
test_begin "Firewall: masquerade + NAT on $CON_NAME"

e2e_run "Setup firewall + masquerade on $CON_NAME" \
    "_vm_setup_firewall $CON_HOST $DEF_USER"

test_end

# ============================================================================
# 7. DNS: dnsmasq on connected bastion (serves cluster DNS for this pool)
# ============================================================================
test_begin "DNS: dnsmasq on $CON_NAME for pool $POOL_NUM cluster records"

e2e_run "Setup dnsmasq on $CON_NAME" \
    "_vm_setup_dnsmasq $CON_HOST $DEF_USER $CON_NAME"

test_end

# ============================================================================
# 8. NTP: chrony and timezone (AFTER network + firewall so dis1 can reach NTP)
# ============================================================================
test_begin "NTP: chrony and timezone on both hosts"

e2e_run "NTP/time on $CON_NAME" "_vm_setup_time $CON_HOST $DEF_USER"
e2e_run "NTP/time on $DIS_NAME" "_vm_setup_time $DIS_HOST $DEF_USER"

test_end

# ============================================================================
# 9. Cleanup: caches, podman, home
# ============================================================================
test_begin "Cleanup: caches, podman, home on both hosts"

e2e_run "Cleanup caches on $CON_NAME" "_vm_cleanup_caches $CON_HOST $DEF_USER"
e2e_run "Cleanup caches on $DIS_NAME" "_vm_cleanup_caches $DIS_HOST $DEF_USER"

e2e_run "Cleanup podman on $CON_NAME" "_vm_cleanup_podman $CON_HOST $DEF_USER"
e2e_run "Cleanup podman on $DIS_NAME" "_vm_cleanup_podman $DIS_HOST $DEF_USER"

e2e_run "Cleanup home on $CON_NAME" "_vm_cleanup_home $CON_HOST $DEF_USER"
e2e_run "Cleanup home on $DIS_NAME" "_vm_cleanup_home $DIS_HOST $DEF_USER"

test_end

# ============================================================================
# 10. Config: vmware.conf, test user, install aba on con1
# ============================================================================
test_begin "Config: vmware.conf, test user, aba install ($CON_NAME)"

e2e_run "Copy vmware.conf to $CON_NAME" "_vm_setup_vmware_conf $CON_HOST $DEF_USER"
e2e_run "Copy vmware.conf to $DIS_NAME" "_vm_setup_vmware_conf $DIS_HOST $DEF_USER"

e2e_run "Create test user on $CON_NAME" "_vm_create_test_user $CON_HOST $DEF_USER"
e2e_run "Create test user on $DIS_NAME" "_vm_create_test_user $DIS_HOST $DEF_USER"

e2e_run "Set ABA_TESTING on $CON_NAME" "_vm_set_aba_testing $CON_HOST $DEF_USER"
e2e_run "Set ABA_TESTING on $DIS_NAME" "_vm_set_aba_testing $DIS_HOST $DEF_USER"

e2e_run "Install aba on $CON_NAME" "_vm_install_aba $CON_HOST $DEF_USER"

test_end

# ============================================================================
# 11. Harden dis1: remove RPMs, pull-secret, proxy
# ============================================================================
test_begin "Harden: remove RPMs, pull-secret, proxy ($DIS_NAME)"

e2e_run "Remove RPMs on $DIS_NAME" "_vm_remove_rpms $DIS_HOST $DEF_USER"
e2e_run "Remove pull-secret on $DIS_NAME" "_vm_remove_pull_secret $DIS_HOST $DEF_USER"
e2e_run "Remove proxy on $DIS_NAME" "_vm_remove_proxy $DIS_HOST $DEF_USER"

test_end

# ============================================================================
# 12. Verify everything
# ============================================================================
test_begin "Verify: full configuration check"

# --- Hostnames ---
e2e_run "$CON_HOST: verify hostname = $CON_NAME" \
    "ssh $DEF_USER@$CON_HOST hostnamectl status | grep -q $CON_NAME"
e2e_run "$DIS_HOST: verify hostname = $DIS_NAME" \
    "ssh $DEF_USER@$DIS_HOST hostnamectl status | grep -q $DIS_NAME"

# --- con1: default route must be via ens256 (internet), NOT ens192 ---
e2e_run "$CON_HOST: default route via ens256" \
    "ssh $DEF_USER@$CON_HOST ip route show default | grep ens256"
e2e_run "$CON_HOST: no default route via ens192" \
    "ssh $DEF_USER@$CON_HOST '! ip route show default | grep ens192'"

# --- dis1: default route must be via con1 VLAN, NOT ens192/ens256 ---
e2e_run "$DIS_HOST: default route via ens224.10 (VLAN)" \
    "ssh $DEF_USER@$DIS_HOST ip route show default | grep ens224.10"
e2e_run "$DIS_HOST: no default route via ens192" \
    "ssh $DEF_USER@$DIS_HOST '! ip route show default | grep ens192'"

# --- dis1: ens256 should be DOWN ---
e2e_run "$DIS_HOST: ens256 is DOWN" \
    "ssh $DEF_USER@$DIS_HOST 'ip link show ens256 | grep -q \"state DOWN\"'"

# --- VLAN interfaces with correct IPs ---
con_vlan_ip="${VM_CLONE_VLAN_IPS[$CON_NAME]%%/*}"
dis_vlan_ip="${VM_CLONE_VLAN_IPS[$DIS_NAME]%%/*}"

e2e_run "$CON_HOST: ens224.10 has IP $con_vlan_ip" \
    "ssh $DEF_USER@$CON_HOST ip addr show ens224.10 | grep $con_vlan_ip"
e2e_run "$DIS_HOST: ens224.10 has IP $dis_vlan_ip" \
    "ssh $DEF_USER@$DIS_HOST ip addr show ens224.10 | grep $dis_vlan_ip"

# --- VLAN connectivity ---
e2e_run "$CON_HOST -> $DIS_NAME ($dis_vlan_ip) VLAN ping" \
    "ssh $DEF_USER@$CON_HOST ping -c 3 -W 5 $dis_vlan_ip"
e2e_run "$DIS_HOST -> $CON_NAME ($con_vlan_ip) VLAN ping" \
    "ssh $DEF_USER@$DIS_HOST ping -c 3 -W 5 $con_vlan_ip"

# --- Masquerade ---
e2e_run "$CON_HOST: firewall masquerade enabled" \
    "ssh $DEF_USER@$CON_HOST sudo firewall-cmd --query-masquerade"
e2e_run "$CON_HOST: ip_forward = 1" \
    "ssh $DEF_USER@$CON_HOST cat /proc/sys/net/ipv4/ip_forward | grep 1"
e2e_run "$CON_HOST: ping internet (8.8.8.8)" \
    "ssh $DEF_USER@$CON_HOST ping -c 3 -W 5 8.8.8.8"

# --- dis1 reaches internet via con1 masquerade ---
e2e_run "$DIS_HOST: default route via $CON_NAME VLAN ($con_vlan_ip)" \
    "ssh $DEF_USER@$DIS_HOST ip route show default | grep $con_vlan_ip"
e2e_run "$DIS_HOST: ping internet via $CON_NAME masquerade (8.8.8.8)" \
    "ssh $DEF_USER@$DIS_HOST ping -c 3 -W 5 8.8.8.8"

# --- DNS: dnsmasq on con1 ---
pool_dom="$(pool_domain $POOL_NUM)"
expected_node="$(pool_node_ip $POOL_NUM)"
expected_api="$(pool_api_vip $POOL_NUM)"
expected_apps="$(pool_apps_vip $POOL_NUM)"
con_ip="$(pool_con_ip $POOL_NUM)"
sno_name="$(pool_cluster_name sno $POOL_NUM)"
compact_name="$(pool_cluster_name compact $POOL_NUM)"
standard_name="$(pool_cluster_name standard $POOL_NUM)"

e2e_run "$CON_HOST: dnsmasq running" \
    "ssh $DEF_USER@$CON_HOST systemctl is-active dnsmasq"
e2e_run "$CON_HOST: DNS port 53 open" \
    "ssh $DEF_USER@$CON_HOST sudo firewall-cmd --list-services | grep dns"

# SNO records
e2e_run "$CON_HOST: api.$sno_name.$pool_dom -> $expected_node" \
    "ssh $DEF_USER@$CON_HOST dig +short api.$sno_name.$pool_dom @127.0.0.1 | grep -q $expected_node"
e2e_run "$CON_HOST: *.apps.$sno_name.$pool_dom -> $expected_node" \
    "ssh $DEF_USER@$CON_HOST dig +short test.apps.$sno_name.$pool_dom @127.0.0.1 | grep -q $expected_node"

# Compact records
e2e_run "$CON_HOST: api.$compact_name.$pool_dom -> $expected_api" \
    "ssh $DEF_USER@$CON_HOST dig +short api.$compact_name.$pool_dom @127.0.0.1 | grep -q $expected_api"
e2e_run "$CON_HOST: *.apps.$compact_name.$pool_dom -> $expected_apps" \
    "ssh $DEF_USER@$CON_HOST dig +short test.apps.$compact_name.$pool_dom @127.0.0.1 | grep -q $expected_apps"

# Standard records
e2e_run "$CON_HOST: api.$standard_name.$pool_dom -> $expected_api" \
    "ssh $DEF_USER@$CON_HOST dig +short api.$standard_name.$pool_dom @127.0.0.1 | grep -q $expected_api"
e2e_run "$CON_HOST: *.apps.$standard_name.$pool_dom -> $expected_apps" \
    "ssh $DEF_USER@$CON_HOST dig +short test.apps.$standard_name.$pool_dom @127.0.0.1 | grep -q $expected_apps"

# Upstream forwarding works
e2e_run "$CON_HOST: upstream DNS forwarding (google.com)" \
    "ssh $DEF_USER@$CON_HOST dig +short google.com @127.0.0.1 | grep -q '[0-9]'"

# Verify con1's dnsmasq is reachable from the network (run dig locally, targeting con1's IP)
e2e_run "Network DNS: api.$sno_name.$pool_dom via $CON_NAME ($con_ip)" \
    "dig +short api.$sno_name.$pool_dom @$con_ip | grep -q $expected_node"

# --- Root SSH ---
e2e_run "$CON_HOST: root SSH" "ssh root@$CON_HOST whoami | grep root"
e2e_run "$DIS_HOST: root SSH" "ssh root@$DIS_HOST whoami | grep root"

# --- NTP ---
e2e_run "$CON_HOST: chronyd running" \
    "ssh $DEF_USER@$CON_HOST systemctl is-active chronyd"
e2e_run "$DIS_HOST: chronyd running" \
    "ssh $DEF_USER@$DIS_HOST systemctl is-active chronyd"

# --- Test user ---
e2e_run "$CON_HOST: testy SSH" \
    "ssh -i ~/.ssh/testy_rsa testy@$CON_HOST whoami | grep testy"
e2e_run "$DIS_HOST: testy SSH" \
    "ssh -i ~/.ssh/testy_rsa testy@$DIS_HOST whoami | grep testy"
e2e_run "$CON_HOST: testy sudo" \
    "ssh -i ~/.ssh/testy_rsa testy@$CON_HOST sudo whoami | grep root"
e2e_run "$DIS_HOST: testy sudo" \
    "ssh -i ~/.ssh/testy_rsa testy@$DIS_HOST sudo whoami | grep root"

# --- con1: aba installed ---
e2e_run "$CON_HOST: aba installed" \
    "ssh $DEF_USER@$CON_HOST which aba"

# --- dis1: RPMs removed (git should be gone) ---
e2e_run "$DIS_HOST: git NOT installed" \
    "ssh $DEF_USER@$DIS_HOST '! which git 2>/dev/null'"

# --- dis1: pull-secret removed ---
e2e_run "$DIS_HOST: pull-secret removed" \
    "ssh $DEF_USER@$DIS_HOST '! test -f ~/.pull-secret.json'"

# --- vmware.conf on both ---
e2e_run "$CON_HOST: vmware.conf exists" \
    "ssh $DEF_USER@$CON_HOST test -s ~/.vmware.conf"
e2e_run "$DIS_HOST: vmware.conf exists" \
    "ssh $DEF_USER@$DIS_HOST test -s ~/.vmware.conf"

test_end

# ============================================================================

suite_end

echo ""
echo "================================================="
echo "Pool ${POOL_NUM} VMs fully configured and verified:"
echo "  $CON_NAME ($CON_HOST) -- connected bastion / gateway"
echo "  $DIS_NAME ($DIS_HOST) -- disconnected bastion (air-gapped)"
echo ""
echo "VMs are left running. Destroy manually when done:"
echo "  destroy_vm $CON_NAME && destroy_vm $DIS_NAME"
echo "================================================="
