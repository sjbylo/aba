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

# --- Quay-specific: verify SSH to localhost ---
# The Quay mirror-registry installer requires SSH access to the install host,
# even for local installs. Verify connectivity and warn about misconfigurations.

flag_file=/tmp/.$(whoami).$RANDOM
rm -f $flag_file

# Check if default SSH unexpectedly reaches a *remote* host (misconfigured DNS)
if h=$(ssh -F $ssh_conf_file $reg_host "touch $flag_file && hostname") >/dev/null 2>&1; then
	if [ ! -f $flag_file ]; then
		aba_warning \
			"Mirror registry configured for *local* install (reg_ssh_key is not defined)." \
			"But $reg_host resolves to $fqdn_ip, which reaches remote host [$h] via ssh!" \
			"Options:" \
			"1. Update DNS so '$reg_host' resolves to this localhost '$(hostname -s)'." \
			"2. Set 'reg_ssh_key' in mirror.conf for remote installation."
		sleep 2
	else
		rm -f $flag_file
		aba_info "SSH access to localhost via '$reg_host' is working."
	fi
fi

# Quay installer needs SSH to localhost -- ensure a test key pair exists
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
