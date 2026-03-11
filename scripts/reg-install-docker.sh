#!/bin/bash
# Install Docker/OCI registry on localhost.
# Called by reg-install.sh dispatcher; not intended for direct invocation.

source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

reg_load_config
reg_check_fqdn
reg_detect_existing
reg_setup_data_dir docker
reg_generate_password
reg_verify_localhost

REGISTRY_NAME="registry"
REGISTRY_DATA_DIR="$reg_root/data"
REGISTRY_CERTS_DIR="$REGISTRY_DATA_DIR/.docker-certs"
REGISTRY_AUTH_DIR="$REGISTRY_DATA_DIR/.docker-auth"

ask "Install Docker registry on localhost ($(hostname -s)), accessible via $reg_hostport" || exit 1

aba_info "Installing Docker registry on localhost ..."

# Pre-load Docker registry image from tarball (for air-gapped environments)
if [ -f docker-reg-image.tgz ]; then
	aba_info "Loading Docker registry image from docker-reg-image.tgz ..."
	podman load -i docker-reg-image.tgz
fi

mkdir -p "$REGISTRY_DATA_DIR" "$REGISTRY_CERTS_DIR" "$REGISTRY_AUTH_DIR"

# --- Generate CA certificate ---
if [[ ! -f "$REGISTRY_CERTS_DIR/ca.crt" || ! -f "$REGISTRY_CERTS_DIR/ca.key" ]]; then
	aba_info "Generating CA certificate ..."
	openssl genrsa -out "$REGISTRY_CERTS_DIR/ca.key" 4096
	openssl req -x509 -new -nodes -key "$REGISTRY_CERTS_DIR/ca.key" \
		-sha256 -days 3650 -out "$REGISTRY_CERTS_DIR/ca.crt" \
		-subj "/CN=ABA-RegistryCA"
fi

# --- Generate registry certificate signed by CA ---
if [[ ! -f "$REGISTRY_CERTS_DIR/registry.crt" || ! -f "$REGISTRY_CERTS_DIR/registry.key" ]]; then
	aba_info "Generating registry certificate ..."
	openssl genrsa -out "$REGISTRY_CERTS_DIR/registry.key" 4096
	openssl req -new -key "$REGISTRY_CERTS_DIR/registry.key" \
		-out "$REGISTRY_CERTS_DIR/registry.csr" \
		-subj "/CN=$reg_host"
	cat > "$REGISTRY_CERTS_DIR/registry-ext.cnf" <<-EOF
	subjectAltName = DNS:$reg_host
	extendedKeyUsage = serverAuth
	EOF
	openssl x509 -req -in "$REGISTRY_CERTS_DIR/registry.csr" \
		-CA "$REGISTRY_CERTS_DIR/ca.crt" -CAkey "$REGISTRY_CERTS_DIR/ca.key" -CAcreateserial \
		-out "$REGISTRY_CERTS_DIR/registry.crt" -days 3650 -sha256 \
		-extfile "$REGISTRY_CERTS_DIR/registry-ext.cnf"
fi

# --- Create htpasswd authentication ---
aba_info "Creating authentication file ..."
htpasswd -Bbn "$reg_user" "$reg_pw" > "$REGISTRY_AUTH_DIR/htpasswd"

# --- Stop old container if running ---
if podman ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
	aba_info "Removing old registry container ..."
	podman rm -f "$REGISTRY_NAME" || true
fi

# --- Start the registry container ---
# Use --network host to avoid rootless podman pasta hairpin NAT bug:
# with -p port mapping, connections from the host to its own FQDN/external IP
# go through pasta's userspace proxy, which breaks the TLS handshake.
aba_info "Starting Docker registry at $reg_url (data: $REGISTRY_DATA_DIR) ..."
podman run -d \
	--network host \
	--restart=always \
	--name "$REGISTRY_NAME" \
	-v "${REGISTRY_DATA_DIR}:/var/lib/registry:Z" \
	-v "${REGISTRY_CERTS_DIR}:/certs:Z" \
	-v "${REGISTRY_AUTH_DIR}:/auth:Z" \
	-e REGISTRY_HTTP_ADDR=0.0.0.0:${reg_port} \
	-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
	-e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
	-e REGISTRY_AUTH=htpasswd \
	-e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
	-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
	docker.io/library/registry:latest

reg_open_firewall

# Save credentials and state BEFORE the connectivity check, so the user
# can recover with 'aba verify' or 'aba uninstall' if networking fails.
reg_post_install "$REGISTRY_CERTS_DIR/ca.crt" docker

cat > "$reg_root/INSTALLED_BY_ABA.md" <<-BREADCRUMB
	Mirror registry installed by ABA: https://github.com/sjbylo/aba.git
	Installed from: $(hostname -f):$PWD
	Date: $(date '+%Y-%m-%d %H:%M:%S')

	On host $(hostname -f):
	To verify:    cd $PWD && aba verify
	To uninstall: cd $PWD && aba uninstall
BREADCRUMB

# Verify connectivity after saving state
if ! curl -k -fsSL --connect-timeout 10 "$reg_url/v2/" \
	-u "$reg_user:$reg_pw" >/dev/null 2>&1; then
	aba_abort \
		"Registry at $reg_url is not reachable after starting." \
		"The container is running but network connectivity failed." \
		"Common causes:" \
		"  - Firewall is blocking port $reg_port" \
		"  - nftables NOTRACK rules interfere with podman networking" \
		"  - FORWARD chain has a DROP/REJECT policy" \
		"Try: sudo nft flush chain ip raw PREROUTING && sudo nft flush chain ip raw OUTPUT" \
		"Also try: sudo iptables -P FORWARD ACCEPT && sudo iptables -F FORWARD" \
		"Credentials have been saved. After fixing networking, run: aba -d $(basename "$PWD") verify"
fi
