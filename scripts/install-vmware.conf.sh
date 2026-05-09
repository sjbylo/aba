#!/bin/bash 
# Install and edit the vmware (govc) conf file
# This script should really only be run on the internal bastion (with access to vCenter) 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Verify that vSphere objects referenced in vmware.conf actually exist.
# Called after govc about succeeds (login is valid).
_vmw_verify_objects() {
	local _err=""

	if [ "$GOVC_DATASTORE" ]; then
		if govc datastore.info "$GOVC_DATASTORE" >/dev/null 2>&1; then
			aba_info "Datastore '$GOVC_DATASTORE' ... OK"
		else
			aba_warning "Datastore '$GOVC_DATASTORE' not found!"
			_err=1
		fi
	fi

	if [ "${ISO_DATASTORE:-}" ]; then
		if govc datastore.info "$ISO_DATASTORE" >/dev/null 2>&1; then
			aba_info "ISO Datastore '$ISO_DATASTORE' ... OK"
		else
			aba_warning "ISO Datastore '$ISO_DATASTORE' not found!"
			_err=1
		fi
	fi

	if [ "$GOVC_NETWORK" ]; then
		if [ "$(govc find / -type Network -name "$GOVC_NETWORK")" ]; then
			aba_info "Network '$GOVC_NETWORK' ... OK"
		else
			aba_warning "Network (port group) '$GOVC_NETWORK' not found!"
			_err=1
		fi
	fi

	if [ "${GOVC_DATACENTER:-}" ]; then
		if govc datacenter.info "$GOVC_DATACENTER" >/dev/null 2>&1; then
			aba_info "Datacenter '$GOVC_DATACENTER' ... OK"
		else
			aba_warning "Datacenter '$GOVC_DATACENTER' not found!"
			_err=1
		fi
	fi

	# govc cluster.info doesn't exist; use find instead
	if [ "${GOVC_CLUSTER:-}" ]; then
		if [ "$(govc find / -type ClusterComputeResource -name "$GOVC_CLUSTER")" ]; then
			aba_info "Cluster '$GOVC_CLUSTER' ... OK"
		else
			aba_warning "Cluster '$GOVC_CLUSTER' not found!"
			_err=1
		fi
	fi

	if [ "${VC_FOLDER:-}" ]; then
		if govc folder.info "$VC_FOLDER" >/dev/null 2>&1; then
			aba_info "Folder '$VC_FOLDER' ... OK"
		else
			aba_info "Folder '$VC_FOLDER' does not exist yet (will be created at install time)"
		fi
	fi

	if [ "${GOVC_RESOURCE_POOL:-}" ]; then
		if govc pool.info "$GOVC_RESOURCE_POOL" >/dev/null 2>&1; then
			aba_info "Resource pool '$GOVC_RESOURCE_POOL' ... OK"
		else
			aba_warning "Resource pool '$GOVC_RESOURCE_POOL' not found!"
			_err=1
		fi
	fi

	[ "$_err" ] && aba_abort "One or more vSphere objects in vmware.conf do not exist. Fix vmware.conf and try again."

	return 0
}

# Needed for $editor and $ask
source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

[ "$platform" != "vmw" ] && \
	aba_info "To set the platform value in aba.conf run: 'aba -p vmw' and run: 'aba vmw'." && rm -f vmware.conf && exit 0

aba_debug Checking for $PWD/vmware.conf file ..

if [ -d ~/.govmomi/sessions ]; then
	aba_debug "Deleting existing govc sessions in ~/.govmomi/sessions"
	rm -rf ~/.govmomi/sessions/
else
	aba_debug "No existing govc sessions in ~/.govmomi/sessions"
fi

if [ -s vmware.conf ]; then
	aba_debug vmware.conf exists, test it...

	source <(normalize-vmware-conf)

	aba_debug Checking govc config file: $PWD/vmware.conf

	if ! govc about >/dev/null 2>&1; then
		aba_abort "Cannot access vSphere or ESXi at $GOVC_URL.  Please edit $PWD/vmware.conf and try again!" 
	fi

	_vmw_verify_objects

	aba_debug Govc config file $PWD/vmware.conf ok

	[ ! -s ~/.vmware.conf ] && cp vmware.conf ~/.vmware.conf && aba_debug "Saved vmware.conf to ~/.vmware.conf"

	exit 0
else
	aba_info vmware.conf exists but is empty ...

	if [ -s ~/.vmware.conf ]; then
		aba_info "Copying vmware.conf from '~/.vmware.conf' to $PWD/vmware.conf"
		cp ~/.vmware.conf vmware.conf   # The working user edited file, if it exists
	else
		aba_info "Copying 'vmware.conf' from 'templates/vmware.conf'"
		cp templates/vmware.conf .  # The default template 
	fi

	trap - ERR
	edit_file vmware.conf "To deploy to VMware or ESXi, edit the 'vmware.conf' file" || exit 0

	source <(normalize-vmware-conf)

	aba_info Checking govc config file: $PWD/vmware.conf
	aba_debug "Running: govc about"
	if ! govc about; then
		aba_abort "Cannot access vSphere or ESXi at $GOVC_URL.  Please edit $PWD/vmware.conf and try again!" 
	else
		_vmw_verify_objects

		aba_info "Saving working version of 'vmware.conf' to '~/.vmware.conf'."
		[ -s vmware.conf ] && cp vmware.conf ~/.vmware.conf
	fi
fi

exit 0

