#!/bin/bash
# Power every bare-metal node in bmc.conf on or off through its BMC (Redfish).
# Called by 'aba stop' (GracefulShutdown), 'aba kill' / 'aba poweroff' (ForceOff)
# and 'aba startup' (On) on platform=bm. Returns after each node reports the wanted
# PowerState, so after Off the node IPs and VIPs are free for the next install.
# Does not eject media or change the boot override.

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

reset_type="${1:-}"
case "$reset_type" in
	On) want=On; phase=poweron ;;
	GracefulShutdown|ForceOff) want=Off; phase=poweroff ;;
	*) aba_abort "Usage: $0 On|GracefulShutdown|ForceOff" ;;
esac

bmc_has_hosts || aba_abort "No BMC hosts in bmc.conf: aba cannot power the bare-metal nodes on or off." \
	"Power the servers on or off in the BMC UI."

source <(normalize-aba-conf)  # Fetch the 'ask' param
normalize-bmc-conf >/dev/null
source scripts/bmc-redfish.sh
source scripts/bmc-adapter-generic.sh

node_list=$(bmc_host_list)

# 'aba startup' asks before it calls this script for On.
if [ "$want" = "Off" ] && [ "${ask:-}" ]; then
	# A no leaves the nodes on and their IPs in use: exit non-zero so the caller
	# does not report success.
	if ! ask "Power off ($reset_type) bare-metal node(s): ${node_list//$'\n'/ }"; then
		aba_info "Nodes not powered off."
		exit 1
	fi
fi

_bm_power_node() {
	if [ "$want" = "On" ]; then
		bmc_power_on "$1"
	else
		bmc_power_off "$1" "$reset_type"
	fi
}

# Some BMCs (iRMC S4, some iLO) drop the session on a power change, so a request
# gets 401. Log in once more. If the Reset already went out, only wait for the
# wanted state: a second Reset while the node changes power state can fail with 409.
_bm_retry_after_401() {
	[ "$_REDFISH_LAST_CODE" = "401" ] || return 1
	aba_debug "BMC: $1 401 during $phase, re-authenticating once"
	_bm_delete_session "$1" || true
	bmc_session_login "$1" || return 1
	if [ "$_BM_RESET_SENT" ]; then
		_bm_wait_power_state "$1" "$want"
	else
		_bm_power_node "$1"
	fi
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
		aba_warn "BMC: $node phase=discover ($phase) adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		failed_list="$failed_list $node"
	elif ! _bm_power_node "$node" && ! _bm_retry_after_401 "$node"; then
		aba_warn "BMC: $node phase=$phase adapter=$adapter http=$_REDFISH_LAST_CODE reason=\"$_REDFISH_LAST_REASON\""
		failed_list="$failed_list $node"
	else
		ok_count=$(( ok_count + 1 ))
	fi

	bmc_session_logout "$node"
done

summary="BMC: powered ${want,,} $ok_count/$total nodes"
if [ "$ok_count" != "$total" ]; then
	if [ "$reset_type" = "GracefulShutdown" ]; then
		aba_warn "$summary (failed:$failed_list)" "Run 'aba kill' to force the nodes off."
	else
		aba_warn "$summary (failed:$failed_list)"
	fi
	exit 1
fi
aba_success "$summary"
