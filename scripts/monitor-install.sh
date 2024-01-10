#!/bin/bash 

. scripts/include_all.sh

[ "$1" ] && set -x 

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval $(scripts/cluster-config.sh $@ || exit 1)
fi

echo 
echo =================================================================================
echo Running wait-for command ...
echo "openshift-install agent wait-for bootstrap-complete --dir $MANEFEST_DIR"
openshift-install agent wait-for bootstrap-complete --dir $MANEFEST_DIR  # --log-level=debug

echo
echo =================================================================================
echo Running wait-for command ...
echo "openshift-install agent wait-for install-complete --dir $MANEFEST_DIR"
openshift-install agent wait-for install-complete --dir $MANEFEST_DIR    # --log-level=debug

