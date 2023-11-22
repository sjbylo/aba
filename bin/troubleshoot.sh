#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x



if [ ! "$CLUSTER_NAME" ]; then
	eval `common/scripts/cluster-config.sh $@ || exit 1`
fi

bin/init.sh $@

. ~/.vmware.conf || exit 1


ip=$(cat $1/rendezvousIP)

echo Checking ssh access to rendezvous host::
ssh core@$ip whoami 

echo Checking is infrs env is non-empty:
ssh core@$ip curl -s 127.0.0.1:8090/api/assisted-install/v2/infra-envs| jq .


