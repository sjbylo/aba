#!/bin/bash 
# This script extracts the needed values from the agent-config.yaml and the install-config.yaml files.

source scripts/include_all.sh

unset CLUSTER_NAME
unset BASE_DOMAIN
unset RENDEZVOUSIP
unset CP_REPLICAS
unset CP_NAMES
unset CP_MAC_ADDRESSES
unset CP_IP_ADDRESSES
unset WORKER_REPLICAS

unset WORKER_NAMES
unset WKR_MAC_ADDRESSES
unset WKR_IP_ADDRESSES

yaml2json()
{
	python3 -c 'import yaml; import json; import sys; print(json.dumps(yaml.safe_load(sys.stdin)));'
}

export MANEFEST_SRC_DIR=.
export MANEFEST_DIR=iso-agent-based

echo export MANEFEST_DIR=$MANEFEST_DIR
echo export MANEFEST_SRC_DIR=$MANEFEST_SRC_DIR

### # This is only needed to know if the install is via vCenter or not (See VC_FOLDER below)
### [ -s vmware.conf ] && source <(normalize-vmware-conf)          

ICONF=$MANEFEST_SRC_DIR/install-config.yaml  
ICONF_TMP=/tmp/.install-config.yaml  

ACONF=$MANEFEST_SRC_DIR/agent-config.yaml  
ACONF_TMP=/tmp/.agent-config.yaml  

# If the files don't exist, nothing to do!
[ ! -s $ICONF -o ! -s $ACONF ] && echo "One of the files $ICONF and/or $ACONF does not exist.  Cannot parse cluster configuration. Are you running this in the 'cluster' directory?" && exit 1

cat $ICONF | yaml2json > $ICONF_TMP
cat $ACONF | yaml2json > $ACONF_TMP

CLUSTER_NAME=`cat $ICONF_TMP | jq -r .metadata.name`
echo "$CLUSTER_NAME" | grep -q "null" && CLUSTER_NAME=
echo export CLUSTER_NAME=$CLUSTER_NAME

BASE_DOMAIN=`cat $ICONF_TMP | jq -r .baseDomain`
echo "$BASE_DOMAIN" | grep -q "null" && BASE_DOMAIN=
echo export BASE_DOMAIN=$BASE_DOMAIN

CP_REPLICAS=`cat $ICONF_TMP | jq -r .controlPlane.replicas`
echo "$CP_REPLICAS" | grep -q "null" && CP_REPLICAS=
echo export CP_REPLICAS=$CP_REPLICAS

CP_NAMES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "master" )| .hostname'`
echo "$CP_NAMES" | grep -q "null" && CP_NAMES=
echo export CP_NAMES=\"$CP_NAMES\"

CP_MAC_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "master" ) | .interfaces[0].macAddress'`
echo "$CP_MAC_ADDRESSES" | grep -q "null" && CP_MAC_ADDRESSES=
echo export CP_MAC_ADDRESSES=\"$CP_MAC_ADDRESSES\"

CP_IP_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "master" ) | .networkConfig.interfaces[0].ipv4.address[0].ip'`
echo "$CP_IP_ADDRESSES" | grep -q "null" && CP_IP_ADDRESSES=
echo export CP_IP_ADDRESSES=\"$CP_IP_ADDRESSES\"

WORKER_REPLICAS=`cat $ICONF_TMP | jq -r .compute[0].replicas`
echo "$WORKER_REPLICAS" | grep -q "null" && WORKER_REPLICAS=
echo export WORKER_REPLICAS=$WORKER_REPLICAS

RENDEZVOUSIP=`cat $ACONF_TMP | jq -r '.rendezvousIP'`
echo "$RENDEZVOUSIP" | grep -q "null" && RENDEZVOUSIP=
echo export RENDEZVOUSIP=$RENDEZVOUSIP 

err=

if [ $WORKER_REPLICAS -ne 0 ]; then
	WORKER_NAMES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" )| .hostname'`
	echo "$WORKER_NAMES" | grep -q "null" && WORKER_NAMES=
	echo export WORKER_NAMES=\"$WORKER_NAMES\"

	WKR_MAC_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" )| .interfaces[0].macAddress'`
	echo "$WKR_MAC_ADDRESSES" | grep -q "null" && WKR_MAC_ADDRESSES=
	echo export WKR_MAC_ADDRESSES=\"$WKR_MAC_ADDRESSES\"

	WKR_IP_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" ) | .networkConfig.interfaces[0].ipv4.address[0].ip'`
	echo "$WKR_IP_ADDRESSES" | grep -q "null" && WKR_IP_ADDRESSES=
	echo export WKR_IP_ADDRESSES=\"$WKR_IP_ADDRESSES\"

	# basic checks
	[ ! "$WORKER_NAMES" ] && echo ".hosts[].role.worker.hostname missing in $ACONF" >&2 && err=1
	[ ! "$WKR_MAC_ADDRESSES" ] && echo ".hosts[].role.worker.interfaces[0].macAddress missing in $ACONF" >&2 && err=1
	[ ! "$WKR_IP_ADDRESSES" ] && echo ".hosts[].role.worker.networkConfig.interfaces[0].ipv4.address[0].ip missing in $ACONF" >&2 && err=1
fi

rm -f $ICONF_TMP $ACONF_TMP

# basic checks
[ ! "$CLUSTER_NAME" ] && echo "Cluster name .metadata.name missing in $ICONF" >&2 && err=1
[ ! "$BASE_DOMAIN" ] && echo "Base domain .baseDomain missing in $ICONF" >&2 && err=1
[ ! "$RENDEZVOUSIP" ] && echo "Rendezvous ip .rendezvousIP missing in $ACONF" >&2  && err=1
[ ! "$CP_REPLICAS" ] && echo "Control Plane replica count .controlPlane.replicas missing in $ICONF" >&2  && err=1
[ ! "$CP_NAMES" ] && echo "Control Plane names .hosts[].role.master.hostname missing in $ACONF" >&2  && err=1
[ ! "$CP_MAC_ADDRESSES" ] && echo "Control Plane mac addresses .hosts[].role.master.interfaces[0].macAddress missing in $ACONF" >&2  && err=1
[ ! "$CP_IP_ADDRESSES" ] && echo "Control Plane ip addresses .hosts[].role.master.networkConfig.interfaces[0].ipv4.address[0].ip missing in $ACONF" >&2  && err=1
[ ! "$WORKER_REPLICAS" ] && echo "Worker replica count .compute[0].replicas missing in $ICONF" >&2  && err=1

if [ "$err" ]; then
	echo
	[ "$TERM" ] && tput setaf 1
	echo "WARNING: The files 'install-config.yaml' and/or 'agent-config.yaml' chould not be parsed properly." 
	echo
	[ "$TERM" ] && tput sgr0

	exit 1
fi

exit 0
