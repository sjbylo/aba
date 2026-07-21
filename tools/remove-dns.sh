#!/bin/bash
# remove-dns.sh -- Remove ABA's dnsmasq configuration and restore original DNS.
#
# Reverses what tools/setup-dns.sh did:
#   1. Removes all /etc/dnsmasq.d/aba-*.conf files (upstream + cluster records)
#   2. Restores /etc/resolv.conf from backup
#   3. Re-enables NetworkManager DNS management
#   4. Closes firewall port 53
#   5. Stops dnsmasq (does NOT uninstall the RPM)
#
# Usage:  tools/remove-dns.sh [-y]

set -euo pipefail

ABA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ABA_ROOT/scripts/include_all.sh"
ask=${ask:-}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
	case "$1" in
		-y)     export ASK_OVERRIDE=1; shift ;;
		-h|--help)
			head -12 "$0" | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		*) aba_abort "Unknown option: $1. Use --help for usage." ;;
	esac
done

_MARKER="/etc/dnsmasq.d/aba-upstream.conf"

if [ ! -f "$_MARKER" ]; then
	aba_info "ABA dnsmasq marker not found ($_MARKER). Nothing to remove."
	exit 0
fi

ask "Remove ABA's dnsmasq configuration and restore original DNS settings" || exit 1

# --- Remove ABA dnsmasq config files ---
$SUDO rm -f /etc/dnsmasq.d/aba-*.conf
aba_info "Removed /etc/dnsmasq.d/aba-*.conf"

# --- Stop dnsmasq ---
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
	$SUDO systemctl stop dnsmasq
	$SUDO systemctl disable dnsmasq 2>/dev/null || true
	aba_info "Stopped and disabled dnsmasq"
fi

# --- Restore resolv.conf ---
if [ -f /etc/resolv.conf.aba-backup ]; then
	$SUDO cp -p /etc/resolv.conf.aba-backup /etc/resolv.conf
	$SUDO rm -f /etc/resolv.conf.aba-backup
	aba_info "Restored /etc/resolv.conf from backup"
else
	aba_warn "No backup found at /etc/resolv.conf.aba-backup — resolv.conf not restored."
fi

# --- Re-enable NetworkManager DNS ---
$SUDO rm -f /etc/NetworkManager/conf.d/aba-no-dns.conf
$SUDO systemctl reload NetworkManager 2>/dev/null || true
aba_info "Re-enabled NetworkManager DNS management"

# --- Close firewall ---
if command -v firewall-cmd >/dev/null 2>&1; then
	$SUDO firewall-cmd --permanent --remove-service=dns 2>/dev/null || true
	$SUDO firewall-cmd --reload 2>/dev/null || true
	aba_info "Firewall: closed DNS (port 53)"
fi

aba_info "ABA dnsmasq configuration removed. Original DNS settings restored."
