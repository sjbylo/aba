#!/bin/bash
# Install Quay mirror registry on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $* in $PWD"

reg_install_begin quay
reg_check_quay_resources

# Quay requires a default route to exist, even on air-gapped hosts where no
# actual routing is needed.  Without it, container networking fails silently.
aba_debug "Checking for default route: $(ip route show default 2>/dev/null)"
if ! ip route show default | grep -q .; then
	_def_iface=$(ip -o -4 addr show up | grep -v ' lo ' | head -1 | awk '{print $2}')
	if [ -n "$_def_iface" ]; then
		aba_warn "No default route found — Quay registry requires one to function."
		aba_info "Adding default route: default dev $_def_iface scope link"
		$SUDO ip route add default dev "$_def_iface" scope link || \
			aba_warn "Failed to add default route. Registry install may fail."
	else
		# No suitable interface — can't create a route
		aba_warn "No default route and no suitable interface found. Registry install may fail."
	fi
fi

# --- Quay-specific: verify SSH to localhost ---
reg_quay_ensure_local_ssh

reg_pre_install_stale_check quay

ask "Install Quay mirror registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_progress "DONE|reg_env"

aba_info "Installing Quay registry on localhost ..."

aba_progress "START|reg_download"

# Ensure the quay_installer SSH key exists (used internally by mirror-registry)
reg_quay_installer_key

aba_info "Installing mirror registry with command:"
aba_info "./mirror-registry install -v --initUser $reg_user --quayHostname $reg_hostport $reg_root_opts --initPassword <hidden>"

if ! ensure_quay_registry; then
	error_msg=$(get_task_error "$TASK_INST_QUAY_REG")
	aba_abort "Failed to extract mirror-registry:\n$error_msg"
fi

aba_progress "DONE|reg_download"
aba_progress "START|reg_install"

# --- Skip install if registry already running (idempotent resume) ---
if probe_host --any "$reg_url/v2/" "existing registry" 2>/dev/null; then
	aba_info "Registry already running at $reg_host:$reg_port — skipping install"
else
	# Mark state as "installing" so a retry can detect and recover from a partial install
	reg_mark_installing quay

	# mirror-registry hardcodes --name ansible_runner_instance without
	# --replace.  A prior interrupted run leaves it behind (--rm is
	# unreliable on signal kill), blocking all subsequent calls.
	podman rm -f ansible_runner_instance 2>/dev/null || true

	# $reg_root_opts is intentionally unquoted — it expands to multiple arguments.
	# $reg_pw is quoted to preserve special characters (e.g. " ! @ #).
	# shellcheck disable=SC2086
	if ! ./mirror-registry install -v --initUser "$reg_user" --quayHostname "$reg_hostport" $reg_root_opts --initPassword "$reg_pw"; then
		aba_progress "FAIL|reg_install"
		aba_abort "Quay mirror-registry install failed. Check the output above for details."
	fi
fi

aba_progress "DONE|reg_install"
aba_progress "START|reg_firewall"

reg_open_firewall

aba_progress "DONE|reg_firewall"
aba_progress "START|reg_postcfg"

reg_post_install "$reg_root/quay-rootCA/rootCA.pem" quay

aba_progress "DONE|reg_postcfg"
reg_cleanup_backup
aba_progress "START|reg_verify"
aba_progress "DONE|reg_verify"
