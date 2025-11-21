#!/bin/bash 
# Install and edit the vmware (govc) conf file
# This script should really only be run on the internal bastion (with access to vCenter) 

source scripts/include_all.sh

[ "$1" ] && export DEBUG_ABA=1

aba_debug "Starting: $0 $*"

# Needed for $editor and $ask
source <(normalize-aba-conf)

verify-aba-conf || exit 1

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

	aba_info Checking govc config file: $PWD/vmware.conf

	if ! govc about >/dev/null 2>&1; then
		aba_abort "Cannot access vSphere or ESXi at $GOVC_URL.  Please edit $PWD/vmware.conf and try again!" 
	fi

	aba_info Govc config file $PWD/vmware.conf ok

	exit 0
else
	aba_debug vmware.conf exists but is empty ...

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
	# Check access
	if ! govc about; then
		aba_abort "Cannot access vSphere or ESXi at $GOVC_URL.  Please edit $PWD/vmware.conf and try again!" 
	else
		aba_info "Saving working version of 'vmware.conf' to '~/.vmware.conf'."
		[ -s vmware.conf ] && cp vmware.conf ~/.vmware.conf
	fi
fi

exit 0

