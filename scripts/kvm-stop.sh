#!/bin/bash
# Stop the VMs gracefully on the KVM host

source scripts/include_all.sh

aba_debug "Running: $0 $*" >&2

. <(process_args $*)
. <(echo $* | tr " " "\n")

if [ -s kvm.conf ]; then
	ensure_virsh
	source <(normalize-kvm-conf)
else
	aba_info "kvm.conf file not defined. Run 'aba kvm' to create it if needed"
	exit 0
fi

if [ ! "$CLUSTER_NAME" ]; then
	scripts/cluster-config-check.sh
	eval "$(scripts/cluster-config.sh)" || exit 1
fi

source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

hosts="$WORKER_NAMES $CP_NAMES"
[ "$workers" ] && hosts="$WORKER_NAMES"
[ "$masters" ] && hosts="$CP_NAMES"
[ ! "$hosts" ] && hosts="$CP_NAMES"

if [ "$ask" ]; then
	echo
	for name in $hosts; do
		echo "${CLUSTER_NAME}-${name}"
	done

	ask "Stop the above virtual machine(s)" || exit 1
fi

for name in $hosts; do
	virsh -c "$LIBVIRT_URI" shutdown "${CLUSTER_NAME}-${name}" 2>/dev/null || true
done

if [ "$wait" ]; then
	aba_info "Waiting for nodes to power down ..."

	hosts_off=
	while [ ! "$hosts_off" ]; do
		for name in $hosts; do
			state=$(virsh -c "$LIBVIRT_URI" domstate "${CLUSTER_NAME}-${name}" 2>/dev/null)
			[ "$state" = "running" ] && hosts_off= && break
			[ "$state" = "shut off" ] && hosts_off=1
		done

		[ "$hosts_off" ] && exit 0

		sleep 10
	done
fi

exit 0
