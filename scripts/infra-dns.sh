#!/bin/bash
# infra-dns.sh -- Manage per-cluster DNS records in ABA's dnsmasq.
#
# Called automatically by:
#   - Makefile.cluster (.infra-dns target) during install → add-cluster
#   - aba.sh delete flow → remove-cluster
#
# All commands are no-ops if ABA's dnsmasq marker does not exist.
# This script is NOT intended for direct user invocation.
#
# Usage:
#   scripts/infra-dns.sh add-cluster            (reads cluster.conf from CWD)
#   scripts/infra-dns.sh remove-cluster <name>
#   scripts/infra-dns.sh check

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$_SCRIPT_DIR/include_all.sh"

_MARKER="/etc/dnsmasq.d/aba-upstream.conf"

_dnsmasq_restart() {
	$SUDO systemctl restart dnsmasq 2>/dev/null || \
		aba_warn "Failed to restart dnsmasq. Check: systemctl status dnsmasq"
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

		_conf="/etc/dnsmasq.d/aba-${cluster_name}.conf"

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
		[ -z "$local_name" ] && exit 0

		_conf="/etc/dnsmasq.d/aba-${local_name}.conf"
		[ -f "$_conf" ] || exit 0

		$SUDO rm -f "$_conf"
		_dnsmasq_restart
		aba_info "DNS records removed for cluster: ${local_name}"
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
		echo "Usage: scripts/infra-dns.sh {add-cluster|remove-cluster <name>|check}" >&2
		exit 1
		;;
esac
