#!/bin/bash
# Install quay-ng registry on a remote host via SSH.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_install "$_QUAY_NG_VENDOR"

# Pre-install assertion: detect stale state.
_stale=""
$_ssh "ss -tlnp | grep -q ':${reg_port} '" && _stale+="  Port $reg_port still listening"$'\n'
$_ssh "systemctl --user is-active quay.service &>/dev/null" && _stale+="  quay.service still active"$'\n'
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
if [ ! -f "$_image_file" ]; then
	aba_info "Downloading $_QUAY_NG_VENDOR image ..."
	make -s "$_image_file"
fi

aba_info "Copying $_QUAY_NG_VENDOR image to remote host ..."
$_scp "$_image_file" "$_target:$remote_dir/"

aba_info "Running $_QUAY_NG_VENDOR install on remote host ..."

# Initialize registry on remote (creates certs, admin user, database)
$_ssh "
	set -e
	podman load -i $remote_dir/$_image_file
	mkdir -p $reg_root
	_abs_root=\$(cd $reg_root && pwd)
	if [ ! -f \"\$_abs_root/auth/admin-password\" ]; then
		echo '$reg_pw' | podman run --rm -i \
			-v \"\${_abs_root}:/data:Z\" $_QUAY_NG_IMAGE \
			init -data-dir /data -hostname $reg_host -init-user $reg_user -init-password-stdin
	fi
" || aba_abort "Registry initialization failed on $reg_host."

# Create Quadlet and start the service
if ! $_ssh "
	set -e
	_abs_root=\$(cd $reg_root && pwd)
	mkdir -p ~/.config/containers/systemd
	cat > ~/.config/containers/systemd/quay.container <<QUADLET
[Unit]
Description=Quay OCI Registry ($_QUAY_NG_VENDOR)
After=network-online.target

[Container]
Image=$_QUAY_NG_IMAGE
Volume=\${_abs_root}:/data:Z
PublishPort=${reg_port}:8443
Exec=serve -data-dir /data -hostname $reg_host -addr :8443

[Install]
WantedBy=default.target
QUADLET
	systemctl --user daemon-reload
	systemctl --user start quay.service
	[ -f \"\$_abs_root/auth/admin-password\" ] || { echo 'ERROR: admin-password not created'; exit 1; }
	# Quay-ng uses a systemd quadlet -- only linger needed for rootless
	if [ \"\$(id -u)\" -ne 0 ] && command -v loginctl >/dev/null; then
		if ! loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
			$SUDO loginctl enable-linger \"\$USER\"
		fi
	fi
"; then
	aba_abort "$_QUAY_NG_VENDOR install failed on remote host $reg_host." \
		"Check the output above for details."
fi

# Wait for serve to generate the TLS certificate (created on first startup, not by init)
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
