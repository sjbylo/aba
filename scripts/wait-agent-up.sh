#!/bin/bash
# Wait for the Agent REST API (port 8090) on the rendezvous node.
# Timing cushion so openshift-install wait-for does not start before the
# agent is up (avoids noisy early errors after same-session VM/BMC power-on).
#
# Called only from the install Make chain (.install-complete), not from
# 'aba mon' / monitor-install.sh — once install is underway the agent API
# (8090) is often already gone after bootstrap.
#
# Skip: platform=bm with no BMC nodes (manual boot). Operators often return
# to the TUI/CLI long after 8090 is gone; waiting up to 5m is useless then.
# Keep the wait for vmw/kvm and for BM after BMC auto-boot (bmc.conf).
#
# Edge case (vmw/kvm / BM+BMC): if the node is already past agent when this
# runs, we wait the full timeout then fall through to monitor-install.sh.
# Harmless — monitor picks up the running install. Use 'aba mon' to skip.

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

trap - ERR  # We don't want to catch on error. error handling added below.

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh || exit 1
	eval "$(scripts/cluster-config.sh "$@")" || exit 1
fi

source <(normalize-aba-conf)
platform=${platform:-bm}

# Manual BM: no same-session power-on race — skip straight to monitor.
if [ "$platform" = "bm" ] && ! bmc_has_hosts; then
	aba_debug "wait-agent-up: skip (platform=bm, no BMC auto-boot)"
	exit 0
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


