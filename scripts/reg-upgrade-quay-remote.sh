#!/bin/bash
# Upgrade the Quay mirror registry on a remote host via SSH and renew its
# server cert. Called by reg-upgrade.sh dispatcher; reads state from
# $regcreds_dir/state.sh.
#
# Do not skip when the registry answers on /v2/: install does that to resume,
# and here it would leave the old release in place.

source scripts/reg-common.sh

aba_debug "Starting: $0 $* in $PWD"

aba_progress "START|reg_config"

reg_remote_load_state "Quay"

# A CA near expiry stops here, before any download or copy.
reg_quay_check_ca "$_ssh"

aba_progress "DONE|reg_config"

ask "Upgrade Quay registry on remote host $reg_ssh_user@$reg_host:$reg_root (the registry restarts)" || exit 1

aba_progress "START|reg_download"

reg_quay_prepare_tarball
reg_remote_work_dir reg-upgrade

aba_info "Copying $quay_tarball to remote host $reg_host ..."
if ! $_scp "$quay_tarball" "$_target:$remote_dir/"; then
	aba_abort "Failed to copy $quay_tarball to $reg_host"
fi

aba_progress "DONE|reg_download"
aba_progress "START|reg_cert"

reg_quay_issue_leaf "$_ssh" "$leaf_days" "$remote_dir/leaf"

aba_progress "DONE|reg_cert"
aba_progress "START|reg_upgrade"

reg_quay_installer_key "$_ssh"

# Do not chown the data tree here (install does, before a reinstall): Quay
# writes it as the container uid, and the upgrade playbook does not give it back.

# mirror-registry hardcodes --name ansible_runner_instance without --replace.
$_ssh "podman rm -f ansible_runner_instance 2>/dev/null" || true

_upgrade_opts="-v --quayHostname $reg_host:$reg_port $reg_root_opts --sslCert $remote_dir/leaf/ssl.cert --sslKey $remote_dir/leaf/ssl.key"

aba_info "Extracting and upgrading Quay registry on remote host ..."
aba_info "  ssh $reg_ssh_user@$reg_host: ./mirror-registry upgrade $_upgrade_opts"
if ! $_ssh "cd $remote_dir && tar xmzf $quay_tarball && ./mirror-registry upgrade $_upgrade_opts"; then
	aba_progress "FAIL|reg_upgrade"
	aba_abort "Quay mirror-registry upgrade failed on remote host $reg_host." \
		"Check the output above for details."
fi

aba_progress "DONE|reg_upgrade"
aba_progress "START|reg_postcfg"

reg_post_upgrade "$_target:$reg_root/quay-rootCA/rootCA.pem" --ssh

aba_progress "DONE|reg_postcfg"
aba_progress "START|reg_verify"

reg_wait_and_check_auth

aba_progress "DONE|reg_verify"

aba_success "Quay registry upgraded at $reg_host:$reg_port (remote, user: $reg_ssh_user), root: $reg_root"
