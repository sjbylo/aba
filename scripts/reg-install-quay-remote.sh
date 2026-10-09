#!/bin/bash
# Install Quay (mirror-registry) on a remote host via SSH.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_remote_pre_install "quay"
aba_progress "DONE|reg_config"
aba_progress "START|reg_env"

reg_check_quay_resources "$_ssh"

# Pre-install assertion: detect stale state from a previous install that
# was not fully uninstalled.
_stale=""
$_ssh "ss -tlnp | grep -q ':${reg_port} '" && _stale+="  Port $reg_port still listening"$'\n'
$_ssh "podman secret ls --format '{{.Name}}' | grep -q redis_pass" && _stale+="  redis_pass podman secret exists"$'\n'
$_ssh "podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres'" && _stale+="  Quay containers still present"$'\n'
if [ -n "$_stale" ]; then
	aba_abort \
		"Stale registry state detected on $reg_host before install:" \
		"$_stale" \
		"A previous install was not fully cleaned up." \
		"Run 'aba -d $(basename "$PWD") uninstall' first, or clean up manually."
fi

ask "Install Quay mirror registry on remote host ($reg_ssh_user@$reg_host:$reg_root), accessible via $reg_hostport" || exit 1

aba_progress "DONE|reg_env"
aba_progress "START|reg_firewall"
aba_progress "DONE|reg_firewall"
aba_progress "START|reg_download"

aba_info "Installing Quay registry on remote host $reg_host ..."

if ! ensure_quay_registry; then
	error_msg=$(get_task_error "$TASK_INST_QUAY_REG")
	aba_abort "Failed to extract mirror-registry:\n$error_msg"
fi

# mirror-registry's internal Ansible needs quay_installer to SSH back to
# the same host.
$_ssh "if [ ! -s ~/.ssh/quay_installer ]; then mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f ~/.ssh/quay_installer -N '' >/dev/null && cat ~/.ssh/quay_installer.pub >> ~/.ssh/authorized_keys; fi"

aba_info "Copying mirror-registry tarball to remote host ..."
$_scp mirror-registry-*.tar.gz "$_target:$remote_dir/"

aba_progress "DONE|reg_download"
aba_progress "START|reg_install"

# printf '%q' safely escapes all shell metacharacters for remote evaluation
_escaped_pw=$(printf '%q' "$reg_pw")
cmd="cd $remote_dir && tar xvf mirror-registry-*.tar.gz && ./mirror-registry install -v --quayHostname $reg_hostport --initUser $reg_user --initPassword \"\$_reg_pw\" $reg_root_opts"

# mirror-registry hardcodes --name ansible_runner_instance without --replace.
$_ssh "podman rm -f ansible_runner_instance 2>/dev/null" || true

aba_info "Extracting and installing Quay registry on remote host ..."
aba_info "  ssh $reg_ssh_user@$reg_host: ./mirror-registry install -v --quayHostname $reg_hostport --initUser $reg_user --initPassword *** $reg_root_opts"
if ! $_ssh "export _reg_pw=$_escaped_pw && $cmd"; then
	aba_abort "Quay mirror-registry install failed on remote host $reg_host." \
		"Check the output above for details."
fi

aba_progress "DONE|reg_install"
aba_progress "START|reg_postcfg"
aba_progress "DONE|reg_postcfg"
aba_progress "START|reg_verify"

reg_remote_post_install "quay" "$reg_root/quay-rootCA/rootCA.pem"

aba_progress "DONE|reg_verify"
