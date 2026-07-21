#!/bin/bash
# setup-dns.sh -- Configure dnsmasq as a local DNS resolver on this bastion.
#
# This is a one-time setup tool. After running, ABA will automatically manage
# per-cluster DNS records (api.<name>.<domain> and *.apps.<name>.<domain>)
# during cluster install and delete.
#
# Usage:  tools/setup-dns.sh [-y] [--bastion-ip IP] [--upstream IP]
#
# Options:
#   -y               Skip interactive prompts (for automation)
#   --bastion-ip IP  Override auto-detected bastion IP address
#   --upstream IP    Override auto-detected upstream DNS server
#
# What this script does:
#   1. Installs dnsmasq (if not present)
#   2. Configures dnsmasq with upstream DNS forwarding
#   3. Redirects /etc/resolv.conf to use local dnsmasq (127.0.0.1)
#   4. Opens firewall port 53 (dns)
#   5. Sets dns_servers=<bastion_ip> in aba.conf
#
# To undo: tools/remove-dns.sh
#
# The marker file /etc/dnsmasq.d/aba-upstream.conf signals to ABA that
# dnsmasq is managed by ABA and per-cluster records should be auto-managed.

set -eo pipefail

ABA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ABA_ROOT/scripts/include_all.sh"

# --- Parse arguments ---
bastion_ip=""
upstream=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-y)          export ASK_OVERRIDE=1; shift ;;
		--bastion-ip) bastion_ip="$2"; shift 2 ;;
		--upstream)  upstream="$2"; shift 2 ;;
		-h|--help)
			head -25 "$0" | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		*) aba_abort "Unknown option: $1. Use --help for usage." ;;
	esac
done

_MARKER="/etc/dnsmasq.d/aba-upstream.conf"

# --- Idempotent: already configured ---
if [ -f "$_MARKER" ]; then
	aba_info "dnsmasq already configured by ABA (marker exists: $_MARKER)."
	aba_info "Nothing to do. To reconfigure, run tools/remove-dns.sh first."
	exit 0
fi

# --- Determine bastion IP ---
if [ -z "$bastion_ip" ]; then
	local_iface=$(_pick_install_iface 2>/dev/null || true)
	if [ -z "$local_iface" ]; then
		aba_abort "Cannot detect bastion network interface." \
			"Use --bastion-ip to specify manually."
	fi
	bastion_ip=$(ip -o -4 addr show dev "$local_iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
	if [ -z "$bastion_ip" ]; then
		aba_abort "Cannot detect bastion IP from interface $local_iface." \
			"Use --bastion-ip to specify manually."
	fi
fi

# --- Determine upstream DNS ---
if [ -z "$upstream" ]; then
	local_iface=${local_iface:-$(_pick_install_iface 2>/dev/null || true)}
	if [ -n "$local_iface" ] && command -v nmcli >/dev/null 2>&1; then
		upstream=$(nmcli -t -f IP4.DNS dev show "$local_iface" 2>/dev/null \
			| cut -d: -f2 | grep -E '^[0-9.]+' | head -1)
	fi
	if [ -z "$upstream" ]; then
		upstream=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
	fi
	if [ -z "$upstream" ]; then
		aba_abort "Cannot detect upstream DNS server." \
			"Use --upstream to specify manually."
	fi
fi

aba_info "Bastion IP: $bastion_ip"
aba_info "Upstream DNS: $upstream"

# --- Safety check: ask if dnsmasq already running or resolv.conf would change ---
_needs_ask=""
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
	_needs_ask=1
elif ! grep -q '^nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null; then
	_needs_ask=1
fi

if [ "$_needs_ask" ]; then
	ask "ABA will configure dnsmasq as the local DNS resolver and redirect /etc/resolv.conf (backed up first). Continue" || exit 1
fi

# --- Install dnsmasq ---
install_rpms dnsmasq

# --- Backup resolv.conf ---
if [ ! -f /etc/resolv.conf.aba-backup ]; then
	$SUDO cp -p /etc/resolv.conf /etc/resolv.conf.aba-backup
	aba_info "Backed up /etc/resolv.conf to /etc/resolv.conf.aba-backup"
fi

# --- Configure dnsmasq ---
# Remove directives that conflict with bind-dynamic
$SUDO sed -i '/^listen-address/d; /^bind-interfaces/d; /^interface=/d; /^local-service/d' /etc/dnsmasq.conf

$SUDO mkdir -p /etc/dnsmasq.d
$SUDO tee "$_MARKER" >/dev/null <<-EOF
# ABA-managed dnsmasq upstream configuration
# Created by: tools/setup-dns.sh on $(date '+%Y-%m-%d %H:%M:%S')
# To remove: tools/remove-dns.sh
no-resolv
bind-dynamic
server=${upstream}
EOF

# --- Configure NetworkManager to not manage resolv.conf ---
$SUDO mkdir -p /etc/NetworkManager/conf.d
$SUDO tee /etc/NetworkManager/conf.d/aba-no-dns.conf >/dev/null <<-EOF
[main]
dns=none
EOF
$SUDO systemctl reload NetworkManager 2>/dev/null || true

# --- Rewrite resolv.conf ---
$SUDO tee /etc/resolv.conf >/dev/null <<-EOF
# Managed by ABA (tools/setup-dns.sh). Original backed up to /etc/resolv.conf.aba-backup
nameserver 127.0.0.1
EOF

# --- Open firewall ---
if command -v firewall-cmd >/dev/null 2>&1; then
	$SUDO firewall-cmd --permanent --add-service=dns 2>/dev/null || true
	$SUDO firewall-cmd --reload 2>/dev/null || true
	aba_info "Firewall: opened DNS (port 53)"
fi

# --- Enable and start dnsmasq ---
$SUDO systemctl enable --now dnsmasq
$SUDO systemctl restart dnsmasq

# --- Verify ---
if ! dig @127.0.0.1 +short +timeout=3 google.com >/dev/null 2>&1; then
	aba_warn "dnsmasq started but external resolution failed." \
		"Check upstream DNS ($upstream) is reachable." \
		"Verify with: dig @127.0.0.1 google.com"
else
	aba_info "DNS resolution verified (dig @127.0.0.1 google.com)"
fi

# --- Auto-set dns_servers in aba.conf ---
if [ -f "$ABA_ROOT/aba.conf" ]; then
	replace-value-conf -n dns_servers -v "$bastion_ip" -f "$ABA_ROOT/aba.conf"
	aba_info "Set dns_servers=$bastion_ip in aba.conf"
fi

# --- If mirror already installed, add its DNS record too ---
if [ -f "$ABA_ROOT/mirror/.available" ]; then
	(cd "$ABA_ROOT/mirror" && "$ABA_ROOT/scripts/infra-dns.sh" add-mirror)
fi

aba_info "dnsmasq configured successfully."
aba_info "ABA will now auto-manage per-cluster DNS records during install/delete."
