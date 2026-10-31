#!/bin/bash
# Install omr registry on a remote host via SSH.
# Called by reg-install.sh dispatcher; not intended for direct invocation.
# Uses the omr mirror-registry binary's 'install' command on the remote
# host, which handles init, Quadlet creation, and service start.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_install "$_OMR_VENDOR"

aba_progress "DONE|reg_config"
aba_progress "START|reg_env"

reg_pre_install_stale_check "$_OMR_VENDOR" "$_ssh"

ask "Install $_OMR_VENDOR registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

aba_progress "DONE|reg_env"
aba_progress "START|reg_download"

aba_info "Installing $_OMR_VENDOR registry on remote host $reg_host ..."

_image_file="omr-image.tgz"
_bin_dir="omr"
_bin="$_bin_dir/mirror-registry"

if [ ! -f "$_image_file" ]; then
	aba_info "Downloading $_OMR_VENDOR image ..."
	make -s "$_image_file"
fi

# Ensure the install binary is extracted from the container image.
_omr_ensure_binary

# Copy binary and image tarball to remote host
aba_info "Copying $_OMR_VENDOR binary and image to remote host ..."
$_scp "$_bin" "$_image_file" "$_target:$remote_dir/"

aba_progress "DONE|reg_download"
aba_progress "START|reg_install"

# --- Skip install if registry already running (idempotent resume) ---
if probe_host --any "$reg_url/v2/" "existing registry" 2>/dev/null; then
	aba_info "Registry already running at $reg_host:$reg_port — skipping install"
else
	# Mark state as "installing" so a retry can detect and recover from a partial install
	reg_mark_installing "$_OMR_VENDOR"

	# Install via mirror-registry, with WORKAROUND for OMR's 30s health-check
	# timeout (start service / keep-data retry). See reg_omr_install_or_recover()
	# and BACKLOG.md — remove when upstream timeout is fixed and re-tested.
	aba_info "Running $_OMR_VENDOR install on remote host ..."
	if ! reg_omr_install_or_recover "./omr/mirror-registry" "$_image_file" "$_ssh" "$remote_dir"; then
		aba_abort "$_OMR_VENDOR install failed on remote host $reg_host." \
			"Check the output above for details."
	fi

	# Enable linger so the user's systemd instance survives logout
	$_ssh "
		if [ \"\$(id -u)\" -ne 0 ] && command -v loginctl >/dev/null; then
			if ! loginctl show-user \"\$USER\" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
				$SUDO loginctl enable-linger \"\$USER\"
			fi
		fi
	" || true
fi

aba_progress "DONE|reg_install"
aba_progress "START|reg_firewall"
aba_progress "DONE|reg_firewall"
aba_progress "START|reg_postcfg"

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

aba_progress "DONE|reg_postcfg"
aba_progress "START|reg_verify"

reg_remote_post_install "$_OMR_VENDOR" "$reg_root/ssl.cert"

reg_cleanup_backup
aba_progress "DONE|reg_verify"
