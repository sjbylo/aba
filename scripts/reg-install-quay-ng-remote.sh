#!/bin/bash
# Install quay-ng registry on a remote host via SSH.
# Called by reg-install.sh dispatcher; not intended for direct invocation.
# Uses the quay-ng mirror-registry binary's 'install' command on the remote
# host, which handles init, Quadlet creation, and service start.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_install "$_QUAY_NG_VENDOR"

# Pre-install assertion: detect stale state.
# The tool refuses to install if a Quadlet file exists (even if service is dead).
_stale=""
$_ssh "ss -tlnp | grep -q ':${reg_port} '" && _stale+="  Port $reg_port still listening"$'\n'
$_ssh "systemctl --user is-active quay.service &>/dev/null || sudo systemctl is-active quay.service &>/dev/null" && _stale+="  quay.service still active"$'\n'
$_ssh "test -f ~/.config/containers/systemd/quay.container 2>/dev/null || test -f /etc/containers/systemd/quay.container 2>/dev/null" && _stale+="  Leftover Quadlet file (quay.container)"$'\n'
if [ -n "$_stale" ]; then
	aba_abort \
		"Stale registry state detected on $reg_host before install:" \
		"$_stale" \
		"A previous install was not fully cleaned up." \
		"Run 'aba -d $(basename "$PWD") uninstall' first, or clean up manually."
fi

ask "Install $_QUAY_NG_VENDOR registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

aba_info "Installing $_QUAY_NG_VENDOR registry on remote host $reg_host ..."

_image_file="quay-ng-image.tgz"
_bin_dir="quay-ng"
_bin="$_bin_dir/mirror-registry"

if [ ! -f "$_image_file" ]; then
	aba_info "Downloading $_QUAY_NG_VENDOR image ..."
	make -s "$_image_file"
fi

# Extract the install binary from the container image (locally)
if [ ! -x "$_bin" ]; then
	aba_info "Extracting $_QUAY_NG_VENDOR install binary ..."
	mkdir -p "$_bin_dir"
	podman load -i "$_image_file"
	_cid=$(podman create "$_QUAY_NG_IMAGE")
	podman cp "$_cid:/mirror-registry" "$_bin"
	podman rm "$_cid" >/dev/null
	chmod +x "$_bin"
fi

# Copy binary and image tarball to remote host
aba_info "Copying $_QUAY_NG_VENDOR binary and image to remote host ..."
$_scp "$_bin" "$_image_file" "$_target:$remote_dir/"

# Install or reinstall on remote host via the tool's own 'install' command.
# Fresh install: pass -init-user/-init-password-stdin for admin setup.
# Reinstall (data preserved, service removed): omit init flags — the tool
# detects existing data, skips admin provisioning, creates Quadlet, starts service.
aba_info "Running $_QUAY_NG_VENDOR install on remote host ..."
if ! $_ssh "
	set -e
	if [ -f $reg_root/auth/admin-password ]; then
		echo '[ABA] Existing data detected — reinstalling (preserving data) ...'
		$remote_dir/mirror-registry install \
			-data-dir $reg_root \
			-hostname $reg_host \
			-port $reg_port \
			-image-archive $remote_dir/$_image_file
	else
		echo '$reg_pw' | $remote_dir/mirror-registry install \
			-data-dir $reg_root \
			-hostname $reg_host \
			-port $reg_port \
			-init-user $reg_user \
			-init-password-stdin \
			-image-archive $remote_dir/$_image_file
	fi
	# Enable linger so the user's systemd instance survives logout
	if [ \"\$(id -u)\" -ne 0 ] && command -v loginctl >/dev/null; then
		if ! loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
			$SUDO loginctl enable-linger \"\$USER\"
		fi
	fi
"; then
	aba_abort "$_QUAY_NG_VENDOR install failed on remote host $reg_host." \
		"Check the output above for details."
fi

# Wait for serve to generate the TLS certificate
_cert_ok=""
for _i in $(seq 1 15); do
	if $_ssh "test -f $reg_root/ssl.cert" 2>/dev/null; then
		_cert_ok=1
		break
	fi
	sleep 1
done
if [ -z "$_cert_ok" ]; then
	aba_abort "Registry started but $reg_root/ssl.cert was not created within 15s." \
		"Check the quay.service logs on $reg_host: journalctl --user -u quay.service"
fi

reg_remote_post_install "$_QUAY_NG_VENDOR" "$reg_root/ssl.cert"
