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

# --- Purge repos not in the ISC keep-list, then garbage-collect blobs -------

# Repo prefixes that belong to the ISC (OCP release + 3 operators + catalogs).
# Anything outside these prefixes was left behind by a previous test suite.
KEEP_PREFIXES=(
    "ocp4/openshift4/openshift/"
    "ocp4/openshift4/openshift-update-service/"
    "ocp4/openshift4/nginx/"
    "ocp4/openshift4/fluxcd/"
    "ocp4/openshift4/community-operator-pipeline-prod/"
    "ocp4/openshift4/redhat/"
    "ocp4/openshift4/brancz/"
)

pool_registry_purge_extras() {
    local _reg="https://${1}:${REG_PORT}"
    local _auth="${REG_USER}:${REG_PW}"

    local all_repos
    all_repos=$(curl -sk -u "$_auth" "${_reg}/v2/_catalog?n=500" 2>/dev/null \
        | python3 -c 'import json,sys; [print(r) for r in json.load(sys.stdin).get("repositories",[])]' 2>/dev/null)

    local deleted=0 kept=0

    for repo in $all_repos; do
        local skip=0
        for prefix in "${KEEP_PREFIXES[@]}"; do
            [[ "$repo" == "${prefix}"* ]] && { skip=1; break; }
        done
        [[ $skip -eq 1 ]] && { kept=$((kept + 1)); continue; }

        local tags
        tags=$(curl -sk -u "$_auth" "${_reg}/v2/${repo}/tags/list" 2>/dev/null \
            | python3 -c 'import json,sys; t=json.load(sys.stdin).get("tags") or []; [print(x) for x in t]' 2>/dev/null)
        [[ -z "$tags" ]] && continue

        for tag in $tags; do
            local digest
            digest=$(curl -skI -u "$_auth" \
                -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                -H "Accept: application/vnd.oci.image.manifest.v1+json" \
                -H "Accept: application/vnd.oci.image.index.v1+json" \
                -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
                "${_reg}/v2/${repo}/manifests/${tag}" 2>/dev/null \
                | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r\n')
            [[ -z "$digest" ]] && continue

            local rc
            rc=$(curl -sk -u "$_auth" -X DELETE "${_reg}/v2/${repo}/manifests/${digest}" \
                -o /dev/null -w "%{http_code}" 2>/dev/null)
            [[ "$rc" == "202" ]] && deleted=$((deleted + 1))
        done
    done

    if [[ $deleted -gt 0 ]]; then
        echo "  Purged $deleted manifest(s) from non-ISC repos ($kept repos kept)"
        _pool_registry_gc
    fi
}

_pool_registry_gc() {
    echo "  Running garbage collection (registry will restart) ..."
    podman stop "$CONTAINER_NAME" >/dev/null
    podman run --rm \
        -v "${POOL_REG_DIR}/data:/var/lib/registry:Z" \
        docker.io/library/registry:latest \
        garbage-collect --delete-untagged /etc/distribution/config.yml >/dev/null 2>&1
    podman start "$CONTAINER_NAME" >/dev/null

    # Wait for registry to be healthy after restart (avoids oc-mirror race)
    local _i
    for _i in $(seq 1 30); do
        if curl -sfk -o /dev/null -u "${REG_USER}:${REG_PW}" "https://${reg_host}:${REG_PORT}/v2/"; then
            break
        fi
        sleep 2
    done

    echo "  GC complete -- $(du -sh "${POOL_REG_DIR}/data" | awk '{print $1}') in data dir"
}

# Prune old OCP release versions from the pool registry.
# oc-mirror is additive -- it never removes images from previous syncs,
# so blobs from older OCP versions accumulate across test runs and eat disk.
# This deletes release-image tags AND their component images for any version
# other than $keep_ver, then garbage-collects the orphaned blobs.
pool_registry_prune_old_releases() {
    local _host="$1" _keep_ver="$2"
    local _reg="https://${_host}:${REG_PORT}"
    local _auth="${REG_USER}:${REG_PW}"
    local _arch
    _arch="$(uname -m)"

    local _total_deleted=0

    # Prune both repos: release-images (manifest lists) and release (components)
    local _repo
    for _repo in "${REG_PATH#/}/openshift/release-images" "${REG_PATH#/}/openshift/release"; do
        local tags
        tags=$(curl -sk -u "$_auth" "${_reg}/v2/${_repo}/tags/list" 2>/dev/null \
            | python3 -c 'import json,sys; t=json.load(sys.stdin).get("tags") or []; [print(x) for x in t]' 2>/dev/null)
        [[ -z "$tags" ]] && continue

        local deleted=0
        for tag in $tags; do
            [[ "$tag" == "${_keep_ver}-${_arch}" ]] && continue
            [[ "$tag" == "${_keep_ver}-${_arch}-"* ]] && continue
            [[ "$tag" == sha256-* ]] && continue

            local digest
            digest=$(curl -skI -u "$_auth" \
                -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
                -H "Accept: application/vnd.oci.image.manifest.v1+json" \
                -H "Accept: application/vnd.oci.image.index.v1+json" \
                -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
                "${_reg}/v2/${_repo}/manifests/${tag}" 2>/dev/null \
                | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r\n')
            [[ -z "$digest" ]] && continue

            local rc
            rc=$(curl -sk -u "$_auth" -X DELETE \
                "${_reg}/v2/${_repo}/manifests/${digest}" \
                -o /dev/null -w "%{http_code}" 2>/dev/null)
            [[ "$rc" == "202" ]] && deleted=$((deleted + 1))
        done

        [[ $deleted -gt 0 ]] && echo "  Pruned $deleted old tag(s) from ${_repo##*/}"
        _total_deleted=$((_total_deleted + deleted))
    done

    if [[ $_total_deleted -gt 0 ]]; then
        echo "  Pruned $_total_deleted old release tag(s) total"
        _pool_registry_gc
    fi
}

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
    podman rm -f "$CONTAINER_NAME" || true
    for _cid in $(podman ps -a --format '{{.ID}} {{.Ports}}' | grep ":${REG_PORT}" | awk '{print $1}'); do
        echo "  Removing stale container $_cid holding port ${REG_PORT} ..."
        podman rm -f "$_cid" || true
    done
    podman pod rm -f -a || true

    # Open firewall port
    if rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        sudo firewall-cmd --add-port=${REG_PORT}/tcp --permanent || true
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

# --- Step 1b: Purge leftover repos from previous test suites ----------------
# Other suites (e.g. airgapped-existing-reg) load ACM, vote-app, etc. into
# this pool registry. Without cleanup, blobs accumulate and fill the disk.

if curl --retry 3 -sfk -o /dev/null -u "${REG_USER}:${REG_PW}" "https://${reg_host}:${REG_PORT}/v2/"; then
    echo "[1b/4] Checking for leftover repos from previous test suites ..."
    pool_registry_purge_extras "$reg_host"
    pool_registry_prune_old_releases "$reg_host" "$version"
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

    # Clear stale oc-mirror workspace to avoid corrupted OCI index after interrupted syncs
    rm -rf "$SYNC_DIR/working-dir" "$SYNC_DIR/.oc-mirror" "$HOME/.oc-mirror"

    [[ -x "$HOME/bin/oc-mirror" ]] && export PATH="$HOME/bin:$PATH"

    _oc_mirror_tmp_installed=""
    if ! command -v oc-mirror &>/dev/null; then
        echo "  Installing oc-mirror via aba cli Makefile ..."
        # Wait for any background run_once downloads to finish before extracting;
        # otherwise Make sees a partially-downloaded tarball and extraction fails.
        "$ABA_ROOT/scripts/cli-download-all.sh" --wait oc-mirror 2>/dev/null || true
        make -C "$ABA_ROOT/cli" ~/bin/oc-mirror
        export PATH="$HOME/bin:$PATH"
        _oc_mirror_tmp_installed=1
    fi

    # Deploy registries.d sigstore config (oc-mirror reads it automatically)
    _SIGSTORE_TMPL="$ABA_ROOT/templates/aba-sigstore-config.yaml"
    _SIGSTORE_DEST="$HOME/.config/containers/registries.d/aba-sigstore.yaml"
    if [[ -f "$_SIGSTORE_TMPL" && ! -f "$_SIGSTORE_DEST" ]]; then
        mkdir -p "$HOME/.config/containers/registries.d"
        cp "$_SIGSTORE_TMPL" "$_SIGSTORE_DEST"
        echo "  Deployed registries.d sigstore config"
    fi

    # Enable sigstore writes to the pool registry (colon replaced with dash for filename)
    _mirror_safe="${reg_host}:${REG_PORT}"
    _mirror_safe="${_mirror_safe//:/-}"
    _MIRROR_SIGSTORE="$HOME/.config/containers/registries.d/aba-sigstore-mirror-${_mirror_safe}.yaml"
    if [[ ! -f "$_MIRROR_SIGSTORE" ]]; then
        mkdir -p "$HOME/.config/containers/registries.d"
        cat > "$_MIRROR_SIGSTORE" <<-SIGEOF
		docker:
		    ${reg_host}:${REG_PORT}:
		        use-sigstore-attachments: true
		SIGEOF
        echo "  Deployed per-mirror sigstore config for ${reg_host}:${REG_PORT}"
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
