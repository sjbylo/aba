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
[ ! -s $ICONF -o ! -s $ACONF ] && echo "One of the files $ICONF and/or $ACONF does not exist.  Cannot parse cluster configuration. Are you running this in the 'cluster' directory?" && exit 1

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

### # FIXME: does $FOLDER really need to be created here? How about in normalize-vmware-conf()?
### # Check if using ESXi or vCenter 
### if [ "$VMW_FOLDER" ]; then
	### if [ "$VMW_FOLDER" == "/ha-datacenter/vm" ]; then
		### # For ESXi
		### export FOLDER=$VMW_FOLDER
	### else
		### # For vCenter 
		### export FOLDER=$VMW_FOLDER/$CLUSTER_NAME
		### export VC=1
		### echo export VC=1
	### fi
### fi

### echo export FOLDER=$FOLDER
### echo export VMW_FOLDER=$VMW_FOLDER

RENDEZVOUSIP=`cat $ACONF_TMP | jq -r '.rendezvousIP'`
echo export RENDEZVOUSIP=$RENDEZVOUSIP 

err=

### [ $WORKER_REPLICAS -eq 0 ] && rm -f $ICONF_TMP $ACONF_TMP && exit 0
if [ $WORKER_REPLICAS -ne 0 ]; then
	WORKER_NAMES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" )| .hostname'`
	echo export WORKER_NAMES=\"$WORKER_NAMES\"

	WORKER_MAC_ADDRESSES=`cat $ACONF_TMP | jq -r '.hosts[] | select( .role == "worker" )| .interfaces[0].macAddress'`
	echo export WORKER_MAC_ADDRESSES=\"$WORKER_MAC_ADDRESSES\"

	# basic checks
	[ ! "$WORKER_NAMES" ] && echo ".hosts[].role.worker.hostname missing in $ACONF" >&2 && err=1
	[ ! "$WORKER_MAC_ADDRESSES" ] && echo ".hosts[].role.worker.interfaces[0].macAddress missing in $ACONF" >&2 && err=1
fi

rm -f $ICONF_TMP $ACONF_TMP

# basic checks
[ ! "$CLUSTER_NAME" ] && echo "Cluster name .metadata.name missing in $ICONF" >&2 && err=1
[ ! "$BASE_DOMAIN" ] && echo "Base domain .baseDomain missing in $ICONF" >&2 && err=1
[ ! "$RENDEZVOUSIP" ] && echo "Rendezvous ip .rendezvousIP missing in $ACONF" >&2  && err=1
[ ! "$CP_REPLICAS" ] && echo "Control Plane replica count .controlPlane.replicas missing in $ICONF" >&2  && err=1
[ ! "$CP_NAMES" ] && echo "Control Plane names .hosts[].role.master.hostname missing in $ACONF" >&2  && err=1
[ ! "$CP_MAC_ADDRESSES" ] && echo "Control Plane mac addresses .hosts[].role.master.interfaces[0].macAddress missing in $ACONF" >&2  && err=1
[ ! "$WORKER_REPLICAS" ] && echo "Worker replica count .compute[0].replicas missing in $ICONF" >&2  && err=1
### [ ! "$FOLDER" ]  && echo "xxxx" >&2 

if [ "$err" ]; then
	echo
	[ "$TERM" ] && tput setaf 1
	echo "WARNING: The files 'install-config.yaml' and/or 'agent-config.yaml' chould not be parsed properly." 
	echo
	[ "$TERM" ] && tput sgr0
fi

