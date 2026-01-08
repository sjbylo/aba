#!/bin/bash 
# -----------------------------------------------------------------------------
# Secure Docker Registry Setup Script with Verification
# Internal port 5000, external port 8443 by default
# TLS + Basic Auth + SELinux + CA trust
# Verifies docker, podman, curl, skopeo, oc-mirror
# -----------------------------------------------------------------------------

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
verify-aba-conf || exit 1
verify-mirror-conf || exit 1

[ ! "$data_dir" ] && data_dir=$HOME || data_dir=$(eval echo $data_dir)  # Eval any '~'

set -e

REGISTRY_DOMAIN="${1:-registry.example.com}"
[ "$reg_host" ] && REGISTRY_DOMAIN=$reg_host   # Overrride if set
[ "$reg_port" ] && EXTERNAL_PORT=$reg_port
[ "$reg_user" ] && REGISTRY_USER=$reg_user
[ "$reg_pw" ] && REGISTRY_PASS=$reg_pw

# --- Configurable defaults ---
REGISTRY_NAME="registry"
INTERNAL_PORT=5000
EXTERNAL_PORT="${EXTERNAL_PORT:-8443}"
REGISTRY_DATA_DIR="$data_dir/docker-reg/data"
REGISTRY_CERTS_DIR=$REGISTRY_DATA_DIR/.docker-certs  # Is mounted into container
REGISTRY_AUTH_DIR=$REGISTRY_DATA_DIR/.docker-auth

REGISTRY_USER="${REGISTRY_USER:-init}"
REGISTRY_PASS="${REGISTRY_PASS:-p4ssw0rd}"

fail_check() {
	echo_red "[ABA] $1"
}

pass_check() {
	aba_info_ok "$1"
}

# --- Step 1: Create directories ---
REGISTRY_DATA_DIR=$(eval echo "$REGISTRY_DATA_DIR")  # Resolve any ~
mkdir -p "$REGISTRY_DATA_DIR" "$REGISTRY_CERTS_DIR" "$REGISTRY_AUTH_DIR"

# --- Step 2: Generate CA ---
if [[ ! -f "$REGISTRY_CERTS_DIR/ca.crt" || ! -f "$REGISTRY_CERTS_DIR/ca.key" ]]; then
	echo_yellow "Generating CA certificate..."
	openssl genrsa -out "$REGISTRY_CERTS_DIR/ca.key" 4096
	openssl req -x509 -new -nodes -key "$REGISTRY_CERTS_DIR/ca.key" \
		-sha256 -days 3650 -out "$REGISTRY_CERTS_DIR/ca.crt" \
		-subj "/CN=MyRegistryCA"
	aba_info_ok "CA created in $REGISTRY_CERTS_DIR/"
else
	aba_info_ok "Existing CA found, skipping."
fi

# --- Step 3: Generate registry cert signed by CA ---
if [[ ! -f "$REGISTRY_CERTS_DIR/registry.crt" || ! -f "$REGISTRY_CERTS_DIR/registry.key" ]]; then
	echo_yellow "Generating registry certificate signed by CA..."
	openssl genrsa -out "$REGISTRY_CERTS_DIR/registry.key" 4096
	openssl req -new -key "$REGISTRY_CERTS_DIR/registry.key" \
		-out "$REGISTRY_CERTS_DIR/registry.csr" \
		-subj "/CN=$REGISTRY_DOMAIN"
	cat > "$REGISTRY_CERTS_DIR/registry-ext.cnf" <<-EOF
	subjectAltName = DNS:$REGISTRY_DOMAIN
	extendedKeyUsage = serverAuth
	EOF
	openssl x509 -req -in "$REGISTRY_CERTS_DIR/registry.csr" \
		-CA "$REGISTRY_CERTS_DIR/ca.crt" -CAkey "$REGISTRY_CERTS_DIR/ca.key" -CAcreateserial \
		-out "$REGISTRY_CERTS_DIR/registry.crt" -days 3650 -sha256 \
		-extfile "$REGISTRY_CERTS_DIR/registry-ext.cnf"
	aba_info_ok "Registry certificate created in $REGISTRY_CERTS_DIR/"
else
	aba_info_ok "Existing registry certificate found, skipping."
fi

if [ ! "$REGISTRY_PASS" ]; then
	REGISTRY_PASS=$(openssl rand -base64 12)
fi

# --- Step 4: Generate htpasswd credentials ---
echo_yellow "Creating authentication file..."
htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" > "$REGISTRY_AUTH_DIR/htpasswd"
#podman run --rm --entrypoint htpasswd httpd:2 -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" \ 
#    > "$REGISTRY_AUTH_DIR/htpasswd"
aba_info_ok "Credentials stored for user '$REGISTRY_USER'."

# --- Step 5: Stop & remove old registry if exists ---
if podman ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
	echo_yellow "Stopping and removing old registry container..."
	podman rm -f "$REGISTRY_NAME" || true
fi

# --- Step 6: Run secure registry ---
echo_yellow "[ABA] Starting secure Docker Registry at https://$REGISTRY_DOMAIN:$EXTERNAL_PORT/ Data dir: $REGISTRY_DATA_DIR"
podman run -d \
	-p ${EXTERNAL_PORT}:${INTERNAL_PORT} \
	--restart=always \
	--name "$REGISTRY_NAME" \
	-v "${REGISTRY_DATA_DIR}:/var/lib/registry:Z" \
	-v "${REGISTRY_CERTS_DIR}:/certs:Z" \
	-v "${REGISTRY_AUTH_DIR}:/auth:Z" \
	-e REGISTRY_HTTP_ADDR=0.0.0.0:${INTERNAL_PORT} \
	-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
	-e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
	-e REGISTRY_AUTH=htpasswd \
	-e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
	-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
	docker.io/library/registry:latest
	#-v "$(pwd)/${REGISTRY_CERTS_DIR}:/certs:Z" \
	#-v "$(pwd)/${REGISTRY_AUTH_DIR}:/auth:Z" \

aba_info "Allowing firewall access to this host at $reg_host/$reg_port ..."
$SUDO firewall-cmd --state && \
	$SUDO firewall-cmd --add-port=$reg_port/tcp --permanent && \
		$SUDO firewall-cmd --reload

# --- Step 7: Add CA to system trust ---
#echo_yellow "Adding CA to system trust (requires sudo)..."
# No need: only for docker
###$SUDO cp "$REGISTRY_CERTS_DIR/ca.crt" /etc/pki/ca-trust/source/anchors/

mkdir -p regcreds
cp "$REGISTRY_CERTS_DIR/ca.crt" regcreds/rootCA.pem
echo -n -e "$REGISTRY_USER\n$REGISTRY_PASS\n" | make password
aba verify

# --- Step 8: Verification ---
echo_yellow "[ABA] Running post-deployment verification..."

REGISTRY_URL_SERVICE="$REGISTRY_DOMAIN:$EXTERNAL_PORT"
REGISTRY_URL="https://$REGISTRY_URL_SERVICE"

# 1. curl
if curl -k -u "$REGISTRY_USER:$REGISTRY_PASS" -fsSL "$REGISTRY_URL/v2/" >/dev/null 2>&1; then
    pass_check "curl /v2/ succeeded"
else
    fail_check "curl /v2/ failed"

    exit 1
fi

# 2. podman login
if echo "$REGISTRY_PASS" | podman login "$REGISTRY_URL" --username "$REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
    pass_check "podman login succeeded"
else
    fail_check "podman login failed"

    exit 1
fi

# 4. skopeo inspect
if skopeo inspect --tls-verify=true --creds "$REGISTRY_USER:$REGISTRY_PASS" "docker://$REGISTRY_URL/doesnotexist" >/dev/null 2>&1; then
    fail_check "skopeo inspect unexpectedly succeeded on non-existent image"
else
    pass_check "skopeo inspect authentication check passed"
fi

# --- Step 9: Completion message ---
aba_info_ok "Secure Docker Registry deployment complete!"
aba_info_ok "Access: $REGISTRY_URL"
aba_info_ok "Login username: $REGISTRY_USER"
aba_info_ok "Login password: $REGISTRY_PASS"
aba_info_ok docker login "$REGISTRY_URL" --username "$REGISTRY_USER" --password "$REGISTRY_PASS"
aba_info_ok podman login "$REGISTRY_URL" --username "$REGISTRY_USER" --password "$REGISTRY_PASS"

exit 0

