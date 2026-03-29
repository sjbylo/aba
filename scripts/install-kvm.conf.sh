#!/bin/bash
# Install and edit the KVM/libvirt conf file
# This script should only be run on the internal bastion (with SSH access to the KVM host)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

[ "$platform" != "kvm" ] && \
	aba_info "To set the platform value in aba.conf run: 'aba -p kvm' and run: 'aba kvm'." && rm -f kvm.conf && exit 0

aba_debug Checking for $PWD/kvm.conf file ..

if [ -s kvm.conf ]; then
	aba_debug kvm.conf exists, test it...

	ensure_virsh
	source <(normalize-kvm-conf)

	aba_debug Checking kvm config file: $PWD/kvm.conf

	if ! virsh -c "$LIBVIRT_URI" version >/dev/null 2>&1; then
		aba_abort "Cannot connect to libvirt at $LIBVIRT_URI.  Please edit $PWD/kvm.conf and try again!"
	fi

	aba_debug KVM config file $PWD/kvm.conf ok

	[ ! -s ~/.kvm.conf ] && cp kvm.conf ~/.kvm.conf && aba_debug "Saved kvm.conf to ~/.kvm.conf"

	exit 0
else
	aba_info kvm.conf exists but is empty ...

	if [ -s ~/.kvm.conf ]; then
		aba_info "Copying kvm.conf from '~/.kvm.conf' to $PWD/kvm.conf"
		cp ~/.kvm.conf kvm.conf
	else
		aba_info "Copying 'kvm.conf' from 'templates/kvm.conf'"
		cp templates/kvm.conf .
	fi

	trap - ERR
	edit_file kvm.conf "To deploy to KVM, edit the 'kvm.conf' file" || exit 0

	ensure_virsh
	source <(normalize-kvm-conf)

	aba_info Checking kvm config file: $PWD/kvm.conf
	if ! virsh -c "$LIBVIRT_URI" version; then
		aba_abort "Cannot connect to libvirt at $LIBVIRT_URI.  Please edit $PWD/kvm.conf and try again!"
	else
		aba_info "Saving working version of 'kvm.conf' to '~/.kvm.conf'."
		[ -s kvm.conf ] && cp kvm.conf ~/.kvm.conf
	fi
fi

exit 0
