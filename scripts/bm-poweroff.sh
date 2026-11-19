#!/bin/bash
# Power off every bare-metal node in bmc.conf through its BMC (Redfish).
# Called by 'aba stop' (GracefulShutdown) and 'aba kill' / 'aba poweroff' (ForceOff)
# on platform=bm. Returns after each node reports PowerState=Off, so the node IPs
# and VIPs are free for the next install. Does not eject media or change the boot override.

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

reset_type="${1:-}"
case "$reset_type" in
	GracefulShutdown|ForceOff) ;;
	*) aba_abort "Usage: $0 GracefulShutdown|ForceOff" ;;
esac

bmc_has_hosts || aba_abort "No BMC hosts in bmc.conf: aba cannot power off the bare-metal nodes." \
	"Power the servers off in the BMC UI."

source <(normalize-aba-conf)  # Fetch the 'ask' param
normalize-bmc-conf >/dev/null
source scripts/bmc-redfish.sh
source scripts/bmc-adapter-generic.sh

node_list=$(bmc_host_list)

if [ "${ask:-}" ]; then
	ask "Power off ($reset_type) bare-metal node(s): ${node_list//$'\n'/ }" || exit 0
fi

# Some BMCs (iRMC S4, some iLO) drop the session on a power change, so the Off poll
# gets 401. Log in once more and poll again; the node is then Off or PoweringOff,
# so bmc_power_off sends no second Reset.
_bm_retry_after_401() {
	[ "$_REDFISH_LAST_CODE" = "401" ] || return 1
	aba_debug "BMC: $1 401 during power-off, re-authenticating once"
	_bm_delete_session "$1" || true
	bmc_session_login "$1" && bmc_power_off "$1" "$reset_type"
}

total=0
ok_count=0
failed_list=""

for node in $node_list; do
	total=$(( total + 1 ))
	type_var="bmc_type_${node}"
	adapter="${!type_var}"

	# Re-source generic to revert any prior iRMC overlay before applying this node's overlay.
	source scripts/bmc-adapter-generic.sh
	if [ "$adapter" = "irmc" ]; then
		source scripts/bmc-adapter-irmc.sh
	fi

	if ! bmc_session_login "$node"; then
		# bmc_session_login already printed the failure line.
		failed_list="$failed_list $node"
		continue
	fi

	if ! bmc_discover_system_id "$node"; then
		aba_warn "BMC: $node phase=discover (poweroff) adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		failed_list="$failed_list $node"
	elif ! bmc_power_off "$node" "$reset_type" && ! _bm_retry_after_401 "$node"; then
		aba_warn "BMC: $node phase=poweroff adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		failed_list="$failed_list $node"
	else
		ok_count=$(( ok_count + 1 ))
	fi

	bmc_session_logout "$node"
done

if [ "$ok_count" != "$total" ]; then
	if [ "$reset_type" = "GracefulShutdown" ]; then
		aba_warn "BMC: powered off $ok_count/$total nodes (failed:$failed_list)" "Run 'aba kill' to force the nodes off."
	else
		aba_warn "BMC: powered off $ok_count/$total nodes (failed:$failed_list)"
	fi
	exit 1
fi
aba_success "BMC: powered off $ok_count/$total nodes"
