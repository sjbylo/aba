#!/bin/bash
# Install the Go-based Quay mirror registry (quay-ng) on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.
# Uses the quay-ng mirror-registry binary's 'install' command, which handles
# init (certs, admin user, database), Quadlet creation, and service start.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_load_config
reg_detect_existing
reg_check_fqdn
reg_setup_data_dir "$_QUAY_NG_VENDOR"
reg_generate_password
reg_verify_localhost

_QUAY_NG_IMAGE_FILE="quay-ng-image.tgz"
_QUAY_NG_BIN_DIR="quay-ng"
_QUAY_NG_BIN="$_QUAY_NG_BIN_DIR/mirror-registry"

ask "Install $_QUAY_NG_VENDOR registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_info "Installing $_QUAY_NG_VENDOR registry on localhost ..."

# Load image from tarball (air-gapped) or pull from registry (connected).
# Ensure the tarball always exists — the install binary needs -image-archive
# because its compiled-in image reference differs from $_QUAY_NG_IMAGE.
if [ -f "$_QUAY_NG_IMAGE_FILE" ]; then
	aba_info "Loading $_QUAY_NG_VENDOR image from $_QUAY_NG_IMAGE_FILE ..."
	podman load -i "$_QUAY_NG_IMAGE_FILE"
else
	if ! podman image exists "$_QUAY_NG_IMAGE" 2>/dev/null; then
		aba_info "Pulling $_QUAY_NG_VENDOR image: $_QUAY_NG_IMAGE ..."
		podman pull "$_QUAY_NG_IMAGE"
	fi
	aba_info "Saving $_QUAY_NG_VENDOR image to $_QUAY_NG_IMAGE_FILE ..."
	podman save -o "$_QUAY_NG_IMAGE_FILE" "$_QUAY_NG_IMAGE"
fi

# Extract the install binary from the container image
if [ ! -x "$_QUAY_NG_BIN" ]; then
	aba_info "Extracting $_QUAY_NG_VENDOR install binary ..."
	mkdir -p "$_QUAY_NG_BIN_DIR"
	_cid=$(podman create "$_QUAY_NG_IMAGE")
	podman cp "$_cid:/mirror-registry" "$_QUAY_NG_BIN"
	podman rm "$_cid" >/dev/null
	chmod +x "$_QUAY_NG_BIN"
fi

# Install or reinstall via the tool's own 'install' command.
# Fresh install: pass -init-user/-init-password-stdin for admin setup.
# Reinstall (data preserved, service removed): omit init flags — the tool
# detects existing data, skips admin provisioning, creates Quadlet, starts service.
if [ -f "$reg_root/auth/admin-password" ]; then
	aba_info "Existing data detected at $reg_root — reinstalling (preserving data) ..."
	if ! ./"$_QUAY_NG_BIN" install \
		-data-dir "$reg_root" \
		-hostname "$reg_host" \
		-port "$reg_port" \
		-image-archive "$_QUAY_NG_IMAGE_FILE"; then
		aba_abort \
			"$_QUAY_NG_VENDOR reinstall failed." \
			"Check the output above for errors."
	fi
else
	aba_info "Running: $_QUAY_NG_BIN install -data-dir $reg_root -hostname $reg_host -port $reg_port ..."
	if ! echo "$reg_pw" | ./"$_QUAY_NG_BIN" install \
		-data-dir "$reg_root" \
		-hostname "$reg_host" \
		-port "$reg_port" \
		-init-user "$reg_user" \
		-init-password-stdin \
		-image-archive "$_QUAY_NG_IMAGE_FILE"; then
		aba_abort \
			"$_QUAY_NG_VENDOR install failed." \
			"Check the output above for errors."
	fi
fi

# Quay-ng uses a systemd quadlet (WantedBy=default.target) -- systemd handles
# auto-start directly. Only linger is needed so the user's systemd instance
# stays alive after logout.
if [ "$(id -u)" -ne 0 ] && command -v loginctl >/dev/null 2>&1; then
	if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
		aba_info "Enabling loginctl linger for $USER (so registry survives reboot) ..."
		$SUDO loginctl enable-linger "$USER"
	fi
fi

reg_open_firewall

reg_post_install "$reg_root/ssl.cert" "$_QUAY_NG_VENDOR"

cat > "$reg_root/INSTALLED_BY_ABA.md" <<-BREADCRUMB
	Mirror registry installed by ABA: https://github.com/sjbylo/aba.git
	Installed from: $(hostname -f):$PWD
	Date: $(date '+%Y-%m-%d %H:%M:%S')

	On host $(hostname -f):
	To verify:    cd $PWD && aba verify
	To uninstall: cd $PWD && aba uninstall
BREADCRUMB

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
