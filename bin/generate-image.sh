#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

eval `common/scripts/cluster-config.sh $@ || exit 1`

###bin/init.sh $@

if [ $MANEFEST_SRC_DIR/install-config.yaml -nt $MANEFEST_DIR/agent.x86_64.iso -o $MANEFEST_SRC_DIR/agent-install.yaml -nt $MANEFEST_DIR/agent.x86_64.iso ]; then
	echo Generating the ISO image for $CLUSTER_NAME.$BASE_DOMAIN ...
	echo "openshift-install agent create image --dir $MANEFEST_DIR "

	# Refresh the ISO
	rm -rf $MANEFEST_DIR && cp -rp $MANEFEST_SRC_DIR $MANEFEST_DIR && openshift-install agent create image --dir $MANEFEST_DIR 
else
	echo "Not re-generating ISO file since the agent-based configuration files have not been updated"
	sleep 1
fi

