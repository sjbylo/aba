#!/bin/bash
# Install and edit the KVM/libvirt conf file
# This script should only be run on the internal bastion (with SSH access to the KVM host)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Verify that KVM objects referenced in kvm.conf actually exist on the hypervisor.
# Called after virsh version succeeds (libvirt connection is valid).
# Uses SSH to KVM_HOST (derived from LIBVIRT_URI by normalize-kvm-conf).
# Runs checks in parallel; silent on success, reports all failures at once.
_kvm_verify_objects() {
	local _tmpdir
	_tmpdir=$(mktemp -d)
	local _ssh="ssh -F $HOME/.aba/ssh.conf ${KVM_HOST}"

	if [ "$KVM_STORAGE_POOL" ]; then
		( $_ssh "test -d '$KVM_STORAGE_POOL'" 2>/dev/null \
			&& echo "ok Storage pool '$KVM_STORAGE_POOL'" > "$_tmpdir/pool" \
			|| echo "fail Storage pool directory '$KVM_STORAGE_POOL' not found on ${KVM_HOST}" > "$_tmpdir/pool" ) &
	fi

	if [ "$KVM_NETWORK" ]; then
		( $_ssh "test -d '/sys/class/net/$KVM_NETWORK'" 2>/dev/null \
			&& echo "ok Network bridge '$KVM_NETWORK'" > "$_tmpdir/network" \
			|| echo "fail Network bridge '$KVM_NETWORK' not found on ${KVM_HOST}" > "$_tmpdir/network" ) &
	fi

	wait

	local _err=""
	for _f in "$_tmpdir"/*; do
		[ -f "$_f" ] || continue
		local _line
		_line=$(cat "$_f")
		case "$_line" in
			ok*)   aba_debug "Verified: ${_line#ok }" ;;
			fail*) aba_warning "${_line#fail }"; _err=1 ;;
		esac
	done
	rm -rf "$_tmpdir"

	if [ "$_err" ]; then
		aba_abort "One or more KVM objects in kvm.conf do not exist. Fix kvm.conf and try again."
	fi

	return 0
}

source <(normalize-aba-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"

[ "$platform" != "kvm" ] && \
	aba_info "To set the platform value in aba.conf run: 'aba -p kvm' and run: 'aba kvm'." && rm -f kvm.conf && exit 0

aba_debug "Checking for $PWD/kvm.conf file .."

if [ -s kvm.conf ]; then
	aba_debug "kvm.conf exists, test it..."

	ensure_virsh
	source <(normalize-kvm-conf)

	aba_debug "Checking kvm config file: $PWD/kvm.conf"

	if ! virsh -c "$LIBVIRT_URI" version >/dev/null 2>&1; then
		aba_abort "Cannot connect to libvirt at $LIBVIRT_URI.  Please edit $PWD/kvm.conf and try again!"
	fi

	_kvm_verify_objects

	aba_debug "KVM config file $PWD/kvm.conf ok"

	[ ! -s ~/.kvm.conf ] && cp kvm.conf ~/.kvm.conf && aba_debug "Saved kvm.conf to ~/.kvm.conf"

	exit 0
else
	aba_info "kvm.conf exists but is empty ..."

	if [ -s ~/.kvm.conf ]; then
		aba_info "Copying kvm.conf from '~/.kvm.conf' to $PWD/kvm.conf"
		cp ~/.kvm.conf kvm.conf
	else
		aba_info "Copying 'kvm.conf' from 'templates/kvm.conf'"
		cp templates/kvm.conf .

		# Set arch-appropriate defaults for boot and graphics
		if [ "$ARCH" = "s390x" ]; then
			sed -i 's/^KVM_BOOT_ARGS=.*/KVM_BOOT_ARGS=hd,cdrom/' kvm.conf
			sed -i 's/^KVM_GRAPHICS_ARGS=.*/KVM_GRAPHICS_ARGS=none/' kvm.conf
			aba_info "Detected s390x: set KVM_BOOT_ARGS=hd,cdrom and KVM_GRAPHICS_ARGS=none"
		fi
	fi

	trap - ERR
	edit_file kvm.conf "To deploy to KVM, edit the 'kvm.conf' file" || exit 0

	ensure_virsh
	source <(normalize-kvm-conf)

	aba_info "Checking kvm config file: $PWD/kvm.conf"
	aba_debug "Running: virsh -c $LIBVIRT_URI version"
	if ! virsh -c "$LIBVIRT_URI" version; then
		aba_abort "Cannot connect to libvirt at $LIBVIRT_URI.  Please edit $PWD/kvm.conf and try again!"
	else
		_kvm_verify_objects

		aba_info "Saving working version of 'kvm.conf' to '~/.kvm.conf'."
		[ -s kvm.conf ] && cp kvm.conf ~/.kvm.conf
	fi
fi

exit 0
