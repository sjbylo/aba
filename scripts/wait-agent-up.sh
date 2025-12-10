#!/bin/bash 
# This will wait for the Agent port to become alive on the rendezvous node0...

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

trap - ERR  # We don't want to catch on error. error handling added below. 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval $(scripts/cluster-config.sh $@ || exit 1)
fi

[ ! -f $ASSETS_DIR/rendezvousIP ] && aba_abort "Error: $ASSETS_DIR/rendezvousIP file missing.  Run 'aba iso' to create it."
cat $ASSETS_DIR/rendezvousIP | grep -E -q "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$" || exit 0 # Ignore if not an IP

echo
aba_info =================================================================================

# Wait for the Agent port to become alive on the rendezvous node0...
if [ ! -f .install-complete ]; then
	AGENT_IP=$(cat $ASSETS_DIR/rendezvousIP)
	AGENT_PORT=8090
	agent_url="http://$AGENT_IP:$AGENT_PORT/"
	max_retries=10
	delay=8

	aba_info "Waiting for Agent to come alive at $agent_url ..."
	for ((i=1; i<=max_retries; i++)); do

		[ "$no_proxy" ] && no_proxy="$AGENT_IP,$no_proxy"
		[ "$no_proxy" ] && aba_debug "Using: no_proxy=$no_proxy"

		code=$(curl --connect-timeout 10 -s -o /dev/null -w "%{http_code}" --max-time 3 "$agent_url")

		aba_debug return code=$code

		# If return code is 4xx, then stop
		if [[ $code =~ ^4..$ ]]; then
			aba_info_ok Agent detected
			sleep 8
			exit 0
		fi

		sleep "$delay"
		let delay=$delay+2
	done

	aba_red "[ABA] Agent not detected"
	sleep 8
fi


