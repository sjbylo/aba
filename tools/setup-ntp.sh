#!/bin/bash
# setup-ntp.sh -- Configure chronyd as an NTP server for the cluster network.
#
# This is a one-time setup tool. After running, cluster nodes can use this
# bastion as their NTP source.
#
# Usage:  tools/setup-ntp.sh [-y] [--bastion-ip IP] [--allow-network CIDR]
#
# Options:
#   -y                   Skip interactive prompts (for automation)
#   --bastion-ip IP      Override auto-detected bastion IP address
#   --allow-network CIDR Override auto-detected network to allow (e.g. 10.0.0.0/16)
#
# What this script does:
#   1. Installs chrony (if not present)
#   2. Adds 'allow <network>' to /etc/chrony.conf (so cluster nodes can sync)
#   3. Opens firewall port 123 (ntp)
#   4. Restarts chronyd
#   5. Sets ntp_servers=<bastion_ip> in aba.conf
#
# To undo: tools/remove-ntp.sh
#
# This is purely additive — it does not change how the bastion syncs its own
# time, only enables it to serve time to the cluster network.

set -eo pipefail

ABA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ABA_ROOT/scripts/include_all.sh"

# --- Parse arguments ---
bastion_ip=""
allow_network=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-y)              export ASK_OVERRIDE=1; shift ;;
		--bastion-ip)    bastion_ip="$2"; shift 2 ;;
		--allow-network) allow_network="$2"; shift 2 ;;
		-h|--help)
			head -23 "$0" | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		*) aba_abort "Unknown option: $1. Use --help for usage." ;;
	esac
done

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

# --- Determine allow network ---
if [ -z "$allow_network" ]; then
	local_iface=${local_iface:-$(_pick_install_iface 2>/dev/null || true)}
	if [ -n "$local_iface" ]; then
		# Use the kernel route for this interface (e.g. 10.0.0.0/24)
		allow_network=$(ip -o -4 route list dev "$local_iface" proto kernel scope link 2>/dev/null \
			| awk '$1 ~ "/" {print $1; exit}')
	fi
	if [ -z "$allow_network" ]; then
		# Fallback: derive from interface CIDR
		local_cidr=$(ip -o -4 addr show dev "${local_iface:-lo}" 2>/dev/null | awk '{print $4; exit}')
		allow_network="${local_cidr:-0.0.0.0/0}"
	fi
fi

aba_info "Bastion IP: $bastion_ip"
aba_info "Allow network: $allow_network"

# --- Install chrony ---
install_rpms chrony

# --- Add allow line (idempotent) ---
if grep -q "^allow ${allow_network}$" /etc/chrony.conf 2>/dev/null; then
	aba_info "chrony.conf already has 'allow $allow_network' — skipping."
else
	$SUDO sed -i "/^#.*Allow NTP client/a allow ${allow_network}" /etc/chrony.conf 2>/dev/null
	if ! grep -q "^allow ${allow_network}$" /etc/chrony.conf 2>/dev/null; then
		echo "allow ${allow_network}" | $SUDO tee -a /etc/chrony.conf >/dev/null
	fi
	aba_info "Added 'allow $allow_network' to /etc/chrony.conf"
fi

# --- Open firewall ---
if command -v firewall-cmd >/dev/null 2>&1; then
	_fw_err=""
	_fw_err=$($SUDO firewall-cmd --permanent --add-service=ntp 2>&1) || aba_debug "firewall-cmd add-service=ntp: $_fw_err"
	_fw_err=$($SUDO firewall-cmd --reload 2>&1) || aba_debug "firewall-cmd reload: $_fw_err"
	aba_info "Firewall: opened NTP (port 123)"
fi

# --- Restart chronyd ---
$SUDO systemctl enable --now chronyd
$SUDO systemctl restart chronyd

# --- Verify ---
_chrony_src=""
_chrony_src=$(chronyc sources 2>&1)
if echo "$_chrony_src" | grep -q '^\^'; then
	aba_info "chronyd is syncing (chronyc sources OK)"
else
	aba_debug "chronyc sources output: $_chrony_src"
	aba_warn "chronyd running but no upstream sources detected." \
		"Check /etc/chrony.conf for server/pool directives."
fi

# --- Auto-set ntp_servers in aba.conf ---
if [ -f "$ABA_ROOT/aba.conf" ]; then
	replace-value-conf -n ntp_servers -v "$bastion_ip" -f "$ABA_ROOT/aba.conf"
	aba_info "Set ntp_servers=$bastion_ip in aba.conf"
fi

aba_info "NTP server configured. Cluster nodes can sync time from $bastion_ip."
