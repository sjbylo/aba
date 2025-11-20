#!/bin/bash 
# This will wait for the Agent port to become alive on the rendezvous node0...

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

trap - ERR  # We don't want to catch on error. error handling added below. 

 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval $(scripts/cluster-config.sh $@ || exit 1)
fi

[ -s iso-agent-based/rendezvousIP ] && cat iso-agent-based/rendezvousIP | grep -E -q "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$" || exit 0

echo
echo =================================================================================

# Wait for the Agent port to become alive on the rendezvous node0...
if [ ! -f .install-complete ]; then
	AGENT_HOST=$(cat iso-agent-based/rendezvousIP)
	AGENT_PORT=8090
	agent_url="http://$AGENT_HOST:$AGENT_PORT/"
	max_retries=10
	delay=8

	echo "Waiting for Agent to come alive at $agent_url ..."
	for ((i=1; i<=max_retries; i++)); do
		code=$(curl --connect-timeout 10 -s -o /dev/null -w "%{http_code}" --max-time 3 "$agent_url")
		[ "$ABA_DEBUG" ] && echo return code=$code
		if [[ $code =~ ^4..$ ]]; then
			break
		fi

		sleep "$delay"
		let delay=$delay+2
	done

	sleep 8
fi

