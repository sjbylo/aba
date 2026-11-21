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
export INFO_ABA=1

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
	# Find the interface that owns bastion_ip, so we allow the correct network
	_ntp_iface=""
	_ntp_iface=$(ip -o -4 addr show 2>/dev/null | awk -v ip="$bastion_ip" '$4 ~ "^"ip"/" {print $2; exit}')
	_ntp_iface=${_ntp_iface:-${local_iface:-$(_pick_install_iface 2>/dev/null || true)}}

	if [ -n "$_ntp_iface" ]; then
		allow_network=$(ip -o -4 route list dev "$_ntp_iface" proto kernel scope link 2>/dev/null \
			| awk '$1 ~ "/" {print $1; exit}')
	fi
	if [ -z "$allow_network" ]; then
		local_cidr=$(ip -o -4 addr show dev "${_ntp_iface:-lo}" 2>/dev/null | awk '{print $4; exit}')
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

# Warning only. This command still publishes the bastion address.
# Stratum 3 or worse is the same depth as the cluster's local stratum 3,
# so nodes will not prefer this host over that local clock.
# The second line names the source this host has selected. It does not
# follow that source's own upstream, and it does not change ntp_servers.
_ntp_warn_if_weak_stratum() {
	local stratum=$1 upstream=$2
	case "$stratum" in
		''|*[!0-9]*) return 0 ;;
	esac
	if [ "$stratum" -ge 3 ] && [ "$stratum" -le 15 ]; then
		if [ -n "$upstream" ]; then
			aba_warn "This host is NTP stratum $stratum. Prefer a stratum 1 or 2 server so cluster nodes can keep local stratum 3." \
				"Consider $upstream if the OpenShift nodes can reach it."
		else
			aba_warn "This host is NTP stratum $stratum. Prefer a stratum 1 or 2 server so cluster nodes can keep local stratum 3."
		fi
	fi
}

# Stratum 0 is what chronyd reports until it selects a source. That happens
# a few seconds after the restart above, so a single immediate read stays quiet.
_ntp_current_stratum() {
	chronyc tracking 2>/dev/null | awk '/^Stratum[[:space:]]*:/ {print $3; exit}' || true
}

_ntp_wait_stratum() {
	local stratum="" tries=0
	while [ "$tries" -lt 15 ]; do
		stratum=$(_ntp_current_stratum)
		case "$stratum" in
			''|*[!0-9]*|0)
				sleep 1
				tries=$(( tries + 1 ))
				;;
			*)
				printf '%s\n' "$stratum"
				return 0
				;;
		esac
	done
	printf '%s\n' "$stratum"
}

# server/pool/peer names from one chrony file. Comments and options are ignored.
_ntp_servers_in() {
	[ -f "$1" ] || return 0
	awk '$1 == "server" || $1 == "pool" || $1 == "peer" { print $2 }' "$1"
}

# Names from chrony.conf plus one level of sourcedir/confdir.
# No names means this host is not an NTP client. Callers then skip the
# stratum check: the cluster can still take time from this bastion.
_ntp_configured_servers() {
	local conf=${1:-/etc/chrony.conf}
	local line kind dir f
	[ -f "$conf" ] || return 0
	_ntp_servers_in "$conf"
	while IFS= read -r line || [ -n "$line" ]; do
		set -- $line
		kind=$1
		dir=$2
		case "$kind" in
			sourcedir|confdir) ;;
			*) continue ;;
		esac
		[ -n "$dir" ] && [ -d "$dir" ] || continue
		for f in "$dir"/*; do
			[ -f "$f" ] || continue
			_ntp_servers_in "$f"
		done
	done < "$conf"
}

# The address in parentheses is the source chrony selected, not that source's upstream.
_ntp_selected_from_tracking() {
	awk -F'[()]' '/^Reference ID[[:space:]]*:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }'
}

_ntp_selected_source() {
	chronyc tracking 2>/dev/null | _ntp_selected_from_tracking || true
}

# Prefer the selected source. Otherwise the first configured name that is not this host.
_ntp_suggest_upstream() {
	local bastion=$1 selected=$2 s
	shift 2
	# Dots in an address must stay literal, so this is a string compare.
	if [ -n "$selected" ] && [ "$selected" != "$bastion" ] \
		&& [ "$selected" != "0.0.0.0" ] && [ "$selected" != "127.0.0.1" ] && [ "$selected" != "::1" ]; then
		printf '%s\n' "$selected"
		return 0
	fi
	for s in "$@"; do
		[ -n "$s" ] && [ "$s" != "$bastion" ] || continue
		case "$s" in
			0.0.0.0|127.0.0.1|::1) continue ;;
		esac
		printf '%s\n' "$s"
		return 0
	done
	return 0
}

# No configured server: do not read the stratum and do not warn.
_ntp_have=$(_ntp_configured_servers)
if [ -n "$_ntp_have" ]; then
	_ntp_stratum=$(_ntp_wait_stratum)
	_ntp_selected=$(_ntp_selected_source)
	_ntp_upstream=$(_ntp_suggest_upstream "$bastion_ip" "$_ntp_selected" $_ntp_have)
	_ntp_warn_if_weak_stratum "$_ntp_stratum" "$_ntp_upstream"
fi

# --- Auto-set ntp_servers in aba.conf ---
if [ -f "$ABA_ROOT/aba.conf" ]; then
	replace-value-conf -n ntp_servers -v "$bastion_ip" -f "$ABA_ROOT/aba.conf"
	aba_info "Set ntp_servers=$bastion_ip in aba.conf"
fi

aba_info "NTP server configured. Cluster nodes can sync time from $bastion_ip."
