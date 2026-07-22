#!/bin/bash 
# Script to do some simple verification of install-config.yaml

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$mirror_name
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

# These checks are actually also made in 'verify-cluster-conf'
[ ! "$cluster_name" ] && aba_abort "missing cluster_name value in cluster.conf!"
[ ! "$base_domain" ] && aba_abort "missing base_domain value in cluster.conf!"
[ ! "$starting_ip" ] && aba_abort "missing starting_ip value in cluster.conf!"
[ ! "$num_masters" ] && aba_abort "missing num_masters value in cluster.conf!"
[ ! "$num_workers" ] && aba_abort "missing num_workers value in cluster.conf!"

cl_domain="$cluster_name.$base_domain"
cl_ingress_domain="*.apps.$cl_domain"
cl_api_domain="api.$cl_domain"

# Set the rendezvous_ip to the first master's ip
export rendezvous_ip=$starting_ip

# Checking for invalid config 

SNO=
[ "$num_masters" -eq 1 ] && [ "$num_workers" -eq 0 ] && SNO=1 && aba_info "Configuration is for Single Node Openshift (SNO) ..."
[ "$num_masters" -ne 1 ] && [ "$num_masters" -ne 3 ] && aba_abort "number of masters can only be 1 or 3!"

aba_info "Master count: $num_masters is valid"

if [ "$num_masters" -eq 1 ] && [ "$num_workers" -ne 0 ]; then
	aba_abort "number of workers must be 0 if number of masters is 1 (SNO)!"
fi

aba_info "Worker count: $num_workers is valid"

# verify_conf=off: skip all validation entirely
if [ "$verify_conf" = "off" ]; then
	aba_success "Configuration validation skipped (verify_conf=off)"
	exit 0
fi

# --- DNS VIP resolution runs for both verify_conf=conf and verify_conf=all ---

aba_debug "Running: dig +time=8 +short $cl_api_domain"
_dig_err=""
actual_ip_of_api=$(dig +time=8 +short $cl_api_domain 2>"$ABA_TMP/dig-api.$$") || true
[ -s "$ABA_TMP/dig-api.$$" ] && { _dig_err=$(cat "$ABA_TMP/dig-api.$$"); aba_debug "dig api stderr: $_dig_err"; }
rm -f "$ABA_TMP/dig-api.$$"
aba_debug "dig result for $cl_api_domain: '${actual_ip_of_api:-<empty>}'"

_apps_domain="$RANDOM.apps.$cl_domain"
aba_debug "Running: dig +time=8 +short $_apps_domain"
actual_ip_of_ingress=$(dig +time=8 +short $_apps_domain 2>"$ABA_TMP/dig-apps.$$") || true  # Use $RANDOM to avoid DNS cache issue
[ -s "$ABA_TMP/dig-apps.$$" ] && { _dig_err=$(cat "$ABA_TMP/dig-apps.$$"); aba_debug "dig apps stderr: $_dig_err"; }
rm -f "$ABA_TMP/dig-apps.$$"
aba_debug "dig result for $_apps_domain: '${actual_ip_of_ingress:-<empty>}'"

# Check if ABA manages DNS (dnsmasq marker from tools/setup-dns.sh)
_aba_manages_dns=""
[ -f /etc/dnsmasq.d/aba-upstream.conf ] && _aba_manages_dns=1

# If not SNO, then ensure api_vip and ingress_vip are defined 
if [ ! "$SNO" ]; then

	# Auto-allocate both VIPs when ABA manages DNS and neither VIP nor DNS exists.
	# Prefer placing VIPs before starting_ip (starting_ip-2, starting_ip-1).
	# If that wraps out of the subnet, place after the last node (+10 gap).
	_need_auto_alloc=""
	_is_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

	if ! { [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; } && [ ! "$actual_ip_of_api" ]; then
		_need_auto_alloc=1
	fi
	if ! { [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; } && [ ! "$actual_ip_of_ingress" ]; then
		_need_auto_alloc=1
	fi

	if [ "$_need_auto_alloc" ] && [ "$_aba_manages_dns" ] && [ "$starting_ip" ]; then
		# Auto-allocate VIPs for ABA-managed DNS environments
		_start_int=$(ip_to_int "$starting_ip")
		_node_count=$(( ${num_masters:-3} + ${num_workers:-0} ))
		_net_int=$(ip_to_int "$machine_network")
		# Subnet size: 2^(32-prefix_length)
		_subnet_size=$(( 1 << (32 - ${prefix_length:-24}) ))
		_net_end=$(( _net_int + _subnet_size - 1 ))

		# Try "before starting_ip": api=starting_ip-2, ingress=starting_ip-1
		_try_api=$(( _start_int - 2 ))
		_try_ing=$(( _start_int - 1 ))

		if [ "$_try_api" -gt "$_net_int" ] && [ "$_try_ing" -lt "$_net_end" ]; then
			# "Before" placement fits within the subnet
			api_vip=$(int_to_ip "$_try_api")
			ingress_vip=$(int_to_ip "$_try_ing")
		else
			# "Before" wraps out of subnet — place after last node (+10 gap)
			_after_api=$(( _start_int + _node_count + 10 ))
			_after_ing=$(( _start_int + _node_count + 11 ))
			if [ "$_after_ing" -lt "$_net_end" ]; then
				api_vip=$(int_to_ip "$_after_api")
				ingress_vip=$(int_to_ip "$_after_ing")
			else
				aba_abort "Cannot auto-allocate VIPs: no room in subnet $machine_network/$prefix_length." \
					"Set api_vip and ingress_vip explicitly in cluster.conf."
			fi
		fi

		aba_info "Auto-allocated VIPs: api_vip=$api_vip, ingress_vip=$ingress_vip (ABA-managed DNS)"
		replace-value-conf -n api_vip -v "$api_vip" cluster.conf
		replace-value-conf -n ingress_vip -v "$ingress_vip" cluster.conf
		_vips_auto_allocated=1  # Skip DNS validation below — records created by infra-dns.sh later
	fi

	# Validate api_vip: from cluster.conf, DNS, or auto-allocated above
	if [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; then
		aba_info "API endpoint: api_vip=$api_vip is defined"
	else
		if [ "$actual_ip_of_api" ] && echo "$actual_ip_of_api" | grep -q -E "$_is_ip"; then
			# DNS record found — auto-populate cluster.conf
			aba_warn -p Attention \
				"inserting actual IP address ($actual_ip_of_api) into cluster.conf" \
				"Please verify this is correct! If not, edit cluster.conf file and try again!" 
			replace-value-conf -n api_vip -v "$actual_ip_of_api" cluster.conf
			sleep 1
			api_vip=$actual_ip_of_api
		else
			aba_abort "Missing DNS record $cl_api_domain" \
				"Create DNS records for api.$cluster_name.$base_domain or set api_vip in cluster.conf."
		fi
	fi

	# Validate ingress_vip: from cluster.conf, DNS, or auto-allocated above
	if [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; then
		aba_info "Ingress endpoint: ingress_vip=$ingress_vip is defined"
	else
		if [ "$actual_ip_of_ingress" ] && echo "$actual_ip_of_ingress" | grep -q -E "$_is_ip"; then
			# DNS record found — auto-populate cluster.conf
			aba_warn -p Attention \
				"inserting actual IP address ($actual_ip_of_ingress) into cluster.conf" \
				"Please verify this is correct! If not, edit cluster.conf file and try again!"
			replace-value-conf -n ingress_vip -v "$actual_ip_of_ingress" cluster.conf
			sleep 1
			ingress_vip=$actual_ip_of_ingress
		else
			aba_abort "Missing DNS record $cl_ingress_domain!" \
				"Create DNS records for *.apps.$cluster_name.$base_domain or set ingress_vip in cluster.conf."
		fi
	fi
else
	[ "$api_vip" ] || [ "$ingress_vip" ] && \
		aba_warn "Cluster endpoints: api_vip and ingress_vip are not required for single-node (SNO) configuration, they will be ignored."
fi

# --- VIP collision checks (non-SNO only) ---
# Catch configuration errors before openshift-install rejects them.
if [ ! "$SNO" ] && [ "$api_vip" ] && [ "$ingress_vip" ]; then
	# api_vip and ingress_vip must be different
	[ "$api_vip" = "$ingress_vip" ] && \
		aba_abort "api_vip ($api_vip) and ingress_vip ($ingress_vip) must be different!" \
			"Each VIP requires a unique IP address."

	# VIPs must not overlap with node IPs (starting_ip is the first node).
	# Uses ip_to_int() from include_all.sh for robust range comparison —
	# handles subnets larger than /24 and IPs that wrap across octet boundaries.
	if [ "$starting_ip" ]; then
		_node_start=$(ip_to_int "$starting_ip")
		_node_count=$(( ${num_masters:-3} + ${num_workers:-0} ))
		_node_end=$(( _node_start + _node_count - 1 ))
		_api_int=$(ip_to_int "$api_vip")
		_ing_int=$(ip_to_int "$ingress_vip")

		if [ "$_api_int" -ge "$_node_start" ] && [ "$_api_int" -le "$_node_end" ]; then
			aba_abort "api_vip ($api_vip) falls within the node IP range ($starting_ip + $_node_count nodes)!" \
				"VIPs must be outside the node IP range."
		fi
		if [ "$_ing_int" -ge "$_node_start" ] && [ "$_ing_int" -le "$_node_end" ]; then
			aba_abort "ingress_vip ($ingress_vip) falls within the node IP range ($starting_ip + $_node_count nodes)!" \
				"VIPs must be outside the node IP range."
		fi
	fi
fi

# verify_conf=conf: VIP resolution (above) is done; skip remaining network checks
if [ "$verify_conf" = "conf" ]; then
	aba_success "Configuration validation passed (network checks skipped, verify_conf=conf)"
	exit 0
fi

# --- Below runs only when verify_conf=all ---

[ ! "$actual_ip_of_api" ] && actual_ip_of_api="<empty>"
[ ! "$actual_ip_of_ingress" ] && actual_ip_of_ingress="<empty>"

# If NOT SNO...
if [ ! "$SNO" ]; then
	if [ "${_vips_auto_allocated:-}" ]; then
		# VIPs were just auto-allocated — DNS records will be created by
		# infra-dns.sh (runs after this script via Makefile dependency).
		# Skip DNS validation; it would fail because records don't exist yet.
		aba_info "DNS validation skipped (VIPs auto-allocated, infra-dns.sh will create records)"
	else
		# Ensure api DNS exists and points to correct ip
		[ "$actual_ip_of_api" != "$api_vip" ] && \
			aba_abort "DNS record: $cl_api_domain does not resolve to $api_vip, it resolves to $actual_ip_of_api!" \
				"To skip network checks, set verify_conf=conf in aba.conf"

		aba_info "DNS record for OpenShift api ($cl_api_domain) exists: $actual_ip_of_api"

		# Ensure apps DNS exists and points to correct ip
		[ "$actual_ip_of_ingress" != "$ingress_vip" ] && \
			aba_abort "DNS record: $cl_ingress_domain does not resolve to $ingress_vip, it resolves to $actual_ip_of_ingress!" \
				"To skip network checks, set verify_conf=conf in aba.conf"

		aba_info "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
	fi
else
	# For SNO...
	if [ "${_aba_manages_dns:-}" ] && { [ "$actual_ip_of_api" = "<empty>" ] || [ -z "$actual_ip_of_api" ]; }; then
		# ABA manages DNS but records don't exist yet — infra-dns.sh will
		# create them after this script (Makefile dependency order).
		aba_info "DNS validation skipped for SNO (ABA-managed DNS, infra-dns.sh will create records)"
	else
		# Check values are both pointing to "rendezvous_ip"
		[ "$actual_ip_of_api" != "$rendezvous_ip" ] && \
			aba_abort "DNS record $cl_api_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_api!" \
				"To skip network checks, set verify_conf=conf in aba.conf"

		aba_info "DNS record for OpenShift api ($cl_api_domain) exists: $actual_ip_of_api"

		# Ensure apps DNS exists
		[ "$actual_ip_of_ingress" != "$rendezvous_ip" ] && \
			aba_abort "DNS record $cl_ingress_domain does not resolve to the rendezvous ip: $rendezvous_ip, it resolves to $actual_ip_of_ingress!" \
				"To skip network checks, set verify_conf=conf in aba.conf"

		aba_info "DNS record for apps ingress ($cl_ingress_domain) exists: $actual_ip_of_ingress"
	fi
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

