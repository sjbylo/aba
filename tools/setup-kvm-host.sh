#!/bin/bash
# setup-kvm-host.sh -- Standalone helper to configure a RHEL 9 host as a KVM hypervisor.
# This is NOT part of ABA core; it's a one-time provisioning tool for lab use.
#
# Usage:  tools/setup-kvm-host.sh <kvm-host-ip> [--user USER] [--hostname NAME] [--bridge-iface IFACE]
#
# Assumes passwordless SSH (and passwordless sudo) to the target host.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
KVM_HOST=""
SSH_USER="steve"
KVM_HOSTNAME="kvm-host"
BRIDGE_NAME="br-lab"
BRIDGE_IFACE="eno1"
STORAGE_POOL_PATH="/home/libvirt/images"

# ── Parse args ────────────────────────────────────────────────────────────────
usage() {
	echo "Usage: $0 <kvm-host-ip> [--user USER] [--hostname NAME] [--bridge-iface IFACE]"
	echo
	echo "  --user USER            SSH user with passwordless sudo (default: steve)"
	echo "  --hostname NAME        Set the KVM host's hostname (default: kvm-host)"
	echo "  --bridge-iface IFACE   NIC to bridge (default: eno1)"
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--user)         SSH_USER="$2"; shift 2 ;;
		--hostname)     KVM_HOSTNAME="$2"; shift 2 ;;
		--bridge-iface) BRIDGE_IFACE="$2"; shift 2 ;;
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
echo "    SSH user:     $SSH_USER"
echo "    Hostname:     $KVM_HOSTNAME"
echo "    Bridge:       $BRIDGE_NAME on $BRIDGE_IFACE"
echo "    Storage pool: $STORAGE_POOL_PATH"
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

# ── Step 8: Verify ───────────────────────────────────────────────────────────
echo "--- Step 8: Verification ---"

$RSSH bash <<'VERIFY_SCRIPT'
echo "=== virt-host-validate ==="
sudo virt-host-validate qemu 2>&1 || true

echo "=== virsh list ==="
virsh list --all 2>/dev/null || sudo virsh list --all

echo "=== virsh net-list ==="
virsh net-list --all 2>/dev/null || sudo virsh net-list --all

echo "=== virsh pool-list ==="
virsh pool-list --all 2>/dev/null || sudo virsh pool-list --all

echo "=== bridge ==="
ip addr show br-lab 2>/dev/null || echo "(br-lab not found)"
bridge link show 2>/dev/null || true
VERIFY_SCRIPT

echo
echo "=== KVM host setup complete at $KVM_HOST ==="
echo "    Connect with: virsh -c qemu+ssh://${SSH_USER}@${KVM_HOST}/system"
