#!/bin/bash -e
# Pre-flight validation: DNS/NTP reachability + IP conflict detection
# Runs from cluster directory before ISO generation.
# Designed for extensibility — IICCCN-55 vSphere checks can source and extend.

source scripts/include_all.sh
aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

# Error/warning counters (accessible to extensions)
_preflight_warnings=0
_preflight_errors=0

preflight_check_dns() {
	[ ! "$dns_servers" ] && aba_info "No DNS servers configured, skipping DNS check" && return

	local servers
	servers=$(echo "$dns_servers" | tr ',' ' ')
	local total=0
	local failed=0

	for ip in $servers; do
		total=$((total + 1))
		# Self-referencing query — works in air-gapped environments (no internet needed)
		if dig @"$ip" +time=3 +tries=1 version.bind chaos txt >/dev/null 2>&1; then
			aba_info_ok "DNS server $ip is reachable"
		else
			aba_warning "DNS server $ip is not reachable"
			failed=$((failed + 1))
			_preflight_warnings=$((_preflight_warnings + 1))
		fi
	done

	# Guard: no tokens produced (e.g. dns_servers was commas/spaces only)
	[ $total -eq 0 ] && aba_info "No valid DNS server entries found, skipping DNS check" && return

	# If ALL DNS servers unreachable, escalate to error
	if [ $failed -eq $total ]; then
		_preflight_errors=$((_preflight_errors + 1))
		# Undo the warnings that were already counted, replace with single error
		_preflight_warnings=$((_preflight_warnings - failed))
		aba_warning "All $total DNS server(s) are unreachable!"
	fi
}

preflight_check_ntp() {
	[ ! "$ntp_servers" ] && aba_info "No NTP servers configured, skipping NTP check" && return

	local servers
	servers=$(echo "$ntp_servers" | tr ',' ' ')
	local total=0
	local failed=0

	# Determine NTP probe method once, before iterating servers
	local ntp_method="udp"
	command -v chronyd >/dev/null 2>&1 && ntp_method="chronyd"

	for host in $servers; do
		total=$((total + 1))
		if [ "$ntp_method" = "chronyd" ]; then
			# chronyd -Q queries without changing system clock, no root needed
			if timeout 5 chronyd -Q "server $host iburst" >/dev/null 2>&1; then
				aba_info_ok "NTP server $host is reachable"
			else
				aba_warning "NTP server $host is not reachable"
				failed=$((failed + 1))
				_preflight_warnings=$((_preflight_warnings + 1))
			fi
		else
			# Fallback: UDP port check
			if timeout 3 bash -c "echo >/dev/udp/$host/123" 2>/dev/null; then
				aba_info_ok "NTP server $host is reachable (UDP port 123)"
			else
				aba_warning "NTP server $host is not reachable"
				failed=$((failed + 1))
				_preflight_warnings=$((_preflight_warnings + 1))
			fi
		fi
	done

	# Guard: no tokens produced (e.g. ntp_servers was commas/spaces only)
	[ $total -eq 0 ] && aba_info "No valid NTP server entries found, skipping NTP check" && return

	# If ALL NTP servers unreachable, escalate to error
	if [ $failed -eq $total ]; then
		_preflight_errors=$((_preflight_errors + 1))
		_preflight_warnings=$((_preflight_warnings - failed))
		aba_warning "All $total NTP server(s) are unreachable!"
	fi
}

preflight_check_ip_conflicts() {
	[ ! "$starting_ip" ] && aba_info "No starting_ip configured, skipping IP conflict check" && return
	[ ! "$num_masters" ] && return

	local num_nodes=$((num_masters + ${num_workers:-0}))
	local -a cluster_ips=()

	# Collect VIP addresses (skip for SNO)
	if [ $num_masters -ne 1 ] || [ "${num_workers:-0}" -ne 0 ]; then
		[ "$api_vip" ] && cluster_ips+=("$api_vip")
		[ "$ingress_vip" ] && cluster_ips+=("$ingress_vip")
	fi

	# Collect node IPs: sequential from starting_ip
	local current_int
	current_int=$(ip_to_int "$starting_ip")
	for ((i = 0; i < num_nodes; i++)); do
		cluster_ips+=("$(int_to_ip $current_int)")
		current_int=$((current_int + 1))
	done

	# Get bastion's own IPs to skip them
	local bastion_ips
	bastion_ips=$(hostname -I 2>/dev/null || true)

	# Determine IP conflict detection method: arping (Layer 2, can't be firewalled) preferred over ping (ICMP)
	local ip_check_method="ping"
	if command -v arping >/dev/null 2>&1; then
		ip_check_method="arping"
	fi
	aba_info "Checking IP conflicts using $ip_check_method"

	local conflicts=0
	local arping_rc=0
	local arping_err=""
	for ip in "${cluster_ips[@]}"; do
		# Skip bastion's own IPs
		if echo "$bastion_ips" | grep -qw "$ip" 2>/dev/null; then
			aba_debug "Skipping bastion IP $ip"
			continue
		fi

		if [ "$ip_check_method" = "arping" ]; then
			# arping can't reliably auto-detect the outgoing interface on multi-homed
			# hosts (multiple NICs/VLANs), so use 'ip route get' to determine it.
			local iface=""
			iface=$(ip route get "$ip" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)

			if [ -z "$iface" ]; then
				aba_debug "Could not determine interface for $ip, falling back to ping"
				if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
					aba_warning "IP conflict: $ip is already in use!"
					_preflight_errors=$((_preflight_errors + 1))
					conflicts=$((conflicts + 1))
				else
					aba_debug "IP $ip is available"
				fi
				continue
			fi

			aba_debug "Using interface $iface for arping $ip"
			arping_err=$(arping -c 1 -w 2 -I "$iface" "$ip" 2>&1 >/dev/null) && arping_rc=0 || arping_rc=$?
			if [ $arping_rc -eq 0 ]; then
				aba_warning "IP conflict: $ip is already in use!"
				_preflight_errors=$((_preflight_errors + 1))
				conflicts=$((conflicts + 1))
			elif echo "$arping_err" | grep -qi "permission\|operation not permitted\|setuid\|socket\|invalid option\|device" 2>/dev/null; then
				# arping can fail for reasons other than "no reply" (permissions, missing device);
				# fall back to ping for this and all subsequent IPs
				aba_warning "arping failed ($arping_err), falling back to ping"
				ip_check_method="ping"
				if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
					aba_warning "IP conflict: $ip is already in use!"
					_preflight_errors=$((_preflight_errors + 1))
					conflicts=$((conflicts + 1))
				else
					aba_debug "IP $ip is available"
				fi
			else
				aba_debug "IP $ip is available"
			fi
		else
			if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
				aba_warning "IP conflict: $ip is already in use!"
				_preflight_errors=$((_preflight_errors + 1))
				conflicts=$((conflicts + 1))
			else
				aba_debug "IP $ip is available"
			fi
		fi
	done

	if [ $conflicts -eq 0 ]; then
		aba_info_ok "No IP conflicts detected for $num_nodes node(s)"
	fi
}

# Run all platform-agnostic checks
preflight_check_dns
preflight_check_ntp
preflight_check_ip_conflicts

# Hook for platform-specific extensions (IICCCN-55)
if [ "$platform" = "vmw" ] && [ -f scripts/preflight-check-vsphere.sh ]; then
	source scripts/preflight-check-vsphere.sh
	preflight_check_vsphere
fi

# Summary
if [ $_preflight_errors -gt 0 ]; then
	aba_abort "Pre-flight failed: $_preflight_errors error(s), $_preflight_warnings warning(s)"
fi
if [ $_preflight_warnings -gt 0 ]; then
	aba_warning "Pre-flight completed with $_preflight_warnings warning(s)"
	sleep 2
fi
aba_info_ok "Pre-flight validation passed"

exit 0
