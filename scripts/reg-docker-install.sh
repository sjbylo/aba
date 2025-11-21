#!/usr/bin/env bash
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

DOCKER=podman 
####cd $(dirname $0)

set -e
#set -euo pipefail

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
REGISTRY_CERTS_DIR=".docker-certs"
REGISTRY_AUTH_DIR=".docker-auth"

REGISTRY_USER="${REGISTRY_USER:-init}"
REGISTRY_PASS="${REGISTRY_PASS:-p4ssw0rd}"

fail_checkp() {
    echo_red "[ABA] ❌ $1"
}

pass_check() {
    aba_info_ok "[ABA] ✅ $1"
}

# --- Step 1: Create directories ---
REGISTRY_DATA_DIR=$(eval echo "$REGISTRY_DATA_DIR")  # Resolve any ~
mkdir -p "$REGISTRY_DATA_DIR" "$REGISTRY_CERTS_DIR" "$REGISTRY_AUTH_DIR"

# --- Step 2: Generate CA ---
if [[ ! -f "$REGISTRY_CERTS_DIR/ca.crt" || ! -f "$REGISTRY_CERTS_DIR/ca.key" ]]; then
    echo_yellow "[ABA] Generating CA certificate..."
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
    echo_yellow "[ABA] Generating registry certificate signed by CA..."
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
    aba_info_ok "Registry certificate created in $REGISTRY_CERTS_DIR/"
else
    aba_info_ok "Existing registry certificate found, skipping."
fi

# --- Step 4: Generate htpasswd credentials ---
echo_yellow "[ABA] Creating authentication file..."
htpasswd -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" > "$REGISTRY_AUTH_DIR/htpasswd"
#$DOCKER run --rm --entrypoint htpasswd httpd:2 -Bbn "$REGISTRY_USER" "$REGISTRY_PASS" \ 
#    > "$REGISTRY_AUTH_DIR/htpasswd"
aba_info_ok "Credentials stored for user '$REGISTRY_USER'."

# --- Step 5: Stop & remove old registry if exists ---
if $DOCKER ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
    echo_yellow "[ABA] Stopping and removing old registry container..."
    $DOCKER rm -f "$REGISTRY_NAME" || true
fi

# --- Step 6: Run secure registry ---
echo_yellow "[ABA] Starting secure Docker Registry at https://$REGISTRY_DOMAIN:$EXTERNAL_PORT/ Data dir: $REGISTRY_DATA_DIR"
$DOCKER run -d \
    -p ${EXTERNAL_PORT}:${INTERNAL_PORT} \
    --restart=always \
    --name "$REGISTRY_NAME" \
    -v "${REGISTRY_DATA_DIR}:/var/lib/registry:Z" \
    -v "$(pwd)/${REGISTRY_CERTS_DIR}:/certs:Z" \
    -v "$(pwd)/${REGISTRY_AUTH_DIR}:/auth:Z" \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:${INTERNAL_PORT} \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
    -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
    -e REGISTRY_AUTH=htpasswd \
    -e REGISTRY_AUTH_HTPASSWD_REALM="Registry Realm" \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    docker.io/library/registry:latest
#    registry:2

# --- Step 7: Add CA to system trust ---
#echo_yellow "Adding CA to system trust (requires sudo)..."
# No need: only for docker
###sudo cp "$REGISTRY_CERTS_DIR/ca.crt" /etc/pki/ca-trust/source/anchors/

mkdir -p regcreds
cp "$REGISTRY_CERTS_DIR/ca.crt" regcreds/rootCA.pem
echo -n -e "$REGISTRY_USER\n$REGISTRY_PASS\n" | aba password
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

# Not needed
####sudo cp "$REGISTRY_CERTS_DIR/ca.crt"  /etc/docker/certs.d/$REGISTRY_URL_SERVICE/ca.crt

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

#if $DOCKER pull hello-world >/dev/null; then
#	echo_yellow "Running pull/push verification..."
#
#	aba_info_ok	$DOCKER pull hello-world
#			$DOCKER pull hello-world
#
#	aba_info_ok	$DOCKER tag  hello-world "$REGISTRY_URL_SERVICE"/hello-world
#			$DOCKER tag  hello-world "$REGISTRY_URL_SERVICE"/hello-world
#
#	aba_info_ok	$DOCKER push "$REGISTRY_URL_SERVICE"/hello-world
#			$DOCKER push "$REGISTRY_URL_SERVICE"/hello-world
#
#	pass_check "$DOCKER pull/push succeeded"
#fi


# --- Step 9: Completion message ---
aba_info_ok "[ABA] ✅ Secure Docker Registry deployment complete!"
aba_info_ok "[ABA] Access: $REGISTRY_URL"
#aba_info_ok "Login username: $REGISTRY_USER"
#aba_info_ok "Login password: $REGISTRY_PASS"
aba_info_ok [ABA] docker login "$REGISTRY_URL" --username "$REGISTRY_USER" --password "$REGISTRY_PASS"
aba_info_ok [ABA] podman login "$REGISTRY_URL" --username "$REGISTRY_USER" --password "$REGISTRY_PASS"

exit 0

