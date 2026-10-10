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

# Load image from tarball (air-gapped) or pull from registry (connected).
# Ensure the tarball always exists — the install binary needs -image-archive
# because its compiled-in image reference differs from $_OMR_IMAGE.
if [ -f "$_OMR_IMAGE_FILE" ]; then
	aba_info "Loading $_OMR_VENDOR image from $_OMR_IMAGE_FILE ..."
	podman load -i "$_OMR_IMAGE_FILE"
else
	if ! podman image exists "$_OMR_IMAGE" 2>/dev/null; then
		aba_info "Pulling $_OMR_VENDOR image: $_OMR_IMAGE ..."
		podman pull "$_OMR_IMAGE"
	fi
	aba_info "Saving $_OMR_VENDOR image to $_OMR_IMAGE_FILE ..."
	podman save -o "$_OMR_IMAGE_FILE" "$_OMR_IMAGE"
fi

# Extract the install binary from the container image
if [ ! -x "$_OMR_BIN" ]; then
	aba_info "Extracting $_OMR_VENDOR install binary ..."
	mkdir -p "$_OMR_BIN_DIR"
	_cid=$(podman create "$_OMR_IMAGE")
	podman cp "$_cid:/mirror-registry" "$_OMR_BIN"
	podman rm "$_cid" >/dev/null
	chmod +x "$_OMR_BIN"
fi

aba_progress "DONE|reg_download"
aba_progress "START|reg_install"

# Install or reinstall via the tool's own 'install' command.
# Fresh install: pass -init-user/-init-password-stdin for admin setup.
# Reinstall (data preserved, service removed): omit init flags — the tool
# detects existing data, skips admin provisioning, creates Quadlet, starts service.
if [ -f "$reg_root/auth/admin-password" ]; then
	aba_info "Existing data detected at $reg_root — reinstalling (preserving data) ..."
	if ! ./"$_OMR_BIN" install \
		-data-dir "$reg_root" \
		-hostname "$reg_host" \
		-port "$reg_port" \
		-image-archive "$_OMR_IMAGE_FILE"; then
		aba_abort \
			"$_OMR_VENDOR reinstall failed." \
			"Check the output above for errors."
	fi
else
	aba_info "Running: $_OMR_BIN install -data-dir $reg_root -hostname $reg_host -port $reg_port ..."
	if ! echo "$reg_pw" | ./"$_OMR_BIN" install \
		-data-dir "$reg_root" \
		-hostname "$reg_host" \
		-port "$reg_port" \
		-init-user "$reg_user" \
		-init-password-stdin \
		-image-archive "$_OMR_IMAGE_FILE"; then
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

cat > "$reg_root/INSTALLED_BY_ABA.md" <<-BREADCRUMB
	Mirror registry installed by ABA: https://github.com/sjbylo/aba.git
	Installed from: $(hostname -f):$PWD
	Date: $(date '+%Y-%m-%d %H:%M:%S')

	On host $(hostname -f):
	To verify:    cd $PWD && aba verify
	To uninstall: cd $PWD && aba uninstall
BREADCRUMB

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

aba_progress "DONE|reg_verify"
