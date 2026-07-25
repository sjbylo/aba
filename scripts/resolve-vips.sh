#!/bin/bash
# resolve-vips.sh -- Resolve and populate VIP addresses in cluster.conf.
#
# INTENT: Ensure api_vip and ingress_vip are populated before infra-dns.sh
#         creates DNS records.  Detection + mutation only; no DNS validation.
# CALLED BY: Makefile.cluster (.resolve-vips target)
# CWD: cluster directory
# REQUIRES: cluster.conf, aba.conf
# PRODUCES: Updated cluster.conf with api_vip/ingress_vip populated
# SIDE EFFECTS: Writes to cluster.conf via replace-value-conf
# IDEMPOTENT: Yes

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

# Basic config validation (format/range checks only)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

cl_domain="$cluster_name.$base_domain"
cl_api_domain="api.$cl_domain"
cl_ingress_domain="*.apps.$cl_domain"

# SNO clusters use starting_ip for api+apps — no VIP resolution needed
SNO=
[ "$num_masters" -eq 1 ] && [ "$num_workers" -eq 0 ] && SNO=1

if [ "$SNO" ]; then
	[ "$api_vip" ] || [ "$ingress_vip" ] && \
		aba_warn "Cluster endpoints: api_vip and ingress_vip are not required for single-node (SNO) configuration, they will be ignored."
	exit 0
fi

# --- Non-SNO: resolve api_vip and ingress_vip ---

_is_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# If both VIPs are already set as valid IPs, skip DNS discovery
if { [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; } && \
   { [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; }; then
	aba_info "VIPs already set: api_vip=$api_vip, ingress_vip=$ingress_vip"
else
	# DNS discovery: dig for existing VIP records.
	# Skip when verify_conf=conf or off — those modes mean "no network operations"
	# (user may not be on the target network).  Auto-allocation (pure math) and
	# collision checks still run below.
	actual_ip_of_api=""
	actual_ip_of_ingress=""

	if [ "$verify_conf" = "all" ]; then
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
	else
		aba_debug "Skipping DNS discovery (verify_conf=$verify_conf, no network)"
	fi

	# Check if ABA manages DNS (dnsmasq marker from tools/setup-dns.sh)
	_aba_manages_dns=""
	[ -f /etc/dnsmasq.d/aba-upstream.conf ] && _aba_manages_dns=1

	# Determine if auto-allocation is needed (no VIP set AND no DNS record found)
	_need_auto_alloc=""
	if ! { [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; } && [ ! "$actual_ip_of_api" ]; then
		_need_auto_alloc=1
	fi
	if ! { [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; } && [ ! "$actual_ip_of_ingress" ]; then
		_need_auto_alloc=1
	fi

	if [ "$_need_auto_alloc" ] && [ "$_aba_manages_dns" ] && [ "$starting_ip" ]; then
		# Auto-allocate VIPs for ABA-managed DNS environments.
		# Prefer placing VIPs before starting_ip (starting_ip-2, starting_ip-1).
		# If that wraps out of the subnet, place after the last node (+10 gap).
		_start_int=$(ip_to_int "$starting_ip")
		_node_count=$(( ${num_masters:-3} + ${num_workers:-0} ))
		_net_int=$(ip_to_int "$machine_network")
		_subnet_size=$(( 1 << (32 - ${prefix_length:-24}) ))
		_net_end=$(( _net_int + _subnet_size - 1 ))

		# Try "before starting_ip": api=starting_ip-2, ingress=starting_ip-1
		_try_api=$(( _start_int - 2 ))
		_try_ing=$(( _start_int - 1 ))

		if [ "$_try_api" -gt "$_net_int" ] && [ "$_try_ing" -lt "$_net_end" ]; then
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

	elif ! { [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; }; then
		# api_vip not set — try to back-fill from DNS
		if [ "$actual_ip_of_api" ] && echo "$actual_ip_of_api" | grep -q -E "$_is_ip"; then
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

	# Resolve ingress_vip (may already be set from auto-allocation above)
	if ! { [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; }; then
		if [ "$actual_ip_of_ingress" ] && echo "$actual_ip_of_ingress" | grep -q -E "$_is_ip"; then
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
fi

# --- VIP collision checks (non-SNO only) ---
# Catch configuration errors before openshift-install rejects them.
if [ "$api_vip" ] && [ "$ingress_vip" ]; then
	# api_vip and ingress_vip must be different
	[ "$api_vip" = "$ingress_vip" ] && \
		aba_abort "api_vip ($api_vip) and ingress_vip ($ingress_vip) must be different!" \
			"Each VIP requires a unique IP address."

	# VIPs must not overlap with node IPs (starting_ip is the first node).
	# Uses ip_to_int() for robust range comparison — handles subnets larger
	# than /24 and IPs that wrap across octet boundaries.
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

aba_info "VIP resolution complete: api_vip=$api_vip, ingress_vip=$ingress_vip"

exit 0
