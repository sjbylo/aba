#!/bin/bash 
# This script extracts the needed values from the agent-config.yaml and the install-config.yaml files.

source scripts/include_all.sh

#[ ! "$1" ] && echo "Usage: `basename $0` <directory>" && exit 1

yaml2json()
{
	python3 -c 'import yaml; import json; import sys; print(json.dumps(yaml.safe_load(sys.stdin)));'
}

export MANEFEST_SRC_DIR=.
export MANEFEST_DIR=iso-agent-based

echo export MANEFEST_DIR=$MANEFEST_DIR
echo export MANEFEST_SRC_DIR=$MANEFEST_SRC_DIR

# This is only needed to know if the install is via vCenter or not (See VMW_FOLDER below)
[ -s vmware.conf ] && source <(normalize-vmware-conf)            # This is needed for $VMW_FOLDER

ICONF=$MANEFEST_SRC_DIR/install-config.yaml  
ICONF_TMP=/tmp/.install-config.yaml  

ACONF=$MANEFEST_SRC_DIR/agent-config.yaml  
ACONF_TMP=/tmp/.agent-config.yaml  

# If the files don't exist, nothing to do!
[ ! -s $ICONF -o ! -s $ACONF ] && echo "One of the files $ICONF and/or $ACONF does not exist.  Cannot parse cluster configuration. Are you running this in the 'cluster' directory?" && exit 0

cat $ICONF | yaml2json > $ICONF_TMP
cat $ACONF | yaml2json > $ACONF_TMP

CLUSTER_NAME=`cat $ICONF_TMP | jq -r .metadata.name`
echo export CLUSTER_NAME=$CLUSTER_NAME
BASE_DOMAIN=`cat $ICONF_TMP | jq -r .baseDomain`
echo export BASE_DOMAIN=$BASE_DOMAIN

CP_REPLICAS=`cat $ICONF_TMP | jq -r .controlPlane.replicas`
echo export CP_REPLICAS=$CP_REPLICAS

CP_NAMES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "master" )| .hostname'`
echo export CP_NAMES=\"$CP_NAMES\"

CP_MAC_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "master" ) | .interfaces[0].macAddress'`
echo export CP_MAC_ADDRESSES=\"$CP_MAC_ADDRESSES\"

WORKER_REPLICAS=`cat $ICONF_TMP | jq -r .compute[0].replicas`
echo export WORKER_REPLICAS=$WORKER_REPLICAS

# FIXME: does $FOLDER really need to be created here? How about in normalize-vmware-conf()?
# Check if using ESXi or vCenter 
if [ "$VMW_FOLDER" ]; then
	if [ "$VMW_FOLDER" == "/ha-datacenter/vm" ]; then
		# For ESXi
		export FOLDER=$VMW_FOLDER
	else
		# For vCenter 
		export FOLDER=$VMW_FOLDER/$CLUSTER_NAME
		export VC=1
		echo export VC=1
	fi
fi

echo export FOLDER=$FOLDER
echo export VMW_FOLDER=$VMW_FOLDER

RENDEZVOUSIP=`cat $ACONF_TMP | jq -r '.rendezvousIP'`
echo export RENDEZVOUSIP=$RENDEZVOUSIP 

[ $WORKER_REPLICAS -eq 0 ] && rm -f $ICONF_TMP $ACONF_TMP && exit 0

WORKER_NAMES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" )| .hostname'`
echo export WORKER_NAMES=\"$WORKER_NAMES\"

WORKER_MAC_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" )| .interfaces[0].macAddress'`
echo export WORKER_MAC_ADDRESSES=\"$WORKER_MAC_ADDRESSES\"

rm -f $ICONF_TMP $ACONF_TMP

# basic check
if [ ! "$CLUSTER_NAME" -o ! "$BASE_DOMAIN" -o ! "$RENDEZVOUSIP" -o ! "$CP_REPLICAS" -o ! "$CP_NAMES" -o ! "$CP_MAC_ADDRESSES" -o ! "$WORKER_REPLICAS" -o ! "$WORKER_NAMES" -o ! "$WORKER_MAC_ADDRESSES" -o ! "$VMW_FOLDER" ]; then
	echo
	[ "$TERM" ] && tput setaf 1
	echo "WARNING: The files 'install-config.yaml' and/or 'agent-config.yaml' chould not be parsed properly." 
	echo
	[ "$TERM" ] && tput sgr0
fi


