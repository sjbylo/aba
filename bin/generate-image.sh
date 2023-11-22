#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x

eval `common/scripts/cluster-config.sh $@ || exit 1`

bin/init.sh $@

if [ $MANEFEST_DIR/agent.x86_64.iso -nt $MANEFEST_SRC_DIR/install-config.yaml -a $MANEFEST_DIR/agent.x86_64.iso -nt $MANEFEST_SRC_DIR/agent-install.yaml ]; then
	echo "Not re-generating ISO file since the agent-based configuration files have not been updated"
else
	echo Generating the ISO image for $CLUSTER_NAME.$BASE_DOMAIN ...
	echo "openshift-install agent create image --dir $MANEFEST_DIR "

	rm -rf $MANEFEST_DIR && cp -rp $MANEFEST_SRC_DIR $MANEFEST_DIR && openshift-install agent create image --dir $MANEFEST_DIR 
fi

#rm -rf $MANEFEST_DIR && cp -rp $MANEFEST_SRC_DIR $MANEFEST_DIR && \
#openshift-install agent create image --log-level debug --dir $MANEFEST_DIR 

