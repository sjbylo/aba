#!/bin/bash
# verify-config.sh -- Validate cluster configuration before install-config generation.
#
# INTENT: Pure validation.  Aborts on invalid config.  Never mutates cluster.conf.
#         VIP resolution/auto-allocation is handled by resolve-vips.sh (runs earlier).
#         DNS record creation is handled by infra-dns.sh (runs between resolve-vips
#         and this script).
# CALLED BY: Makefile.cluster (install-config.yaml target)
# CWD: cluster directory
# REQUIRES: cluster.conf (VIPs already populated by resolve-vips.sh), aba.conf,
#           mirror.conf
# PRODUCES: Nothing (exit 0 = valid, exit 1 = invalid)
# SIDE EFFECTS: None
# IDEMPOTENT: Yes

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$(image_source_mirror_name)
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

cl_domain="$cluster_name.$base_domain"
cl_ingress_domain="*.apps.$cl_domain"
cl_api_domain="api.$cl_domain"

# Set the rendezvous_ip to the first master's ip
export rendezvous_ip=$starting_ip

# Detect SNO (topology rules are enforced by verify-cluster-conf)
SNO=
[ "$num_masters" -eq 1 ] && [ "$num_workers" -eq 0 ] && SNO=1

# verify_conf=off: skip all validation entirely
if [ "$verify_conf" = "off" ]; then
	aba_success "Configuration validation skipped (verify_conf=off)"
	exit 0
fi

# verify_conf=conf: format/range checks (above) are done; skip network checks
if [ "$verify_conf" = "conf" ]; then
	aba_success "Configuration validation passed (network checks skipped, verify_conf=conf)"
	exit 0
fi

# --- Below runs only when verify_conf=all ---

# Helper: resolve a hostname via the cluster's DNS servers (dns_servers from aba.conf).
# Returns the IPv4 address on stdout, or empty if no cluster DNS server could resolve it.
# Sets _vc_cluster_dns_used to the server that resolved, or empty.
_vc_cluster_dns_used=""
_vc_resolve_via_cluster_dns() {
	local host="$1"
	local _ipv4_re='([0-9]{1,3}\.){3}[0-9]{1,3}'
	_vc_cluster_dns_used=""
	[ -z "$dns_servers" ] && return
	local servers
	servers=$(echo "$dns_servers" | tr ',' ' ')
	local ns ns_ip
	for ns in $servers; do
		ns_ip=$(dig +short +time=5 +tries=1 "@$ns" "$host" 2>/dev/null \
			| grep -v '^;;' | grep -Eo "$_ipv4_re" | head -1) || true
		if [ -n "$ns_ip" ]; then
			_vc_cluster_dns_used="$ns"
			echo "$ns_ip"
			return
		fi
	done
}

# _vc_check_dns: Two-step DNS validation for a hostname against an expected IP.
# Step 1: bastion's own DNS (warn on fail — bastion may not have cluster DNS records)
# Step 2: cluster DNS from dns_servers (abort on fail — this is what nodes will use)
_vc_skip_hint="To skip network checks: aba --verify conf  (or set verify_conf=conf in aba.conf)"
_vc_check_dns() {
	local fqdn="$1" expected_ip="$2" label="$3" display_fqdn="${4:-$1}"

	# Step 1: bastion's own DNS
	local _ipv4_re='([0-9]{1,3}\.){3}[0-9]{1,3}'
	aba_debug "Running: dig +time=8 +short $fqdn (bastion DNS)"
	local bastion_ip
	bastion_ip=$(dig +time=8 +short "$fqdn" 2>/dev/null \
		| grep -v '^;;' | grep -Eo "$_ipv4_re" | head -1) || true
	aba_debug "Bastion DNS result for $fqdn: '${bastion_ip:-<empty>}'"

	if [ "$bastion_ip" = "$expected_ip" ]; then
		aba_success "DNS record for $label ($display_fqdn) exists: $bastion_ip"
		return
	fi

	# Bastion DNS failed — warn (bastion may not have cluster DNS records)
	aba_warn "$display_fqdn: bastion DNS returned '${bastion_ip:-<empty>}' (expected $expected_ip)"

	# Step 2: cluster DNS (if configured and different from bastion's result)
	local cluster_ip
	cluster_ip=$(_vc_resolve_via_cluster_dns "$fqdn")

	if [ "$cluster_ip" = "$expected_ip" ]; then
		aba_success "DNS record for $label ($display_fqdn) resolved via cluster DNS ($dns_servers): $cluster_ip"
		return
	fi

	if [ -n "$cluster_ip" ]; then
		# Cluster DNS returned a different IP
		aba_abort "DNS record: $display_fqdn resolves to $cluster_ip via cluster DNS ($dns_servers), expected $expected_ip!" \
			"$_vc_skip_hint"
	fi

	# Cluster DNS also failed — check if cluster DNS is even reachable
	if [ -n "$dns_servers" ]; then
		local servers ns _reachable=""
		servers=$(echo "$dns_servers" | tr ',' ' ')
		for ns in $servers; do
			if dig +time=3 +tries=1 "@$ns" version.bind chaos txt >/dev/null 2>&1; then
				_reachable=1
				break
			fi
		done
		if [ -z "$_reachable" ]; then
			aba_warn "$display_fqdn: cluster DNS ($dns_servers) not reachable from this host — cannot verify"
			return
		fi
	fi

	# Cluster DNS is reachable but can't resolve the hostname
	aba_abort "DNS record: $display_fqdn does not resolve via cluster DNS ($dns_servers), expected $expected_ip!" \
		"Neither bastion DNS nor cluster DNS could resolve this hostname." \
		"$_vc_skip_hint"
}

# Validate API and ingress DNS records
_apps_domain="$RANDOM.apps.$cl_domain"
_apps_display="*.apps.$cl_domain"

if [ ! "$SNO" ]; then
	_vc_check_dns "$cl_api_domain" "$api_vip" "OpenShift api"
	_vc_check_dns "$_apps_domain" "$ingress_vip" "apps ingress" "$_apps_display"
else
	_vc_check_dns "$cl_api_domain" "$rendezvous_ip" "OpenShift api"
	_vc_check_dns "$_apps_domain" "$rendezvous_ip" "apps ingress" "$_apps_display"
fi

# Wildcard shadow detection: verify that api.X and *.apps.X are distinct
# records, not just caught by a parent wildcard like *.X
_wc_probe="aba-dns-wildcard-check.$cl_domain"
aba_debug "Running wildcard shadow check for $_wc_probe"

# Check via bastion DNS first, then cluster DNS
_wc_ip=$(dig +time=8 +short "$_wc_probe" 2>/dev/null \
	| grep -v '^;;' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1) || true
[ -z "$_wc_ip" ] && _wc_ip=$(_vc_resolve_via_cluster_dns "$_wc_probe")

if [ "$_wc_ip" ] && echo "$_wc_ip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
	aba_abort \
		"Wildcard DNS detected: $_wc_probe resolves to $_wc_ip" \
		"A catch-all record like *.$cl_domain exists -- OpenShift requires explicit records." \
		"Create distinct DNS records for:" \
		"  api.$cl_domain  and  *.apps.$cl_domain" \
		"$_vc_skip_hint"
fi

aba_success "Cluster configuration is valid"

exit 0
