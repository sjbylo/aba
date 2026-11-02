#!/bin/bash
# Install the Go-based Quay mirror registry (omr) on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.
# Uses the omr mirror-registry binary's 'install' command, which handles
# init (certs, admin user, database), Quadlet creation, and service start.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_load_config
aba_progress "DONE|reg_config"
aba_progress "START|reg_env"

reg_detect_existing

reg_check_fqdn
reg_setup_data_dir "$_OMR_VENDOR"
reg_generate_password

reg_verify_localhost

aba_progress "DONE|reg_env"

_OMR_IMAGE_FILE="omr-image.tgz"
_OMR_BIN_DIR="omr"
_OMR_BIN="$_OMR_BIN_DIR/mirror-registry"

ask "Install $_OMR_VENDOR registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_progress "START|reg_download"
aba_info "Installing $_OMR_VENDOR registry on localhost ..."

# --- Ensure image file exists (needed for mirror-registry install -image-archive) ---
# On connected hosts, pull + save if the file isn't already present.
if [ ! -f "$_OMR_IMAGE_FILE" ]; then
	if ! podman image exists "$_OMR_IMAGE" 2>/dev/null; then
		aba_info "Pulling $_OMR_VENDOR image: $_OMR_IMAGE ..."
		if ! podman pull "$_OMR_IMAGE"; then
			aba_abort "Failed to pull $_OMR_VENDOR image: $_OMR_IMAGE" \
				"Check network connectivity and registry credentials."
		fi
	fi
	aba_info "Saving $_OMR_VENDOR image to $_OMR_IMAGE_FILE ..."
	if ! podman save -o "$_OMR_IMAGE_FILE" "$_OMR_IMAGE"; then
		rm -f "$_OMR_IMAGE_FILE"
		aba_abort "Failed to save $_OMR_VENDOR image to $_OMR_IMAGE_FILE." \
			"Check available disk space."
	fi
fi

# Ensure the install binary is extracted from the container image.
_omr_ensure_binary

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
	if ! reg_omr_install_or_recover "./$_OMR_BIN" "$_OMR_IMAGE_FILE"; then
		aba_abort \
			"$_OMR_VENDOR install failed." \
			"Check the output above for errors."
	fi
fi

aba_progress "DONE|reg_install"
aba_progress "START|reg_firewall"

# OMR uses a systemd quadlet (WantedBy=default.target) -- systemd handles
# auto-start directly. Only linger is needed so the user's systemd instance
# stays alive after logout.
if [ "$(id -u)" -ne 0 ] && command -v loginctl >/dev/null 2>&1; then
	if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
		aba_info "Enabling loginctl linger for $USER (so registry survives reboot) ..."
		$SUDO loginctl enable-linger "$USER"
	fi
fi

reg_open_firewall

aba_progress "DONE|reg_firewall"
aba_progress "START|reg_postcfg"

reg_post_install "$reg_root/ssl.cert" "$_OMR_VENDOR"

aba_progress "DONE|reg_postcfg"
aba_progress "START|reg_verify"

# Phase 1: Wait for the TLS listener (no auth = no lockout risk)
if ! try_cmd -n 10 -d 1 -m "Wait for registry on ${reg_host}:${reg_port}" -- \
	probe_host --any --quick "$reg_url/v2/" "registry readiness"; then
	_local_ips=$(hostname -I 2>/dev/null | xargs)
	_localhost_ok="no"
	probe_host --any --quick "https://localhost:$reg_port/v2/" "localhost" && _localhost_ok="yes"

	aba_abort \
		"Registry installed but not reachable via FQDN." \
		"" \
		"  FQDN:         $reg_host → ${fqdn_ip:-unresolved}" \
		"  Localhost:     localhost:$reg_port responds: $_localhost_ok" \
		"  Local IPs:    $_local_ips" \
		"" \
		"Common causes:" \
		"  - DNS points to a different host" \
		"  - Firewall blocking port $reg_port" \
		"" \
		"Credentials saved. After fixing: aba -d $(basename "$PWD") verify"
fi

# Phase 2: Single auth check — NO retry to avoid Quay brute-force lockout
if ! reg_check_v2_auth "$reg_url" "$reg_user" "$reg_pw"; then
	aba_abort \
		"Registry is reachable but authentication failed on $reg_host:$reg_port." \
		"Check registry credentials (reg_user=$reg_user in mirror.conf)." \
		"Credentials saved. After fixing: aba -d $(basename "$PWD") verify"
fi

reg_cleanup_backup
aba_progress "DONE|reg_verify"
