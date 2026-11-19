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

# First Makefile step of install. Open the config step before VIP lookups so
# the progress dialog is not stuck at 0% while DNS and YAML generation run.
aba_progress "START|ci_config"

aba_debug "Starting: $0 $* in $PWD"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

# Basic config validation (format/range checks only)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

cl_domain="$cluster_name.$base_domain"
cl_api_domain="api.$cl_domain"
cl_ingress_domain="*.apps.$cl_domain"

# A starting_ip list names each node IP and may leave gaps.  Keep the node IPs
# space padded for the membership tests below.  One starting IP leaves it empty.
# Expand before the SNO exit: with verify_conf=off a bad list must stop here,
# not reach the DNS records.
_node_ips=""
if [[ "$starting_ip" == *,* ]]; then
	_node_ips=" $(expand_starting_ips "$starting_ip" $(( ${num_masters:-3} + ${num_workers:-0} ))) " || exit 1
fi

# Step from INT by STEP (-1 or 1) past listed node IPs.  Prints the integer.
_skip_node_ips() {
	local n=$1
	while [[ "$_node_ips" == *" $(int_to_ip "$n") "* ]]; do
		n=$(( n + $2 ))
	done
	echo "$n"
}

# SNO clusters use starting_ip for api+apps — no VIP resolution needed
SNO=
is_sno && SNO=1

if [ "$SNO" ]; then
	[ "$api_vip" ] || [ "$ingress_vip" ] && \
		aba_warn "Cluster endpoints: api_vip and ingress_vip are not required for single-node (SNO) configuration, they will be ignored."
	exit 0
fi

# --- Non-SNO: resolve api_vip and ingress_vip ---

_is_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# dig +short can print a CNAME and then several addresses. The VIP is the first IPv4 line.
first_ipv4() {
	printf '%s\n' "$1" | grep -m1 -E "$_is_ip" || true
}

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
		# A list: count from the first listed node IP and step past listed node IPs
		if [ "$_node_ips" ]; then
			read -r _first_ip _ <<< "$_node_ips"
			_start_int=$(ip_to_int "$_first_ip")
		else
			_start_int=$(ip_to_int "$starting_ip")
		fi
		_node_count=$(( ${num_masters:-3} + ${num_workers:-0} ))
		_net_int=$(ip_to_int "$machine_network")
		_subnet_size=$(( 1 << (32 - ${prefix_length:-24}) ))
		_net_end=$(( _net_int + _subnet_size - 1 ))

		# Try "before starting_ip": api=starting_ip-2, ingress=starting_ip-1
		_try_api=$(( _start_int - 2 ))
		_try_ing=$(( _start_int - 1 ))
		if [ "$_node_ips" ]; then
			_try_ing=$(_skip_node_ips "$_try_ing" -1)
			_try_api=$(_skip_node_ips $(( _try_ing - 1 )) -1)
		fi

		# Candidates only. A VIP that is already a valid IP must stay.
		_new_api=""
		_new_ing=""
		if [ "$_try_api" -gt "$_net_int" ] && [ "$_try_ing" -lt "$_net_end" ]; then
			_new_api=$(int_to_ip "$_try_api")
			_new_ing=$(int_to_ip "$_try_ing")
		else
			# "Before" wraps out of subnet — place after last node (+10 gap)
			_after_api=$(( _start_int + _node_count + 10 ))
			_after_ing=$(( _start_int + _node_count + 11 ))
			if [ "$_node_ips" ]; then
				_after_api=$(_skip_node_ips "$_after_api" 1)
				_after_ing=$(_skip_node_ips $(( _after_api + 1 )) 1)
			fi
			if [ "$_after_ing" -lt "$_net_end" ]; then
				_new_api=$(int_to_ip "$_after_api")
				_new_ing=$(int_to_ip "$_after_ing")
			else
				aba_abort "Cannot auto-allocate VIPs: no room in subnet $machine_network/$prefix_length." \
					"Set api_vip and ingress_vip explicitly in cluster.conf."
			fi
		fi

		if ! { [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; }; then
			api_vip="$_new_api"
			replace-value-conf -n api_vip -v "$api_vip" cluster.conf
		fi
		if ! { [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; }; then
			ingress_vip="$_new_ing"
			replace-value-conf -n ingress_vip -v "$ingress_vip" cluster.conf
		fi

		aba_info "Auto-allocated VIPs: api_vip=$api_vip, ingress_vip=$ingress_vip (ABA-managed DNS)"

	elif ! { [ "$api_vip" ] && echo "$api_vip" | grep -q -E "$_is_ip"; }; then
		# api_vip not set — try to back-fill from DNS
		_api_ip=$(first_ipv4 "$actual_ip_of_api")
		if [ "$_api_ip" ]; then
			aba_info "Resolved $cl_api_domain → $_api_ip (saved to $cluster_name/cluster.conf)"
			replace-value-conf -q -n api_vip -v "$_api_ip" cluster.conf
			api_vip=$_api_ip
		else
			aba_abort "Missing DNS record $cl_api_domain" \
				"Create DNS records for api.$cluster_name.$base_domain or set api_vip in cluster.conf."
		fi
	fi

	# Resolve ingress_vip (may already be set from auto-allocation above)
	if ! { [ "$ingress_vip" ] && echo "$ingress_vip" | grep -q -E "$_is_ip"; }; then
		_ingress_ip=$(first_ipv4 "$actual_ip_of_ingress")
		if [ "$_ingress_ip" ]; then
			aba_info "Resolved $cl_ingress_domain → $_ingress_ip (saved to $cluster_name/cluster.conf)"
			replace-value-conf -q -n ingress_vip -v "$_ingress_ip" cluster.conf
			ingress_vip=$_ingress_ip
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
	# A list may leave gaps: a VIP collides only if it is a listed node IP.
	# Node IPs are canonical, so compare the canonical VIP.
	if [ "$_node_ips" ]; then
		for _vip_name in api_vip ingress_vip; do
			_vip_val=$(normalize_ipv4 "${!_vip_name}") || _vip_val=${!_vip_name}
			if [[ "$_node_ips" == *" $_vip_val "* ]]; then
				aba_abort "$_vip_name (${!_vip_name}) is a node IP in starting_ip!" \
					"VIPs must not be node IPs."
			fi
		done
	elif [ "$starting_ip" ]; then
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
