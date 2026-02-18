#!/bin/bash
# =============================================================================
# Setup pre-populated mirror registry on conN for E2E testing (out-of-band).
# =============================================================================
# Installs Quay locally and syncs OCP release images + one operator from
# each of the three catalogs. Does NOT use aba's mirror workflow.
#
# Usage:
#   setup-pool-registry.sh --channel CHANNEL --version VERSION [--host HOSTNAME]
#
# Prerequisites:
#   - ~/.pull-secret.json
#   - Internet access (to download images from registry.redhat.io)
#   - oc-mirror in PATH or ~/bin/
#
# Operators synced (one per catalog):
#   - cincinnati-operator        (redhat-operator)
#   - nginx-ingress-operator     (certified-operator)
#   - flux                       (community-operator)
#
# Persistent state stored under ~/.e2e-pool-registry/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

POOL_REG_DIR="$HOME/.e2e-pool-registry"
REG_PORT=8443
REG_PW="p4ssw0rd"
REG_USER="init"
MR_URL="https://mirror.openshift.com/pub/cgw/mirror-registry/latest"

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
echo "  E2E Pool Registry Setup (out-of-band)"
echo "  Host:     $reg_host:$REG_PORT"
echo "  Channel:  $channel"
echo "  Version:  $version (major: $ver_major)"
echo "  Operators: $OP_REDHAT, $OP_CERTIFIED, $OP_COMMUNITY"
echo "============================================================"

# --- Check prerequisites ----------------------------------------------------

if [[ ! -f ~/.pull-secret.json ]]; then
    echo "ERROR: ~/.pull-secret.json not found" >&2
    exit 1
fi

mkdir -p "$POOL_REG_DIR"

# --- Step 1: Ensure oc-mirror is available ----------------------------------

if ! command -v oc-mirror &>/dev/null && [[ ! -x ~/bin/oc-mirror ]]; then
    echo "ERROR: oc-mirror not found in PATH or ~/bin/" >&2
    echo "Install it first: aba --dir cli ~/bin/oc-mirror" >&2
    exit 1
fi
# Prefer ~/bin if not in PATH
[[ ! -x "$(command -v oc-mirror 2>/dev/null)" ]] && export PATH="$HOME/bin:$PATH"

echo "[1/5] oc-mirror found: $(command -v oc-mirror)"

# --- Step 2: Install Quay (idempotent) -------------------------------------

if curl --retry 3 -fSkIL -o /dev/null "https://${reg_host}:${REG_PORT}/health/instance" 2>/dev/null; then
    echo "[2/5] Quay already running on ${reg_host}:${REG_PORT} -- skipping install"
else
    echo "[2/5] Installing Quay on ${reg_host}:${REG_PORT} ..."

    if ! rpm -q podman &>/dev/null; then
        sudo dnf install -y podman
    fi

    cd "$POOL_REG_DIR"

    # Download mirror-registry tarball if not present
    if [[ ! -f mirror-registry-amd64.tar.gz ]]; then
        echo "  Downloading mirror-registry ..."
        curl -f --retry 3 --progress-bar -OL "${MR_URL}/mirror-registry-amd64.tar.gz"
    fi

    if [[ ! -x ./mirror-registry ]]; then
        tar xmzf mirror-registry-amd64.tar.gz
    fi

    # Open firewall port
    if rpm -q firewalld &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        sudo firewall-cmd --add-port=${REG_PORT}/tcp --permanent
        sudo firewall-cmd --reload
    fi

    ./mirror-registry install --quayHostname "$reg_host" --initPassword "$REG_PW"

    # Trust the CA
    reg_root="$HOME/quay-install"
    sudo cp "$reg_root/quay-rootCA/rootCA.pem" /etc/pki/ca-trust/source/anchors/pool-registry-rootCA.pem
    sudo update-ca-trust extract

    echo "  Quay installed successfully"
fi

# --- Step 3: Merge auth (pull-secret + local Quay creds) -------------------

echo "[3/5] Setting up container auth ..."

enc_password=$(echo -n "${REG_USER}:${REG_PW}" | base64 -w0)

# Build merged auth: Red Hat pull secret + local Quay
merged_auth=$(python3 -c "
import json, sys
rh = json.load(open('$HOME/.pull-secret.json'))
auths = rh.get('auths', rh)
if 'auths' not in rh:
    rh = {'auths': auths}
rh['auths']['${reg_host}:${REG_PORT}'] = {'auth': '${enc_password}'}
json.dump(rh, sys.stdout)
")

mkdir -p ~/.docker ~/.containers
echo "$merged_auth" > ~/.docker/config.json
cp ~/.docker/config.json ~/.containers/auth.json

podman login -u "$REG_USER" -p "$REG_PW" "https://${reg_host}:${REG_PORT}" --tls-verify=false 2>/dev/null || \
    podman login -u "$REG_USER" -p "$REG_PW" "https://${reg_host}:${REG_PORT}"

echo "  Auth configured for ${reg_host}:${REG_PORT} + registry.redhat.io"

# --- Step 4: Create imageset config ----------------------------------------

echo "[4/5] Creating imageset config ..."

SYNC_DIR="$POOL_REG_DIR/sync"
mkdir -p "$SYNC_DIR"

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

# --- Step 5: Run oc-mirror sync --------------------------------------------

# Skip if already synced for this version
DONE_MARKER="$SYNC_DIR/.synced-${version}"
if [[ -f "$DONE_MARKER" ]]; then
    echo "[5/5] Already synced for ${version} -- skipping"
else
    echo "[5/5] Syncing images to ${reg_host}:${REG_PORT} (this may take 30+ minutes) ..."

    cd "$SYNC_DIR"
    oc-mirror --v2 \
        --config imageset-config.yaml \
        --workspace file://. \
        "docker://${reg_host}:${REG_PORT}" \
        --image-timeout 15m \
        --parallel-images 4 \
        --retry-delay 30s \
        --retry-times 3

    touch "$DONE_MARKER"
    echo "  Sync complete"
fi

echo ""
echo "============================================================"
echo "  Pool registry ready: ${reg_host}:${REG_PORT}"
echo "  Working dir:  $SYNC_DIR/working-dir/"
echo "  Synced:       OCP ${version} + ${OP_REDHAT}, ${OP_CERTIFIED}, ${OP_COMMUNITY}"
echo "============================================================"
