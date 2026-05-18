# BMC MAC discovery library for Phase 10 preflight wiring.
# Sourced (not executed): no shebang, not chmod +x.
# Must be sourced AFTER scripts/bmc-redfish.sh and scripts/bmc-adapter-generic.sh
# (the latter provides _bm_get_ethernetinterfaces, the canonical DSP0266 wrapper
# this library calls into; vendor overlays may redefine that function via bash
# function-redefine-wins semantics).
#
# Public API (vendor-agnostic helpers; Redfish wrapper itself lives in
# scripts/bmc-adapter-generic.sh per the generic-with-vendor-override pattern):
#   _bm_filter_enabled_up
#     - stdin: pipe-format NIC lines from _bm_get_ethernetinterfaces
#       ("nic_id|mac|link_status|enabled|interface_type|name")
#     - stdout: subset matching D-04 (LinkUp + InterfaceEnabled) and not a
#       bond/team entry per D-06.
#
#   _bm_resolve_mac <node> <all_nics_pipe_format>
#     - D-05 explicit-or-fail resolver. Sets _BM_DISCOVERED_MAC and
#       _BM_DISCOVERED_NIC_ID on success (exactly one surviving NIC).
#     - Returns 4 on MAC-04 (no candidates), 5 on MAC-05 (ambiguous), 0 on hit.
#
#   _bm_get_mac <node>
#     - D-03 single consumer-facing helper. Resolution order:
#       1. operator-supplied mac_<node> (sourced from bmc.conf upstream;
#          cluster.conf is also a supported location when consumed via the
#          normalize-cluster-conf pathway),
#       2. discovered_mac from .bmc-state.<node> sidecar (not "disabled"),
#       3. hard-fail with MAC-unavailable warning.
#     - stdout: MAC address. Return 0 on hit, 1 on miss.
#
# Invariants (mirror scripts/bmc-redfish.sh):
#   - The Redfish-touching wrapper (_bm_get_ethernetinterfaces in
#     bmc-adapter-generic.sh) is the only allowed HTTP path; this file does NOT
#     issue HTTP requests directly.
#   - Every counter uses var=$(( var + 1 )) (Phase 5 D-11; ERR-trap-safe).
#   - jq only after HTTP 2xx gate (enforced inside the wrapper).
#   - Never `2>/dev/null` on a Redfish call (UX-05).
#   - Error strings begin with "BMC: <node> MAC-XX:" (UX-03 prefix; D-10 error
#     namespace introduced by Phase 10).
#   - Sidecar reads use `grep | cut`, never `source` or `eval`, so a corrupt
#     sidecar cannot inject shell.

_BM_DISCOVERED_MAC=""
_BM_DISCOVERED_NIC_ID=""

_bm_filter_enabled_up() {
	# D-04 filter: keep LinkUp + InterfaceEnabled.
	# D-06 filter: drop bond/team entries (interface_type=Bond or name contains
	# bond/team/master case-insensitively; iRMC emits iLO-bond0 style ids per
	# Phase 10 specifics block).
	# Reads stdin, emits filtered stdout. No globals touched.
	local line nic_id mac link enabled iftype name lname
	while IFS='|' read -r nic_id mac link enabled iftype name; do
		[ -z "$nic_id" ] && continue
		[ "$link" = "LinkUp" ] || continue
		[ "$enabled" = "true" ] || continue
		[ "$iftype" = "Bond" ] && continue
		lname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
		case "$lname" in
			*bond*|*team*|*master*) continue ;;
		esac
		# Also reject bond shape carried on nic_id (iRMC iLO-bond0).
		local lnid
		lnid=$(printf '%s' "$nic_id" | tr '[:upper:]' '[:lower:]')
		case "$lnid" in
			*bond*|*team*) continue ;;
		esac
		printf '%s|%s|%s|%s|%s|%s\n' "$nic_id" "$mac" "$link" "$enabled" "$iftype" "$name"
	done
}

_bm_resolve_mac() {
	# D-05 explicit-or-fail resolver. Vendor-agnostic.
	# Args: $1=node, $2=all NICs in pipe format (multi-line string from
	# _bm_get_ethernetinterfaces).
	# Side effect on success: sets _BM_DISCOVERED_MAC + _BM_DISCOVERED_NIC_ID
	# in the enclosing shell scope via printf -v with fixed (non-dynamic) names.
	# Returns: 0 on single-candidate hit, 4 on no candidates (MAC-04),
	# 5 on ambiguous (MAC-05).
	local node="$1"
	local all_nics="$2"
	local filtered count
	filtered=$(printf '%s\n' "$all_nics" | _bm_filter_enabled_up)
	if [ -z "$filtered" ]; then
		count=0
	else
		count=$(printf '%s\n' "$filtered" | grep -c '^')
	fi

	_BM_DISCOVERED_MAC=""
	_BM_DISCOVERED_NIC_ID=""

	if [ "$count" -eq 0 ]; then
		aba_warning "BMC: $node MAC-04: no enabled NIC with link reported"
		return 4
	fi

	if [ "$count" -eq 1 ]; then
		local nic_id mac rest
		IFS='|' read -r nic_id mac rest <<<"$filtered"
		printf -v _BM_DISCOVERED_MAC '%s' "$mac"
		printf -v _BM_DISCOVERED_NIC_ID '%s' "$nic_id"
		return 0
	fi

	# count > 1: build "nic_id=mac" list (D-07: never auto-pick via BootOrder /
	# ProvisioningInterface; explicit-or-fail only).
	local list="" line nic_id mac rest
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		IFS='|' read -r nic_id mac rest <<<"$line"
		if [ -z "$list" ]; then
			list="${nic_id}=${mac}"
		else
			list="${list}, ${nic_id}=${mac}"
		fi
	done <<<"$filtered"
	aba_warning "BMC: $node MAC-05: ambiguous - candidates for $node: [$list]; set mac_${node}=<address> in bmc.conf to disambiguate"
	return 5
}

_bm_get_mac() {
	# D-03 single consumer-facing helper.
	# Resolution order:
	#   1. operator-supplied mac_<node> from bmc.conf (or cluster.conf when
	#      consumed via the normalize-cluster-conf pathway upstream).
	#   2. discovered_mac in .bmc-state.<node> (excluding the literal "disabled"
	#      sentinel written by the opt-out path).
	#   3. hard-fail with MAC-unavailable warning, return 1.
	# stdout: MAC address on success; nothing on miss.
	local node="$1"
	local op_var="mac_${node}"
	local op_val="${!op_var:-}"
	if [ -n "$op_val" ]; then
		printf '%s' "$op_val"
		return 0
	fi

	local sidecar=".bmc-state.${node}"
	if [ -f "$sidecar" ]; then
		local disc
		disc=$(grep '^discovered_mac=' "$sidecar" | cut -d= -f2)
		if [ -n "$disc" ] && [ "$disc" != "disabled" ]; then
			printf '%s' "$disc"
			return 0
		fi
	fi

	aba_warning "BMC: $node MAC unavailable - no operator mac_${node} and no discovered_mac in .bmc-state.${node}"
	return 1
}
