#!/bin/bash 
# Start the VMs

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

. <(process_args $*)
# eval all key value args
. <(echo $* | tr " " "\n")

if [ -s vmware.conf ]; then
	source <(normalize-vmware-conf)  # This is needed for $VC_FOLDER
else
	aba_info "vmware.conf file not defined. Run 'aba vmw' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval `scripts/cluster-config.sh || exit 1`
fi

source <(normalize-aba-conf)  # Fetch the 'ask' param

verify-aba-conf || exit 1

cluster_folder=$VC_FOLDER/$CLUSTER_NAME

hosts="$WORKER_NAMES $CP_NAMES"
[ "$workers" ] && hosts="$WORKER_NAMES"
[ "$masters" ] && hosts="$CP_NAMES"
[ ! "$hosts" ] && hosts="$CP_NAMES"

# If at least one VM exists, then show vms.
if scripts/vmw-exists.sh; then
	for name in $hosts; do
		[ "$VC" ] && echo $cluster_folder/${CLUSTER_NAME}-$name || echo ${CLUSTER_NAME}-$name
	done

	ask "Start the above virtual machine(s)" || exit 1
else
	exit 1
fi

for name in $hosts ; do
	govc vm.power -on ${CLUSTER_NAME}-$name || true
done

exit 0 

