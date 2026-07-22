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
export regcreds_dir=$HOME/.aba/mirror/$mirror_name
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

# Dig DNS to validate records match expected IPs
aba_debug "Running: dig +time=8 +short $cl_api_domain"
_dig_err=""
actual_ip_of_api=$(dig +time=8 +short $cl_api_domain 2>"$ABA_TMP/dig-api.$$") || true
[ -s "$ABA_TMP/dig-api.$$" ] && { _dig_err=$(cat "$ABA_TMP/dig-api.$$"); aba_debug "dig api stderr: $_dig_err"; }
rm -f "$ABA_TMP/dig-api.$$"
aba_debug "dig result for $cl_api_domain: '${actual_ip_of_api:-<empty>}'"

_apps_domain="$RANDOM.apps.$cl_domain"
aba_debug "Running: dig +time=8 +short $_apps_domain"
actual_ip_of_ingress=$(dig +time=8 +short $_apps_domain 2>"$ABA_TMP/dig-apps.$$") || true
[ -s "$ABA_TMP/dig-apps.$$" ] && { _dig_err=$(cat "$ABA_TMP/dig-apps.$$"); aba_debug "dig apps stderr: $_dig_err"; }
rm -f "$ABA_TMP/dig-apps.$$"
aba_debug "dig result for $_apps_domain: '${actual_ip_of_ingress:-<empty>}'"

[ ! "$actual_ip_of_api" ] && actual_ip_of_api="<empty>"
[ ! "$actual_ip_of_ingress" ] && actual_ip_of_ingress="<empty>"

if [ ! "$SNO" ]; then
	# Non-SNO: DNS must resolve to the configured VIPs
	[ "$actual_ip_of_api" != "$api_vip" ] && \
		aba_abort "DNS record: $cl_api_domain does not resolve to $api_vip, it resolves to $actual_ip_of_api!" \
			"To skip network checks, set verify_conf=conf in aba.conf"

	aba_info "DNS record for OpenShift api ($cl_api_domain) exists: $actual_ip_of_api"

	[ "$actual_ip_of_ingress" != "$ingress_vip" ] && \
		aba_abort "DNS record: $cl_ingress_domain does not resolve to $ingress_vip, it resolves to $actual_ip_of_ingress!" \
			"To skip network checks, set verify_conf=conf in aba.conf"

	aba_info "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
else
	# SNO: DNS must resolve to the rendezvous_ip (starting_ip)
	[ "$actual_ip_of_api" != "$rendezvous_ip" ] && \
		aba_abort "DNS record $cl_api_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_api!" \
			"To skip network checks, set verify_conf=conf in aba.conf"

	aba_info "DNS record for OpenShift api ($cl_api_domain) exists: $actual_ip_of_api"

	[ "$actual_ip_of_ingress" != "$rendezvous_ip" ] && \
		aba_abort "DNS record $cl_ingress_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_ingress!" \
			"To skip network checks, set verify_conf=conf in aba.conf"

	aba_info "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
fi

# Wildcard shadow detection: verify that api.X and *.apps.X are distinct
# records, not just caught by a parent wildcard like *.X
_wc_probe="aba-dns-wildcard-check.$cl_domain"
aba_debug "Running: dig +time=8 +short $_wc_probe (wildcard shadow check)"
_wc_ip=$(dig +time=8 +short "$_wc_probe" 2>"$ABA_TMP/dig-wc.$$") || true
[ -s "$ABA_TMP/dig-wc.$$" ] && aba_debug "dig wildcard stderr: $(cat "$ABA_TMP/dig-wc.$$")"
rm -f "$ABA_TMP/dig-wc.$$"

if [ "$_wc_ip" ] && echo "$_wc_ip" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
	aba_abort \
		"Wildcard DNS detected: $_wc_probe resolves to $_wc_ip" \
		"A catch-all record like *.$cl_domain exists -- OpenShift requires explicit records." \
		"Create distinct DNS records for:" \
		"  api.$cl_domain  and  *.apps.$cl_domain" \
		"To skip network checks, set verify_conf=conf in aba.conf"
fi

aba_success "Cluster configuration is valid"

exit 0
