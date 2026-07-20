#!/bin/bash
# Install the Go-based Quay mirror registry (quay-ng) on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.
# Uses Podman Quadlet for systemd-managed container lifecycle.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_load_config
reg_detect_existing
reg_check_fqdn
reg_setup_data_dir "$_QUAY_NG_VENDOR"
reg_verify_localhost

_QUAY_NG_IMAGE_FILE="quay-ng-image.tgz"
_QUADLET_DIR="$HOME/.config/containers/systemd"
_QUADLET_FILE="$_QUADLET_DIR/quay.container"
_SERVICE_NAME="quay.service"

ask "Install $_QUAY_NG_VENDOR registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_info "Installing $_QUAY_NG_VENDOR registry on localhost ..."

# Load image from tarball (air-gapped) or pull from registry (connected)
if [ -f "$_QUAY_NG_IMAGE_FILE" ]; then
	aba_info "Loading $_QUAY_NG_VENDOR image from $_QUAY_NG_IMAGE_FILE ..."
	podman load -i "$_QUAY_NG_IMAGE_FILE"
elif ! podman image exists "$_QUAY_NG_IMAGE" 2>/dev/null; then
	aba_info "Pulling $_QUAY_NG_VENDOR image: $_QUAY_NG_IMAGE ..."
	podman pull "$_QUAY_NG_IMAGE"
fi

mkdir -p "$reg_root"

# Create Quadlet unit file for systemd-managed container
mkdir -p "$_QUADLET_DIR"
cat > "$_QUADLET_FILE" <<-EOF
[Unit]
Description=Quay OCI Registry ($_QUAY_NG_VENDOR)
After=network-online.target

[Container]
Image=$_QUAY_NG_IMAGE
Volume=${reg_root}:/data:Z
PublishPort=${reg_port}:${reg_port}
Exec=serve -data-dir /data -hostname $reg_host -addr :${reg_port}

[Install]
WantedBy=default.target
EOF

aba_info "Starting $_QUAY_NG_VENDOR registry service ..."
systemctl --user daemon-reload
if ! systemctl --user start "$_SERVICE_NAME"; then
	aba_abort \
		"Failed to start $_SERVICE_NAME." \
		"Check: journalctl --user -xeu $_SERVICE_NAME" \
		"Quadlet: $_QUADLET_FILE"
fi

# Wait for the registry to initialize (generates certs, creates admin)
aba_info "Waiting for registry to initialize ..."
local_ok=""
for i in $(seq 1 15); do
	if [ -f "$reg_root/auth/admin-password" ]; then
		local_ok=1
		break
	fi
	sleep 1
done
if [ ! "$local_ok" ]; then
	aba_abort \
		"Registry did not create admin credentials within 15 seconds." \
		"Check: journalctl --user -xeu $_SERVICE_NAME"
fi

# Read auto-generated credentials
reg_user="admin"
reg_pw=$(cat "$reg_root/auth/admin-password")

# Write actual credentials back to mirror.conf so it stays in sync
replace-value-conf -n reg_user -v "$reg_user" -f mirror.conf
replace-value-conf -n reg_pw -v "'$reg_pw'" -f mirror.conf

# Ensure rootless podman containers survive VM reboot
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

# Verify connectivity
if ! curl -k -fsSL --connect-timeout 10 "$reg_url/v2/" \
	-u "$reg_user:$reg_pw" >/dev/null 2>&1; then
	_local_ips=$(hostname -I 2>/dev/null | xargs)
	_localhost_ok="no"
	curl -k -fsSL --connect-timeout 10 "https://localhost:$reg_port/v2/" \
		-u "$reg_user:$reg_pw" >/dev/null 2>&1 && _localhost_ok="yes"

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
