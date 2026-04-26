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
		echo "$(vm_name "$CLUSTER_NAME" "$name")"
	done

	ask "Stop the above virtual machine(s)" || exit 1
fi

for name in $hosts; do
	exec_cmd="virsh -c $LIBVIRT_URI shutdown $(vm_name "$CLUSTER_NAME" "$name")"
	aba_debug "Running: $exec_cmd"
	$exec_cmd 2>/dev/null || true
done

# Return 0 when every VM is shut off (aligned with cluster-graceful-shutdown aba_wait_show).
_kvm_stop_all_shut_off() {
	local name state
	for name in $hosts; do
		aba_debug "Running: virsh -c $LIBVIRT_URI domstate $(vm_name "$CLUSTER_NAME" "$name")"
		state=$(virsh -c "$LIBVIRT_URI" domstate "$(vm_name "$CLUSTER_NAME" "$name")" 2>/dev/null)
		[ "$state" = "shut off" ] || return 1
	done
	return 0
}

if [ "$wait" ]; then
	_wait_mins=40
	_wait_timeout=$(( 60 * _wait_mins ))
	_wait_rc=0
	aba_wait_show "Waiting for VMs to shut off (Ctrl-C to abort)" 10 "$_wait_timeout" \
		_kvm_stop_all_shut_off || _wait_rc=$?
	if [ "$_wait_rc" -eq 130 ] || [ "$_wait_rc" -eq 143 ]; then
		aba_info "Aborted. VMs may still be shutting down in the background."
	elif [ "$_wait_rc" -ne 0 ]; then
		aba_abort "Timed out after ${_wait_timeout}s waiting for VMs to shut off"
	fi
fi

exit 0
