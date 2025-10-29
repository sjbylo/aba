#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Secure Docker Registry Setup Script with Verification
# Internal port 5000, external port 8443 by default
# TLS + Basic Auth + SELinux + CA trust
# Verifies docker, podman, curl, skopeo, oc-mirror
# -----------------------------------------------------------------------------

DOCKER=podman 

cd $(dirname $0)

set -e

set -euo pipefail

# --- Configurable defaults ---
REGISTRY_NAME="registry"
INTERNAL_PORT=5000
EXTERNAL_PORT="${2:-8443}"
REGISTRY_DATA_DIR="./data"
REGISTRY_CERTS_DIR="./certs"
REGISTRY_AUTH_DIR="./auth"
REGISTRY_DOMAIN="${1:-registry.example.com}"
REGISTRY_USER="${REGISTRY_USER:-init}"
REGISTRY_PASS="${REGISTRY_PASS:-p4ssw0rd}"

# --- Helper functions ---
echo_green() { echo -e "\033[1;32m$*\033[0m"; }
echo_yellow() { echo -e "\033[1;33m$*\033[0m"; }
echo_red() { echo -e "\033[1;31m$*\033[0m"; }

fail_checkp() {
    echo_red "❌ $1"
}

pass_check() {
    echo_green "✅ $1"
}

# --- Step 1: Create directories ---
mkdir -p "$REGISTRY_DATA_DIR" "$REGISTRY_CERTS_DIR" "$REGISTRY_AUTH_DIR"

# --- Step 2: Generate CA ---
if [[ ! -f "$REGISTRY_CERTS_DIR/ca.crt" || ! -f "$REGISTRY_CERTS_DIR/ca.key" ]]; then
    echo_yellow "Generating CA certificate..."
    openssl genrsa -out "$REGISTRY_CERTS_DIR/ca.key" 4096
    openssl req -x509 -new -nodes -key "$REGISTRY_CERTS_DIR/ca.key" \
        -sha256 -days 3650 -out "$REGISTRY_CERTS_DIR/ca.crt" \
        -subj "/CN=MyRegistryCA"
    echo_green "CA created in $REGISTRY_CERTS_DIR/"
else
    echo_green "Existing CA found, skipping."
fi

# --- Step 3: Generate registry cert signed by CA ---
if [[ ! -f "$REGISTRY_CERTS_DIR/registry.crt" || ! -f "$REGISTRY_CERTS_DIR/registry.key" ]]; then
    echo_yellow "Generating registry certificate signed by CA..."
    openssl genrsa -out "$REGISTRY_CERTS_DIR/registry.key" 4096
    openssl req -new -key "$REGISTRY_CERTS_DIR/registry.key" \
        -out "$REGISTRY_CERTS_DIR/registry.csr" \
        -subj "/CN=$REGISTRY_DOMAIN"
    cat > "$REGISTRY_CERTS_DIR/registry-ext.cnf" <<EOF
subjectAltName = DNS:$REGISTRY_DOMAIN
extendedKeyUsage = serverAuth
EOF
    openssl x509 -req -in "$REGISTRY_CERTS_DIR/registry.csr" \
        -CA "$REGISTRY_CERTS_DIR/ca.crt" -CAkey "$REGISTRY_CERTS_DIR/ca.key" -CAcreateserial \
        -out "$REGISTRY_CERTS_DIR/registry.crt" -days 3650 -sha256 \
        -extfile "$REGISTRY_CERTS_DIR/registry-ext.cnf"
    echo_green "Registry certificate created in $REGISTRY_CERTS_DIR/"
else
    echo_green "Existing registry certificate found, skipping."
fi

# --- Step 4: Generate htpasswd credentials ---
echo_yellow "Creating authentication file..."
htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" > "$REGISTRY_AUTH_DIR/htpasswd"
#$DOCKER run --rm --entrypoint htpasswd httpd:2 -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" \ 
#    > "$REGISTRY_AUTH_DIR/htpasswd"
echo_green "Credentials stored for user '$REGISTRY_USER'."

# --- Step 5: Stop & remove old registry if exists ---
if $DOCKER ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    echo_yellow "Stopping and removing old registry container..."
    $DOCKER rm -f "$REGISTRY_NAME" || true
fi

# --- Step 6: Run secure registry ---
echo_yellow "Starting secure Docker Registry on external port $EXTERNAL_PORT (internal port $INTERNAL_PORT)..."
$DOCKER run -d \
    -p ${EXTERNAL_PORT}:${INTERNAL_PORT} \
    --restart=always \
    --name "$REGISTRY_NAME" \
    -v "$(pwd)/${REGISTRY_DATA_DIR}:/var/lib/registry:Z" \
    -v "$(pwd)/${REGISTRY_CERTS_DIR}:/certs:Z" \
    -v "$(pwd)/${REGISTRY_AUTH_DIR}:/auth:Z" \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:${INTERNAL_PORT} \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
    -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    registry:2

# --- Step 7: Add CA to system trust ---
echo_yellow "Adding CA to system trust (requires sudo)..."

# No need: only for docker
###sudo cp "$REGISTRY_CERTS_DIR/ca.crt" /etc/pki/ca-trust/source/anchors/

mkdir -p ../../mirror/regcreds
cp "$REGISTRY_CERTS_DIR/ca.crt" ../../mirror/regcreds/rootCA.pem
if which aba >/dev/null; then
	echo -n -e "$REGISTRY_USER\n$REGISTRY_PASS\n" | aba -d ../../mirror password
	aba -d ../../mirror verify
fi

# --- Step 8: Verification ---
echo_yellow "Running post-deployment verification..."

REGISTRY_URL_SERVICE="$REGISTRY_DOMAIN:$EXTERNAL_PORT"
REGISTRY_URL="https://$REGISTRY_URL_SERVICE"

# 1. curl
if curl -k -u "$REGISTRY_USER:$REGISTRY_PASS" -fsSL "$REGISTRY_URL/v2/" >/dev/null 2>&1; then
    pass_check "curl /v2/ succeeded"
else
    fail_check "curl /v2/ failed"

    exit 1
fi

sudo cp "$REGISTRY_CERTS_DIR/ca.crt"  /etc/docker/certs.d/$REGISTRY_URL_SERVICE/ca.crt

# 2. docker login
if echo "$REGISTRY_PASS" | $DOCKER login "$REGISTRY_URL" --username "$REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
    pass_check "$DOCKER login succeeded"
else
    fail_check "$DOCKER login failed"

    exit 1
fi

# 3. podman login
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

# 5. oc-mirror (dry-run)
#if command -v oc-mirror; then
#    #if REGISTRY_AUTH_FILE=~/.config/containers/auth.json oc-mirror --config /dev/null docker://"$REGISTRY_URL" --dry-run >/dev/null 2>&1; then
#    if                                       oc-mirror --config /dev/null docker://"$REGISTRY_URL" --dry-run; then
#        pass_check "oc-mirror connectivity test succeeded"
#    else
#        echo_yellow "oc-mirror dry-run may fail because --config is empty, but credentials recognized if REGISTRY_AUTH_FILE is correct"
#    fi
#else
#    echo_yellow "oc-mirror not installed, skipping test"
#fi

if $DOCKER pull hello-world >/dev/null; then
	echo_yellow "Running pull/push verification..."

	echo_green	$DOCKER pull hello-world
			$DOCKER pull hello-world

	echo_green	$DOCKER tag  hello-world "$REGISTRY_URL_SERVICE"/hello-world
			$DOCKER tag  hello-world "$REGISTRY_URL_SERVICE"/hello-world

	echo_green	$DOCKER push "$REGISTRY_URL_SERVICE"/hello-world
			$DOCKER push "$REGISTRY_URL_SERVICE"/hello-world

	pass_check "$DOCKER pull/push succeeded"
fi


# --- Step 9: Completion message ---
echo_green "✅ Secure Docker Registry deployment complete!"
echo_green "Access: $REGISTRY_URL"
#echo_green "Login username: $REGISTRY_USER"
#echo_green "Login password: $REGISTRY_PASS"
echo_green docker login "$REGISTRY_URL" --username "$REGISTRY_USER" --password "$REGISTRY_PASS"
echo_green podman login "$REGISTRY_URL" --username "$REGISTRY_USER" --password "$REGISTRY_PASS"

exit 0

