#!/bin/bash
# infra-dns.sh -- Manage DNS records in ABA's dnsmasq.
#
# Called automatically by:
#   - Makefile.cluster (.infra-dns target) during install → add-cluster
#   - aba.sh delete flow → remove-cluster
#   - Makefile.mirror (.available target) → add-mirror
#   - reg-uninstall.sh → remove-mirror
#
# All commands are no-ops if ABA's dnsmasq marker does not exist.
# This script is NOT intended for direct user invocation.
#
# Usage:
#   scripts/infra-dns.sh add-cluster            (reads cluster.conf from CWD)
#   scripts/infra-dns.sh remove-cluster <name>
#   scripts/infra-dns.sh add-mirror             (reads mirror.conf from CWD)
#   scripts/infra-dns.sh remove-mirror
#   scripts/infra-dns.sh check

set -eo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$_SCRIPT_DIR/include_all.sh"

_MARKER="/etc/dnsmasq.d/aba-upstream.conf"

_dnsmasq_restart() {
	$SUDO systemctl reset-failed dnsmasq 2>/dev/null || true
	local _restart_err
	if ! _restart_err=$($SUDO systemctl restart dnsmasq 2>&1); then
		aba_debug "dnsmasq restart failed: $_restart_err"
		aba_warn "Failed to restart dnsmasq. Check: systemctl status dnsmasq"
	fi
}

case "${1:-}" in
	add-cluster)
		# No-op if ABA doesn't own dnsmasq
		[ -f "$_MARKER" ] || exit 0

		source <(normalize-cluster-conf)

		cluster_name="${cluster_name:-}"
		base_domain="${base_domain:-}"
		[ -z "$cluster_name" ] && aba_abort "infra-dns.sh add-cluster: cluster_name not set in cluster.conf"
		[ -z "$base_domain" ] && aba_abort "infra-dns.sh add-cluster: base_domain not set in cluster.conf"

		# Determine IPs: SNO uses starting_ip for both api and apps
		# Multi-node uses api_vip and ingress_vip
		if [ "${api_vip:-}" ] && [ "${ingress_vip:-}" ]; then
			api_ip="$api_vip"
			apps_ip="$ingress_vip"
		elif [ "${starting_ip:-}" ]; then
			api_ip="$starting_ip"
			apps_ip="$starting_ip"
		else
			aba_abort "infra-dns.sh add-cluster: cannot determine cluster IPs." \
				"Set api_vip/ingress_vip or starting_ip in cluster.conf."
		fi

		_conf="/etc/dnsmasq.d/aba-${cluster_name}.${base_domain}.conf"

		$SUDO tee "$_conf" >/dev/null <<-EOF
		address=/api.${cluster_name}.${base_domain}/${api_ip}
		address=/.apps.${cluster_name}.${base_domain}/${apps_ip}
		EOF

		_dnsmasq_restart
		aba_info "DNS records added: api.${cluster_name}.${base_domain} → ${api_ip}, *.apps → ${apps_ip}"
		;;

	remove-cluster)
		# No-op if ABA doesn't own dnsmasq
		[ -f "$_MARKER" ] || exit 0

		local_name="${2:-}"
		local_domain="${3:-}"
		[ -z "$local_name" ] && exit 0
		[ -z "$local_domain" ] && exit 0

		_conf="/etc/dnsmasq.d/aba-${local_name}.${local_domain}.conf"
		[ -f "$_conf" ] || exit 0

		$SUDO rm -f "$_conf"
		_dnsmasq_restart
		aba_info "DNS records removed for cluster: ${local_name}.${local_domain}"
		;;

	add-mirror)
		# No-op if ABA doesn't own dnsmasq
		[ -f "$_MARKER" ] || exit 0

		source <(normalize-mirror-conf)

		reg_host="${reg_host:-}"
		[ -z "$reg_host" ] && exit 0

		# Determine the IP to point the registry hostname at
		local_iface=$(_pick_install_iface 2>/dev/null || true)
		if [ -n "$local_iface" ]; then
			mirror_ip=$(ip -o -4 addr show dev "$local_iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
		fi
		[ -z "${mirror_ip:-}" ] && exit 0

		_conf="/etc/dnsmasq.d/aba-mirror.conf"

		$SUDO tee "$_conf" >/dev/null <<-EOF
		address=/${reg_host}/${mirror_ip}
		EOF

		_dnsmasq_restart
		aba_info "DNS record added: ${reg_host} → ${mirror_ip}"
		;;

	remove-mirror)
		# No-op if ABA doesn't own dnsmasq
		[ -f "$_MARKER" ] || exit 0

		_conf="/etc/dnsmasq.d/aba-mirror.conf"
		[ -f "$_conf" ] || exit 0

		$SUDO rm -f "$_conf"
		_dnsmasq_restart
		aba_info "DNS record removed for mirror registry"
		;;

	check)
		# Verify dnsmasq is running (used by preflight)
		[ -f "$_MARKER" ] || exit 0

		if ! systemctl is-active --quiet dnsmasq 2>/dev/null; then
			aba_abort "ABA dnsmasq marker exists but dnsmasq is not running." \
				"Start it: sudo systemctl start dnsmasq" \
				"Or remove ABA DNS: tools/remove-dns.sh"
		fi

		if ! ss -ulnp | grep -q ':53 ' && ! ss -tlnp | grep -q ':53 '; then
			aba_abort "dnsmasq is active but port 53 is not listening." \
				"Check: journalctl -u dnsmasq"
		fi
		;;

	*)
		echo "Usage: scripts/infra-dns.sh {add-cluster|remove-cluster <name> <domain>|add-mirror|remove-mirror|check}" >&2
		exit 1
		;;
esac
