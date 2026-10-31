#!/bin/bash 
# Wait for the Agent REST API (port 8090) on the rendezvous node.
# This short pause gives the agent time to come online and start producing
# log output so that monitor-install.sh (openshift-install wait-for) has
# something to show when it starts.
#
# Edge case (reviewed, intentionally not fixed):
# After 'aba refresh', if bootstrap succeeds and the node reboots before
# the user re-runs 'aba install', port 8090 is gone.  The .auto-agent-up
# marker was removed by refresh, so Make re-runs this script and it waits
# the full 5-min timeout before falling through to monitor-install.sh.
# This is harmless — monitor-install picks up the running install fine.
# Using 'aba mon' instead of 'aba install' skips this wait entirely.

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

trap - ERR  # We don't want to catch on error. error handling added below. 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh || exit 1
	eval "$(scripts/cluster-config.sh "$@")" || exit 1
fi

[ ! -f "$ASSETS_DIR/rendezvousIP" ] && aba_abort "$ASSETS_DIR/rendezvousIP file missing.  Run 'aba iso' to create it."
grep -E -q "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$" "$ASSETS_DIR/rendezvousIP" || exit 0 # Ignore if not an IP

aba_info =================================================================================

# Wait for the Agent port to become alive on the rendezvous node0...
if [ ! -f .install-complete ]; then
	AGENT_IP=$(cat "$ASSETS_DIR/rendezvousIP")
	AGENT_PORT=8090
	agent_url="http://$AGENT_IP:$AGENT_PORT/"

	if [ "$no_proxy" ]; then
		no_proxy="$AGENT_IP,$no_proxy"
	elif [ "${http_proxy:-}${https_proxy:-}" ]; then
		no_proxy="$AGENT_IP"
	fi
	[ "$no_proxy" ] && aba_debug "Using: no_proxy=$no_proxy"

	# Agent returns 4xx when alive (API endpoints return 404 at root)
	_agent_is_alive() {
		local code
		code=$(curl --connect-timeout 10 -s -o /dev/null -w "%{http_code}" --max-time 3 "$agent_url") || return 1
		[[ $code =~ ^4..$ ]]
	}

	if aba_wait_show "Waiting for Agent at $agent_url" 8 300 _agent_is_alive; then
		aba_success "Agent alive!"
		sleep 8
		exit 0
	fi

	echo_red "[ABA] Agent not detected"
	sleep 8
fi


