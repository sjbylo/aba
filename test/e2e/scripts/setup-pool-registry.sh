#!/usr/bin/env bash
# =============================================================================
# Setup pre-populated mirror registry on conN for E2E testing (out-of-band).
# =============================================================================
# Installs a lightweight Docker (OCI) registry under /opt/pool-reg and syncs
# OCP release images + one operator from each of the three catalogs.
# Does NOT use aba's mirror workflow.
#
# Usage:
#   setup-pool-registry.sh --channel CHANNEL --version VERSION [--host HOSTNAME]
#
# Prerequisites:
#   - ~/.pull-secret.json
#   - Internet access (to download images from registry.redhat.io)
#
# Operators synced (one per catalog):
#   - cincinnati-operator        (redhat-operator)
#   - nginx-ingress-operator     (certified-operator)
#   - flux                       (community-operator)
#
# Persistent state stored under /opt/pool-reg/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$SCRIPT_DIR/../lib/constants.sh"
REG_PORT=8443
REG_PW="p4ssw0rd"
REG_USER="init"
REG_PATH="/ocp4/openshift4"
CONTAINER_NAME="pool-registry"
INTERNAL_PORT=5000

# Operators to sync (one from each catalog)
OP_REDHAT="cincinnati-operator"
OP_CERTIFIED="nginx-ingress-operator"
OP_COMMUNITY="flux"

# --- Parse arguments --------------------------------------------------------

channel=""
version=""
reg_host=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)  channel="$2"; shift 2 ;;
        --version)  version="$2"; shift 2 ;;
        --host)     reg_host="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --channel CHANNEL --version VERSION [--host HOSTNAME]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$channel" ]] && { echo "ERROR: --channel required" >&2; exit 1; }
[[ -z "$version" ]] && { echo "ERROR: --version required" >&2; exit 1; }
[[ -z "$reg_host" ]] && reg_host="$(hostname -f)"

ver_major="${version%.*}"   # e.g. 4.17.8 -> 4.17

echo "============================================================"
echo "  E2E Pool Registry Setup (Docker registry)"
echo "  Host:     $reg_host:$REG_PORT"
echo "  Data:     $POOL_REG_DIR"
echo "  Channel:  $channel"
echo "  Version:  $version (major: $ver_major)"
echo "  Operators: $OP_REDHAT, $OP_CERTIFIED, $OP_COMMUNITY"
echo "============================================================"

# --- Check prerequisites ----------------------------------------------------

if [[ ! -f ~/.pull-secret.json ]]; then
    echo "ERROR: ~/.pull-secret.json not found" >&2
    exit 1
fi

# Create data directory under /opt (where there's space)
if [[ ! -d "$POOL_REG_DIR" ]]; then
    sudo mkdir -p "$POOL_REG_DIR"
    sudo chown "$(id -u):$(id -g)" "$POOL_REG_DIR"
fi

CERTS_DIR="$POOL_REG_DIR/certs"
AUTH_DIR="$POOL_REG_DIR/auth"
DATA_DIR="$POOL_REG_DIR/data"
SYNC_DIR="$POOL_REG_DIR/sync"
mkdir -p "$CERTS_DIR" "$AUTH_DIR" "$DATA_DIR" "$SYNC_DIR"

# --- Step 1: Install Docker registry (idempotent) ---------------------------

if curl --retry 3 -sfk -o /dev/null -u "${REG_USER}:${REG_PW}" "https://${reg_host}:${REG_PORT}/v2/"; then
    echo "[1/4] Docker registry already running on ${reg_host}:${REG_PORT} -- skipping install"
else
    echo "[1/4] Installing Docker registry on ${reg_host}:${REG_PORT} ..."

    if ! rpm -q podman &>/dev/null; then
        sudo dnf install -y podman
    fi

    # Generate CA certificate
    if [[ ! -f "$CERTS_DIR/ca.crt" ]]; then
        echo "  Generating CA certificate ..."
        openssl genrsa -out "$CERTS_DIR/ca.key" 4096
        openssl req -x509 -new -nodes -key "$CERTS_DIR/ca.key" \
            -sha256 -days 3650 -out "$CERTS_DIR/ca.crt" \
            -subj "/CN=E2E-PoolRegistryCA"
    fi

    # Generate server certificate signed by CA
    if [[ ! -f "$CERTS_DIR/registry.crt" ]]; then
        echo "  Generating server certificate ..."
        openssl genrsa -out "$CERTS_DIR/registry.key" 4096
        openssl req -new -key "$CERTS_DIR/registry.key" \
            -out "$CERTS_DIR/registry.csr" \
            -subj "/CN=$reg_host"
        cat > "$CERTS_DIR/registry-ext.cnf" <<-EOF
		subjectAltName = DNS:$reg_host
		extendedKeyUsage = serverAuth
		EOF
        openssl x509 -req -in "$CERTS_DIR/registry.csr" \
            -CA "$CERTS_DIR/ca.crt" -CAkey "$CERTS_DIR/ca.key" -CAcreateserial \
            -out "$CERTS_DIR/registry.crt" -days 3650 -sha256 \
            -extfile "$CERTS_DIR/registry-ext.cnf"
    fi

    # Create htpasswd auth
    echo "  Creating authentication ..."
    htpasswd -Bbn "$REG_USER" "$REG_PW" > "$AUTH_DIR/htpasswd"

    # Stop our container, any stale containers on port 8443, and orphan pods
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
    for _cid in $(podman ps -a --format '{{.ID}} {{.Ports}}' 2>/dev/null | grep ":${REG_PORT}" | awk '{print $1}'); do
        echo "  Removing stale container $_cid holding port ${REG_PORT} ..."
        podman rm -f "$_cid" 2>/dev/null || true
    done
    podman pod rm -f -a 2>/dev/null || true

    # Open firewall port
    if rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        sudo firewall-cmd --add-port=${REG_PORT}/tcp --permanent 2>/dev/null || true
        sudo firewall-cmd --reload
    fi

    # Start the registry (--network host avoids rootless podman pasta hairpin bug)
    echo "  Starting Docker registry (data: $DATA_DIR) ..."
    podman run -d \
        --network host \
        --restart=always \
        --name "$CONTAINER_NAME" \
        -v "${DATA_DIR}:/var/lib/registry:Z" \
        -v "${CERTS_DIR}:/certs:Z" \
        -v "${AUTH_DIR}:/auth:Z" \
        -e REGISTRY_HTTP_ADDR=0.0.0.0:${REG_PORT} \
        -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
        -e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
        -e REGISTRY_AUTH=htpasswd \
        -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
        -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
        docker.io/library/registry:latest

    # Trust the CA system-wide
    sudo install -m 644 "$CERTS_DIR/ca.crt" /etc/pki/ca-trust/source/anchors/pool-registry-rootCA.pem
    sudo update-ca-trust extract

    # Verify the registry is up
    if ! curl -sfk -o /dev/null -u "${REG_USER}:${REG_PW}" "https://${reg_host}:${REG_PORT}/v2/"; then
        echo "ERROR: Registry not reachable after starting" >&2
        exit 1
    fi

    echo "  Docker registry installed successfully"
fi

# --- Step 2: Merge auth (pull-secret + local registry creds) ----------------

echo "[2/4] Setting up container auth ..."

POOL_AUTH="$POOL_REG_DIR/auth.json"
enc_password=$(echo -n "${REG_USER}:${REG_PW}" | base64 -w0)

printf '{"auths":{"%s:%s":{"auth":"%s"}}}\n' "$reg_host" "$REG_PORT" "$enc_password" > "$POOL_REG_DIR/pool-reg-creds.json"
jq -s '.[0] * .[1]' "$HOME/.pull-secret.json" "$POOL_REG_DIR/pool-reg-creds.json" > "$POOL_AUTH"

podman login -u "$REG_USER" -p "$REG_PW" --authfile "$POOL_AUTH" "https://${reg_host}:${REG_PORT}"

echo "  Auth configured in $POOL_AUTH"

# --- Step 3: Create imageset config -----------------------------------------

echo "[3/4] Creating imageset config ..."

cat > "$SYNC_DIR/imageset-config.yaml" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: ${channel}-${ver_major}
      minVersion: ${version}
      maxVersion: ${version}
      type: ocp
    graph: true
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v${ver_major}
    packages:
    - name: ${OP_REDHAT}
  - catalog: registry.redhat.io/redhat/certified-operator-index:v${ver_major}
    packages:
    - name: ${OP_CERTIFIED}
  - catalog: registry.redhat.io/redhat/community-operator-index:v${ver_major}
    packages:
    - name: ${OP_COMMUNITY}
EOF

echo "  Imageset config written to $SYNC_DIR/imageset-config.yaml"

# --- Step 4: Run oc-mirror sync ---------------------------------------------

# Skip if already synced for this version AND the images are still there.
DONE_MARKER="$SYNC_DIR/.synced-${version}"
if [[ -f "$DONE_MARKER" ]]; then
    if skopeo inspect --authfile "$POOL_AUTH" "docker://${reg_host}:${REG_PORT}${REG_PATH}/openshift/release-images:${version}-$(uname -m)" &>/dev/null; then
        echo "[4/4] Already synced for ${version} (verified) -- skipping"
    else
        echo "[4/4] Done-marker exists but release image not found -- re-syncing"
        rm -f "$DONE_MARKER"
    fi
fi

if [[ ! -f "$DONE_MARKER" ]]; then
    echo "[4/4] Syncing images to ${reg_host}:${REG_PORT} (this may take 30+ minutes) ..."

    [[ -x "$HOME/bin/oc-mirror" ]] && export PATH="$HOME/bin:$PATH"

    _oc_mirror_tmp_installed=""
    if ! command -v oc-mirror &>/dev/null; then
        echo "  Installing oc-mirror via aba cli Makefile ..."
        make -C "$ABA_ROOT/cli" ~/bin/oc-mirror
        export PATH="$HOME/bin:$PATH"
        _oc_mirror_tmp_installed=1
    fi

    cd "$SYNC_DIR"
    umask 0022
    oc-mirror --v2 \
        --config imageset-config.yaml \
        --workspace file://. \
        "docker://${reg_host}:${REG_PORT}${REG_PATH}" \
        --authfile "$POOL_AUTH" \
        --image-timeout 15m \
        --parallel-images 4 \
        --retry-delay 30s \
        --retry-times 3

    touch "$DONE_MARKER"
    echo "  Sync complete"

    if [[ -n "$_oc_mirror_tmp_installed" ]]; then
        echo "  Removing temporarily installed oc-mirror ..."
        rm -f ~/bin/oc-mirror
    fi
fi

echo ""
echo "============================================================"
echo "  Pool registry ready: ${reg_host}:${REG_PORT}"
echo "  Data dir:     $DATA_DIR"
echo "  Creds file:   $POOL_REG_DIR/pool-reg-creds.json"
echo "  CA cert:      $CERTS_DIR/ca.crt"
echo "  Synced:       OCP ${version} + ${OP_REDHAT}, ${OP_CERTIFIED}, ${OP_COMMUNITY}"
echo "============================================================"
