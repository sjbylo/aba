#!/bin/bash -e
# This script extracts the required values from the agent-config.yaml and the install-config.yaml files.

source scripts/include_all.sh

unset CLUSTER_NAME
unset BASE_DOMAIN
unset RENDEZVOUSIP
unset CP_REPLICAS
unset CP_NAMES
unset CP_MAC_ADDRS
unset CP_IP_ADDRESSES
unset WORKER_REPLICAS
unset PORTS_PER_NODE

unset WORKER_NAMES
unset WKR_MAC_ADDRS
unset WKR_IP_ADDR

yaml2json()
{
	python3 -c 'import yaml; import json; import sys; print(json.dumps(yaml.safe_load(sys.stdin)));'
}

export MANIFEST_SRC_DIR=.

ICONF=$MANIFEST_SRC_DIR/install-config.yaml  
ACONF=$MANIFEST_SRC_DIR/agent-config.yaml  

# If the files don't exist, nothing to do but exit!
if [ ! -s $ICONF -o ! -s $ACONF ]; then
	echo "One of the files $ICONF and/or $ACONF does not exist."
	echo "Cannot parse cluster configuration. Are you running this in your 'cluster' directory?" 
	exit 1
fi

ICONF_TMP=$(cat $ICONF | yaml2json)
ACONF_TMP=$(cat $ACONF | yaml2json)

CLUSTER_NAME=`echo "$ICONF_TMP" | jq -r .metadata.name`
echo "$CLUSTER_NAME" | grep -q "null" && CLUSTER_NAME=
echo export CLUSTER_NAME=$CLUSTER_NAME

BASE_DOMAIN=`echo "$ICONF_TMP" | jq -r .baseDomain`
echo "$BASE_DOMAIN" | grep -q "null" && BASE_DOMAIN=
echo export BASE_DOMAIN=$BASE_DOMAIN

RENDEZVOUSIP=`echo "$ACONF_TMP" | jq -r '.rendezvousIP'`
echo "$RENDEZVOUSIP" | grep -q "null" && RENDEZVOUSIP=
echo export RENDEZVOUSIP=$RENDEZVOUSIP 

CP_REPLICAS=`echo "$ICONF_TMP" | jq -r .controlPlane.replicas`
echo "$CP_REPLICAS" | grep -q "null" && CP_REPLICAS=
echo export CP_REPLICAS=$CP_REPLICAS

CP_NAMES=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "master" )| .hostname'`
echo "$CP_NAMES" | grep -q "null" && CP_NAMES=
echo export CP_NAMES=\"$CP_NAMES\"

CP_MAC_ADDRS=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "master" ) | .interfaces[].macAddress'`
echo "$CP_MAC_ADDRS" | grep -q "null" && CP_MAC_ADDRS=
echo export CP_MAC_ADDRS=\"$CP_MAC_ADDRS\"

CP_MAC_ADDRS_ARRAY=($CP_MAC_ADDRS)
PORTS_PER_NODE=$(expr ${#CP_MAC_ADDRS_ARRAY[@]} / $CP_REPLICAS)
echo export PORTS_PER_NODE=\"$PORTS_PER_NODE\"

### CP_MAC_ADDR=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "master" ) | .interfaces[].macAddress'`
### echo "$CP_MAC_ADDR" | grep -q "null" && CP_MAC_ADDR=
### echo export CP_MAC_ADDR=\"$CP_MAC_ADDR\"

### # If bonding is NOT used, then ignore eny errors here:
### CP_MAC_ADDR_2ND=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "master" ) | .interfaces[1].macAddress'`
### echo "$CP_MAC_ADDR_2ND" | grep -q "null" && CP_MAC_ADDR_2ND=
### [ "$CP_MAC_ADDR_2ND" ] && echo export CP_MAC_ADDR_2ND=\"$CP_MAC_ADDR_2ND\"

CP_IP_ADDRESSES=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "master" ) | .networkConfig.interfaces[0].ipv4.address[0].ip'`
echo "$CP_IP_ADDRESSES" | grep -q "null" && CP_IP_ADDRESSES=
echo export CP_IP_ADDRESSES=\"$CP_IP_ADDRESSES\"

WORKER_REPLICAS=`echo "$ICONF_TMP" | jq -r .compute[0].replicas`
echo "$WORKER_REPLICAS" | grep -q "null" && WORKER_REPLICAS=
echo export WORKER_REPLICAS=$WORKER_REPLICAS

err=

if [ $WORKER_REPLICAS -ne 0 ]; then
	WORKER_NAMES=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "worker" )| .hostname'`
	echo "$WORKER_NAMES" | grep -q "null" && WORKER_NAMES=
	echo export WORKER_NAMES=\"$WORKER_NAMES\"

	WKR_MAC_ADDRS=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "worker" )| .interfaces[].macAddress'`
	echo "$WKR_MAC_ADDRS" | grep -q "null" && WKR_MAC_ADDRS=
	echo export WKR_MAC_ADDRS=\"$WKR_MAC_ADDRS\"

	#WKR_MAC_ADDR_2ND=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "worker" )| .interfaces[1].macAddress'`
	#echo "$WKR_MAC_ADDR_2ND" | grep -q "null" && WKR_MAC_ADDR_2ND=
	#[ "$WKR_MAC_ADDR_2ND" ] && echo export WKR_MAC_ADDR_2ND=\"$WKR_MAC_ADDR_2ND\"

	WKR_IP_ADDR=`echo "$ACONF_TMP" | jq -r '.hosts[] | select( .role == "worker" ) | .networkConfig.interfaces[0].ipv4.address[0].ip'`
	echo "$WKR_IP_ADDR" | grep -q "null" && WKR_IP_ADDR=
	echo export WKR_IP_ADDR=\"$WKR_IP_ADDR\"

fi

export ASSETS_DIR=iso-agent-based
echo export ASSETS_DIR=$ASSETS_DIR

# basic checks
[ ! "$CLUSTER_NAME" ] && echo "Cluster name .metadata.name missing in $ICONF" >&2 && err=1
[ ! "$BASE_DOMAIN" ] && echo "Base domain .baseDomain missing in $ICONF" >&2 && err=1
[ ! "$RENDEZVOUSIP" ] && echo "Rendezvous ip .rendezvousIP missing in $ACONF" >&2  && err=1
[ ! "$CP_REPLICAS" ] && echo "Control Plane replica count .controlPlane.replicas missing in $ICONF" >&2  && err=1
[ ! "$CP_NAMES" ] && echo "Control Plane names .hosts[].role.master.hostname missing in $ACONF" >&2  && err=1
[ ! "$CP_MAC_ADDRS" ] && echo "Control Plane mac addresses .hosts[].role.master.interfaces[0].macAddress missing in $ACONF" >&2  && err=1
[ ! "$CP_IP_ADDRESSES" ] && echo "Control Plane ip addresses .hosts[].role.master.networkConfig.interfaces[0].ipv4.address[0].ip missing in $ACONF" >&2  && err=1
[ ! "$WORKER_REPLICAS" ] && echo "Worker replica count .compute[0].replicas missing in $ICONF" >&2  && err=1

if [ $WORKER_REPLICAS -ne 0 ]; then
	# basic checks
	[ ! "$WORKER_NAMES" ] && echo ".hosts[].role.worker.hostname missing in $ACONF" >&2 && err=1
	[ ! "$WKR_MAC_ADDRS" ] && echo ".hosts[].role.worker.interfaces[].macAddress missing in $ACONF" >&2 && err=1
	[ ! "$WKR_IP_ADDR" ] && echo ".hosts[].role.worker.networkConfig.interfaces[0].ipv4.address[0].ip missing in $ACONF" >&2 && err=1
fi

if [ "$err" ]; then
	echo
	echo_red "Error: Validation of values in files 'install-config.yaml' and/or 'agent-config.yaml' failed." >&2 
	echo

	exit 1
fi

exit 0
