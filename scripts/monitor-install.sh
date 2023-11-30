#!/bin/bash -e

. scripts/include_all.sh

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$1" ] && set -x 

if [ ! "$CLUSTER_NAME" ]; then
	eval $(scripts/cluster-config.sh $@ || exit 1)
fi

#bin/init.sh $@

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
END

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

