#!/bin/bash
# setup-kvm-host.sh -- Standalone helper to configure a RHEL 9 host as a KVM hypervisor.
# This is NOT part of ABA core; it's a one-time provisioning tool for lab use.
#
# Usage:  tools/setup-kvm-host.sh <kvm-host-ip> [--user USER] [--hostname NAME] [--bridge-iface IFACE]
#                                                [--vlan-id ID] [--num-pools N] [--domain-base BASE]
#                                                [--upstream-dns IP]
#
# Assumes passwordless SSH (and passwordless sudo) to the target host.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
KVM_HOST=""
SSH_USER="steve"
KVM_HOSTNAME="kvm1"
BRIDGE_NAME="br-lab"
BRIDGE_IFACE="eno1"
STORAGE_POOL_PATH="/home/libvirt/images"
VLAN_ID=123
VLAN_SUBNET="10.10.123"
NUM_POOLS=4
DOMAIN_BASE="example.com"
UPSTREAM_DNS="10.0.1.8"

# ── Parse args ────────────────────────────────────────────────────────────────
usage() {
	echo "Usage: $0 <kvm-host-ip> [--user USER] [--hostname NAME] [--bridge-iface IFACE]"
	echo "                        [--vlan-id ID] [--num-pools N] [--domain-base BASE]"
	echo "                        [--upstream-dns IP]"
	echo
	echo "  --user USER            SSH user with passwordless sudo (default: steve)"
	echo "  --hostname NAME        Set the KVM host's hostname (default: kvm-host)"
	echo "  --bridge-iface IFACE   NIC to bridge (default: eno1)"
	echo "  --vlan-id ID           VLAN ID for KVM network tests (default: 123)"
	echo "  --num-pools N          Number of E2E pools to configure DNS for (default: 4)"
	echo "  --domain-base BASE     Base domain for pool FQDNs (default: example.com)"
	echo "  --upstream-dns IP      Upstream DNS/NTP server (default: 10.0.1.8)"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--user)         SSH_USER="$2"; shift 2 ;;
		--hostname)     KVM_HOSTNAME="$2"; shift 2 ;;
		--bridge-iface) BRIDGE_IFACE="$2"; shift 2 ;;
		--vlan-id)      VLAN_ID="$2"; shift 2 ;;
		--num-pools)    NUM_POOLS="$2"; shift 2 ;;
		--domain-base)  DOMAIN_BASE="$2"; shift 2 ;;
		--upstream-dns) UPSTREAM_DNS="$2"; shift 2 ;;
		--help|-h)      usage ;;
		-*)             echo "Unknown option: $1"; usage ;;
		*)
			if [ -z "$KVM_HOST" ]; then
				KVM_HOST="$1"; shift
			else
				echo "Unexpected argument: $1"; usage
			fi
			;;
	esac
done

[ -z "$KVM_HOST" ] && usage

RSSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ServerAliveInterval=15 ${SSH_USER}@${KVM_HOST}"

echo "=== Configuring KVM host at $KVM_HOST ==="
echo "    SSH user:      $SSH_USER"
echo "    Hostname:      $KVM_HOSTNAME"
echo "    Bridge:        $BRIDGE_NAME on $BRIDGE_IFACE"
echo "    Storage pool:  $STORAGE_POOL_PATH"
echo "    VLAN ID:       $VLAN_ID"
echo "    VLAN subnet:   ${VLAN_SUBNET}.0/24"
echo "    Pools:         $NUM_POOLS"
echo "    Upstream DNS:  $UPSTREAM_DNS"
echo

# ── Step 1: Set hostname ─────────────────────────────────────────────────────
echo "--- Step 1: Setting hostname to $KVM_HOSTNAME ---"
$RSSH sudo hostnamectl set-hostname "$KVM_HOSTNAME"

# ── Step 2: Install KVM / libvirt packages ────────────────────────────────────
echo "--- Step 2: Installing KVM/libvirt packages ---"
$RSSH sudo dnf install -y qemu-kvm libvirt virt-install libguestfs-tools

# ── Step 3: Enable and start libvirtd ─────────────────────────────────────────
echo "--- Step 3: Enabling libvirtd ---"
$RSSH sudo systemctl enable --now libvirtd

# ── Step 4: Add SSH user to libvirt group ─────────────────────────────────────
# Required for qemu+ssh://user@host/system to connect to the system daemon.
echo "--- Step 4: Adding $SSH_USER to libvirt group ---"
$RSSH sudo usermod -aG libvirt "$SSH_USER"

# ── Step 5: Disable the libvirt default NAT network (we use bridged) ──────────
echo "--- Step 5: Disabling libvirt default NAT network ---"
$RSSH "sudo virsh net-destroy default 2>/dev/null || true; sudo virsh net-autostart --disable default 2>/dev/null || true"

# ── Step 6: Create network bridge ────────────────────────────────────────────
# The bridge takes over the interface's IP. This WILL briefly drop the SSH
# connection, so the nmcli switch runs via nohup.
echo "--- Step 6: Creating bridge $BRIDGE_NAME on $BRIDGE_IFACE ---"

$RSSH bash -s -- "$BRIDGE_NAME" "$BRIDGE_IFACE" <<'BRIDGE_SCRIPT'
set -eux
BR="$1"
IFACE="$2"

if nmcli -t -f NAME connection show | grep -qx "$BR"; then
	echo "Bridge $BR already exists, skipping creation."
	exit 0
fi

sudo nmcli connection add type bridge ifname "$BR" con-name "$BR" \
	ipv4.method auto \
	ipv6.method disabled \
	connection.autoconnect yes

sudo nmcli connection add type bridge-slave ifname "$IFACE" con-name "${BR}-port-${IFACE}" \
	master "$BR" \
	connection.autoconnect yes

# Switch connectivity: bring down old NIC, bring up bridge.
# Run via nohup so the SSH drop doesn't kill us.
nohup sudo bash -c "
	sleep 1
	nmcli connection down '$IFACE' 2>/dev/null || true
	nmcli connection modify '$IFACE' connection.autoconnect no 2>/dev/null || true
	nmcli connection up '$BR'
" &>/tmp/bridge-switch.log &

echo "Bridge activation dispatched. SSH will drop momentarily."
BRIDGE_SCRIPT

echo "    Waiting 25s for bridge to acquire DHCP..."
sleep 25

echo "    Reconnecting..."
for i in $(seq 1 12); do
	if $RSSH "echo 'SSH reconnected'" 2>/dev/null; then
		break
	fi
	echo "    Retry $i/12..."
	sleep 5
done

echo "    Verifying bridge..."
$RSSH "ip addr show $BRIDGE_NAME && bridge link show" || echo "WARNING: bridge verification failed"

# ── Step 7: Create storage pool ──────────────────────────────────────────────
echo "--- Step 7: Creating storage pool at $STORAGE_POOL_PATH ---"

$RSSH bash -s -- "$STORAGE_POOL_PATH" "$SSH_USER" <<'POOL_SCRIPT'
set -eux
POOL_PATH="$1"
POOL_USER="$2"

sudo mkdir -p "$POOL_PATH"
sudo chown "$POOL_USER:libvirt" "$POOL_PATH"
sudo chmod 775 "$POOL_PATH"

if sudo virsh pool-info default &>/dev/null; then
	echo "Storage pool 'default' already exists."
else
	sudo virsh pool-define-as default dir --target "$POOL_PATH"
	sudo virsh pool-build default
fi

sudo virsh pool-start default 2>/dev/null || true
sudo virsh pool-autostart default
sudo virsh pool-info default
POOL_SCRIPT

# ── Step 8: (skipped) ────────────────────────────────────────────────────────
# Previously authorized a "golden VM root key" so root@conN could connect to
# the KVM host via qemu+ssh://$SSH_USER@host/system.  In practice, all E2E
# suites connect to the KVM host using $SSH_USER's own SSH keys (already
# authorized), so a separate golden root key is unnecessary.  If a future
# workflow requires root@conN to have its own keypair authorized on the KVM
# host, uncomment and adapt the block below.
#
# echo "--- Step 8: Authorizing E2E root keys on KVM host ---"
# _golden_root_key="$HOME/.ssh/e2e-golden-root.pub"
# if [ -f "$_golden_root_key" ]; then
#     _pubkey=$(cat "$_golden_root_key")
#     $RSSH "grep -qF '$(echo "$_pubkey" | cut -d' ' -f2)' ~/.ssh/authorized_keys 2>/dev/null || echo '$_pubkey' >> ~/.ssh/authorized_keys"
# fi
echo "--- Step 8: Skipped (using $SSH_USER SSH keys only) ---"

# ── Step 9: VLAN infrastructure for KVM network tests ────────────────────────
# The KVM VLAN subnet (br-lab.$VLAN_ID / 10.10.123.0/24) needs:
#   - rp_filter=0 so the kernel forwards between br-lab and br-lab.$VLAN_ID
#   - Masquerade NAT so conN traffic destined for VLAN VMs gets source-NAT'd
#   - Firewall ports for DNS (53) and NTP (123) so VLAN VMs can reach services
#   - dnsmasq listening on the VLAN gateway to serve cluster DNS
#   - chronyd configured to serve NTP on the VLAN interface
echo "--- Step 9: Configuring VLAN $VLAN_ID infrastructure ---"

# 9a: rp_filter -- disable reverse-path filtering on bridge + VLAN sub-interface
echo "    [9a] Disabling rp_filter on $BRIDGE_NAME and $BRIDGE_NAME.$VLAN_ID ..."
$RSSH sudo bash -s -- "$BRIDGE_NAME" "$VLAN_ID" <<'RPFILTER_SCRIPT'
set -eu
BR="$1"
VID="$2"
SYSCTL_FILE="/etc/sysctl.d/99-vlan-routing.conf"

# sysctl uses '/' for dots in interface names (br-lab.123 -> br-lab/123)
cat > /tmp/99-vlan-routing.conf <<SYSEOF
# Allow routing between ${BR} and ${BR}.${VID} (KVM VLAN)
net.ipv4.conf.${BR}.rp_filter = 0
net.ipv4.conf.${BR}/${VID}.rp_filter = 0
SYSEOF

sudo cp /tmp/99-vlan-routing.conf "$SYSCTL_FILE"
sudo sysctl -p "$SYSCTL_FILE"
echo "    rp_filter disabled and persisted."
RPFILTER_SCRIPT

# 9b: Firewall -- open DNS/NTP ports and enable masquerade
echo "    [9b] Configuring firewall (DNS, NTP, masquerade) ..."
$RSSH sudo bash -s -- "$BRIDGE_NAME" "$VLAN_ID" "$VLAN_SUBNET" <<'FW_SCRIPT'
set -eu
BR="$1"
VID="$2"
VLAN_SUB="$3"

firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=ntp
firewall-cmd --permanent --zone=public --add-masquerade

firewall-cmd --reload

# Direct iptables rule for VLAN-specific masquerade (survives firewall-cmd reload
# because firewalld's masquerade covers it; this is belt-and-suspenders)
if ! iptables -t nat -C POSTROUTING -o "${BR}.${VID}" -j MASQUERADE 2>/dev/null; then
	iptables -t nat -A POSTROUTING -o "${BR}.${VID}" -j MASQUERADE
fi

echo "    Firewall configured."
FW_SCRIPT

# 9c: dnsmasq -- serve DNS for KVM VLAN cluster endpoints
echo "    [9c] Configuring dnsmasq for VLAN DNS ..."
_dnsmasq_entries=""
for p in $(seq 1 "$NUM_POOLS"); do
	_domain="p${p}.${DOMAIN_BASE}"
	_node_ip="${VLAN_SUBNET}.$((200 + p))"
	_api_vip="${VLAN_SUBNET}.$((210 + p))"
	_apps_vip="${VLAN_SUBNET}.$((220 + p))"

	_dnsmasq_entries="${_dnsmasq_entries}
# Pool $p
address=/api.e2e-kvm-sno-vlan${p}.${_domain}/${_node_ip}
address=/.apps.e2e-kvm-sno-vlan${p}.${_domain}/${_node_ip}
address=/api.e2e-kvm-compact-vlan${p}.${_domain}/${_api_vip}
address=/.apps.e2e-kvm-compact-vlan${p}.${_domain}/${_apps_vip}"
done

$RSSH sudo bash -s -- "${VLAN_SUBNET}.1" "$UPSTREAM_DNS" "$_dnsmasq_entries" <<'DNSMASQ_SCRIPT'
set -eu
LISTEN_IP="$1"
UPSTREAM="$2"
ENTRIES="$3"

sudo dnf install -y dnsmasq || true

cat > /tmp/kvm-vlan.conf <<DNSEOF
# KVM VLAN DNS -- auto-generated by setup-kvm-host.sh
listen-address=${LISTEN_IP}
bind-dynamic
no-resolv
server=${UPSTREAM}
${ENTRIES}
DNSEOF

sudo cp /tmp/kvm-vlan.conf /etc/dnsmasq.d/kvm-vlan.conf
sudo systemctl enable --now dnsmasq
sudo systemctl restart dnsmasq

echo "    dnsmasq configured and running."
DNSMASQ_SCRIPT

# 9d: chronyd -- serve NTP to VLAN VMs
echo "    [9d] Configuring chronyd for VLAN NTP service ..."
$RSSH sudo bash -s -- "$UPSTREAM_DNS" <<'CHRONY_SCRIPT'
set -eu
UPSTREAM="$1"

# Ensure chronyd uses the lab NTP server and allows VLAN clients
if ! grep -q "^server ${UPSTREAM}" /etc/chrony.conf; then
	sudo sed -i '/^pool /d' /etc/chrony.conf
	echo "server ${UPSTREAM} iburst" | sudo tee -a /etc/chrony.conf > /dev/null
fi

if ! grep -q "^allow 10.0.0.0/8" /etc/chrony.conf; then
	echo "allow 10.0.0.0/8" | sudo tee -a /etc/chrony.conf > /dev/null
fi

sudo systemctl restart chronyd
sudo chronyc makestep > /dev/null || true

echo "    chronyd configured and restarted."
CHRONY_SCRIPT

# ── Step 10: Verify ──────────────────────────────────────────────────────────
echo "--- Step 10: Verification ---"

$RSSH bash -s -- "$BRIDGE_NAME" "$VLAN_ID" "$VLAN_SUBNET" <<'VERIFY_SCRIPT'
BR="$1"
VID="$2"
VLAN_SUB="$3"

echo "=== virt-host-validate ==="
sudo virt-host-validate qemu 2>&1 || true

echo "=== virsh list ==="
virsh list --all 2>/dev/null || sudo virsh list --all

echo "=== virsh net-list ==="
virsh net-list --all 2>/dev/null || sudo virsh net-list --all

echo "=== virsh pool-list ==="
virsh pool-list --all 2>/dev/null || sudo virsh pool-list --all

echo "=== bridge ==="
ip addr show "$BR" 2>/dev/null || echo "($BR not found)"
bridge link show 2>/dev/null || true

echo "=== VLAN interface ==="
ip addr show "${BR}.${VID}" 2>/dev/null || echo "(${BR}.${VID} not found)"

echo "=== rp_filter ==="
echo "  ${BR}: $(cat /proc/sys/net/ipv4/conf/${BR}/rp_filter 2>/dev/null || echo 'N/A')"
echo "  ${BR}.${VID}: $(cat /proc/sys/net/ipv4/conf/${BR}.${VID}/rp_filter 2>/dev/null || echo 'N/A')"

echo "=== firewall (masquerade, dns, ntp) ==="
firewall-cmd --query-masquerade 2>/dev/null && echo "  masquerade: yes" || echo "  masquerade: NO"
firewall-cmd --list-services 2>/dev/null | grep -qw dns && echo "  dns: yes" || echo "  dns: NO"
firewall-cmd --list-services 2>/dev/null | grep -qw ntp && echo "  ntp: yes" || echo "  ntp: NO"

echo "=== dnsmasq ==="
systemctl is-active dnsmasq 2>/dev/null && echo "  active" || echo "  NOT active"
test -f /etc/dnsmasq.d/kvm-vlan.conf && echo "  kvm-vlan.conf present" || echo "  kvm-vlan.conf MISSING"

echo "=== chronyd ==="
systemctl is-active chronyd 2>/dev/null && echo "  active" || echo "  NOT active"
chronyc sources -n 2>/dev/null | head -5 || true
VERIFY_SCRIPT

echo
echo "=== KVM host setup complete at $KVM_HOST ==="
echo "    Connect with: virsh -c qemu+ssh://${SSH_USER}@${KVM_HOST}/system"
echo "    VLAN $VLAN_ID: ${VLAN_SUBNET}.0/24 via ${BRIDGE_NAME}.${VLAN_ID}"
echo
echo "    For E2E --user root support, ensure ~/.ssh/e2e-golden-root.pub exists"
echo "    on bastion and re-run this script (Step 8 authorizes it)."
