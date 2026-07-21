#!/bin/bash
# remove-ntp.sh -- Remove ABA's NTP server configuration from chronyd.
#
# Reverses what tools/setup-ntp.sh did:
#   1. Removes the 'allow' line from /etc/chrony.conf
#   2. Closes firewall port 123
#   3. Restarts chronyd (still runs as client, just stops serving)
#
# Does NOT uninstall chrony or stop the service (bastion still needs time sync).
#
# Usage:  tools/remove-ntp.sh [-y]

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

# --- Check if there's anything to remove ---
if ! grep -q '^allow ' /etc/chrony.conf 2>/dev/null; then
	aba_info "No 'allow' line found in /etc/chrony.conf. Nothing to remove."
	exit 0
fi

ask "Remove NTP server 'allow' configuration from chronyd" || exit 1

# --- Remove allow line(s) ---
$SUDO sed -i '/^allow /d' /etc/chrony.conf
aba_info "Removed 'allow' line(s) from /etc/chrony.conf"

# --- Close firewall ---
if command -v firewall-cmd >/dev/null 2>&1; then
	$SUDO firewall-cmd --permanent --remove-service=ntp 2>/dev/null || true
	$SUDO firewall-cmd --reload 2>/dev/null || true
	aba_info "Firewall: closed NTP (port 123)"
fi

# --- Restart chronyd (still runs as client) ---
$SUDO systemctl restart chronyd
aba_info "chronyd restarted (still syncing as client, no longer serving)."
