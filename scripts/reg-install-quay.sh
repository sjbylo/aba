#!/bin/bash
# Install Quay mirror registry on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_load_config
reg_check_fqdn
reg_detect_existing
reg_setup_data_dir quay
reg_generate_password
reg_verify_localhost

# --- Quay-specific: SSH-to-localhost key setup ---
# The Quay mirror-registry installer requires SSH access to the install host.
# (The generic DNS/SSH check is already done by reg_verify_localhost above.)
# Ensure a test key pair exists so the installer can SSH to localhost.
temp_aba_key=~/.ssh/aba_check_ssh
temp_aba_pub_key=~/.ssh/aba_check_ssh.pub

if [ ! -s $temp_aba_key ]; then
	if [ ! -w ~/.ssh ]; then
		aba_warning "Cannot write to ~/.ssh to check SSH connectivity! The Quay installer will likely fail."
		sleep 2
	else
		aba_debug "Creating test ssh key: $temp_aba_key"
		ssh-keygen -t rsa -f $temp_aba_key -N '' >/dev/null
		chmod 600 $temp_aba_key $temp_aba_pub_key
		cat $temp_aba_pub_key >> ~/.ssh/authorized_keys
	fi
fi

if [ -s $temp_aba_key ]; then
	if ! ssh -F $ssh_conf_file -i $temp_aba_key $reg_host touch $flag_file >/dev/null; then
		aba_abort \
			"For local Quay installation, SSH must work to $reg_host. The Quay installer requires this." \
			"Failed command: ssh -i $temp_aba_key $reg_host"
	fi
fi

ask "Install Quay mirror registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_info "Installing Quay registry on localhost ..."

reg_open_firewall

# Ensure the quay_installer SSH key exists (used internally by mirror-registry)
[ ! -s $HOME/.ssh/quay_installer ] && \
	ssh-keygen -t ed25519 -f $HOME/.ssh/quay_installer -N '' >/dev/null && \
	cat $HOME/.ssh/quay_installer.pub >> $HOME/.ssh/authorized_keys

cmd="./mirror-registry install -v --initUser $reg_user --quayHostname $reg_host $reg_root_opts"

aba_info "Installing mirror registry with command:"
aba_info "$cmd --initPassword <hidden>"

if ! ensure_quay_registry; then
	error_msg=$(get_task_error "$TASK_QUAY_REG")
	aba_abort "Failed to extract mirror-registry:\n$error_msg"
fi

eval $cmd --initPassword $reg_pw

reg_post_install "$reg_root/quay-rootCA/rootCA.pem" quay

eval "echo Registry installed from $(hostname -f):$PWD > $reg_root/.install.source"
