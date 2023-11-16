#!/bin/bash -e

common/scripts/validate.sh $@

if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

echo Viewing events on the rendezvous server at $RENDEZVOUSIP ...
sleep 1
lines=`tput lines`
let lines=$lines-4

watch "ssh -o StrictHostKeyChecking=false -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 core@$RENDEZVOUSIP curl -s 127.0.0.1:8090/api/assisted-install/v2/events | jq .[] | jq -r '\"\(.event_time) | \(.message)\"' | tail -$lines"

