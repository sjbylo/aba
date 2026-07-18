#!/bin/bash
# Install Quay mirror registry on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_load_config
reg_detect_existing
reg_check_fqdn
reg_setup_data_dir quay
reg_generate_password
reg_verify_localhost
reg_check_quay_resources

# --- Quay-specific: verify SSH to localhost ---
# The Quay mirror-registry installer uses Ansible, which requires SSH to localhost.
# Try SSH first. Only attempt remediation if it fails.
flag_file="$ABA_TMP/flag.$RANDOM"
rm -f "$flag_file"

_quay_ssh_ok=""
if ssh -F "$ssh_conf_file" "$reg_host" "mkdir -p $ABA_TMP && touch $flag_file" >/dev/null 2>&1 && [ -f "$flag_file" ]; then
	_quay_ssh_ok=1
fi
rm -f "$flag_file"

if [ -z "$_quay_ssh_ok" ]; then
	aba_info "SSH to '$reg_host' failed — attempting to fix ..."

	# Is sshd running?
	if ! systemctl is-active --quiet sshd; then
		aba_info "sshd is not running — starting and enabling ..."
		if ! $SUDO systemctl enable --now sshd; then
			aba_abort \
				"Failed to start sshd." \
				"The Quay mirror-registry installer requires SSH access to localhost." \
				"Start sshd manually ('sudo systemctl start sshd') and try again."
		fi
	fi

	# Ensure ~/.ssh exists with correct permissions (sshd StrictModes requires 700).
	if [ ! -d ~/.ssh ]; then
		mkdir -p ~/.ssh
		chmod 700 ~/.ssh
	elif [ "$(stat -c '%a' ~/.ssh)" != "700" ]; then
		aba_info "Fixing ~/.ssh permissions ($(stat -c '%a' ~/.ssh) → 700) ..."
		chmod 700 ~/.ssh
	fi

	# Ensure a test key pair exists so we can SSH to localhost.
	temp_aba_key=~/.ssh/aba_check_ssh
	temp_aba_pub_key=~/.ssh/aba_check_ssh.pub

	if [ ! -s "$temp_aba_key" ]; then
		if [ ! -w ~/.ssh ]; then
			aba_abort \
				"Cannot write to ~/.ssh to create SSH test key." \
				"The Quay mirror-registry installer requires SSH access to localhost." \
				"Fix permissions on ~/.ssh and try again."
		fi
		aba_debug "Creating test ssh key: $temp_aba_key"
		ssh-keygen -t rsa -f "$temp_aba_key" -N '' >/dev/null
		chmod 600 "$temp_aba_key" "$temp_aba_pub_key"
		cat "$temp_aba_pub_key" >> ~/.ssh/authorized_keys
		chmod 600 ~/.ssh/authorized_keys
	fi

	# Retry SSH after remediation
	rm -f "$flag_file"
	if ! ssh -F "$ssh_conf_file" -i "$temp_aba_key" "$reg_host" "mkdir -p $ABA_TMP && touch $flag_file" >/dev/null 2>&1 || [ ! -f "$flag_file" ]; then
		rm -f "$flag_file"
		aba_warn "SSH to '$reg_host' failed — trying localhost instead ..."
		if ! ssh -F "$ssh_conf_file" -i "$temp_aba_key" localhost "mkdir -p $ABA_TMP && touch $flag_file" >/dev/null 2>&1 || [ ! -f "$flag_file" ]; then
			aba_abort \
				"For local Quay installation, SSH must work to localhost. The Quay installer requires this." \
				"Tried: ssh -F $ssh_conf_file -i $temp_aba_key $reg_host" \
				"Tried: ssh -F $ssh_conf_file -i $temp_aba_key localhost" \
				"Check: sshd running? ~/.ssh permissions? firewall?"
		fi
	fi
	rm -f "$flag_file"
fi

# Pre-install assertion: detect stale state from a previous install that
# was not fully uninstalled. Stale redis_pass secrets cause WRONGPASS on
# the new install; stale containers hold ports and conflict with Ansible.
_stale=""
ss -tlnp | grep -q ":${reg_port} " && _stale+="  Port $reg_port still listening"$'\n'
podman secret ls --format '{{.Name}}' | grep -q redis_pass && _stale+="  redis_pass podman secret exists"$'\n'
podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres' && _stale+="  Quay containers still present"$'\n'
if [ -n "$_stale" ]; then
	aba_abort \
		"Stale registry state detected on localhost before install:" \
		"$_stale" \
		"A previous install was not fully cleaned up." \
		"Run 'aba -d $(basename "$PWD") uninstall' first, or clean up manually."
fi

ask "Install Quay mirror registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_info "Installing Quay registry on localhost ..."

reg_open_firewall

# Ensure the quay_installer SSH key exists (used internally by mirror-registry)
if [ ! -s $HOME/.ssh/quay_installer ]; then
	ssh-keygen -t ed25519 -f $HOME/.ssh/quay_installer -N '' >/dev/null
	cat $HOME/.ssh/quay_installer.pub >> $HOME/.ssh/authorized_keys
fi

aba_info "Installing mirror registry with command:"
aba_info "./mirror-registry install -v --initUser $reg_user --quayHostname $reg_hostport $reg_root_opts --initPassword <hidden>"

if ! ensure_quay_registry; then
	error_msg=$(get_task_error "$TASK_INST_QUAY_REG")
	aba_abort "Failed to extract mirror-registry:\n$error_msg"
fi

# $reg_root_opts is intentionally unquoted — it expands to multiple arguments.
# $reg_pw is quoted to preserve special characters (e.g. " ! @ #).
# shellcheck disable=SC2086
if ! ./mirror-registry install -v --initUser "$reg_user" --quayHostname "$reg_hostport" $reg_root_opts --initPassword "$reg_pw"; then
	aba_abort "Quay mirror-registry install failed. Check the output above for details."
fi

reg_post_install "$reg_root/quay-rootCA/rootCA.pem" quay

cat > "$reg_root/INSTALLED_BY_ABA.md" <<-BREADCRUMB
	Mirror registry installed by ABA: https://github.com/sjbylo/aba.git
	Installed from: $(hostname -f):$PWD
	Date: $(date '+%Y-%m-%d %H:%M:%S')

	On host $(hostname -f):
	To verify:    cd $PWD && aba verify
	To uninstall: cd $PWD && aba uninstall
BREADCRUMB
