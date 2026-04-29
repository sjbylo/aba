#!/bin/bash
# Delete all VMs in the cluster on the KVM host

source scripts/include_all.sh

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

if scripts/kvm-exists.sh; then
	if [ "$ask" ]; then
		for name in $CP_NAMES $WORKER_NAMES; do
			echo "$(vm_name "$CLUSTER_NAME" "$name")"
		done
	fi
else
	aba_info "No VMs found -- nothing to delete"
	exit 0
fi

ask "Delete the above virtual machine(s)" || exit 1

for name in $CP_NAMES $WORKER_NAMES; do
	vm=$(vm_name "$CLUSTER_NAME" "$name")
	aba_debug "Running: virsh -c $LIBVIRT_URI dominfo $vm"
	if ! virsh -c "$LIBVIRT_URI" dominfo "$vm" >/dev/null 2>&1; then
		aba_info "VM $vm does not exist (skipping)"
		continue
	fi
	aba_info "Removing VM $vm"
	# Power off first -- ignore error if already off
	exec_cmd="virsh -c $LIBVIRT_URI destroy $vm"
	aba_debug "Running: $exec_cmd"
	$exec_cmd || true
	# Remove only disk volumes, NOT cdrom (ISO). --remove-all-storage deletes
	# the cdrom ISO too, which breaks refresh: upload ISO -> delete VM (ISO
	# removed) -> create VM (ISO missing).
	disk_vols=$(virsh -c "$LIBVIRT_URI" domblklist "$vm" --details | awk '$2 == "disk" {print $4}' | paste -sd,)
	storage_flag=
	if [ -n "$disk_vols" ]; then
		storage_flag="--storage $disk_vols"
	fi
	exec_cmd="virsh -c $LIBVIRT_URI undefine $vm $storage_flag --nvram"
	aba_debug "Running: $exec_cmd"
	$exec_cmd
	aba_debug "Running: virsh -c $LIBVIRT_URI dominfo $vm (verify)"
	if virsh -c "$LIBVIRT_URI" dominfo "$vm" >/dev/null 2>&1; then
		aba_abort "VM $vm still exists after undefine"
	fi
done

exit 0
