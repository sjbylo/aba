#!/bin/bash
# =============================================================================
# Suite: Bundle to Disk (rewrite of test4-airgapped-bundle-to-disk.sh)
# =============================================================================
# Purpose: Create light and full install bundles and verify their contents.
#          No cluster install, no VMs needed -- the leanest E2E test.
#
# What it tests:
#   - Clean-slate aba install (RPMs removed so aba must auto-install them)
#   - aba CLI configuration (aba.conf, vmware.conf, NTP, operator-sets)
#   - Light bundle creation (specific operator subset)
#   - Full bundle creation (all operators)
#   - Bundle tar verification (contents, mirror_000001.tar presence)
#
# Prerequisites:
#   - ~/.pull-secret.json must exist
#   - ~/.vmware.conf must exist (or VMWARE_CONF points to it)
#   - Internet access (to download OCP images for the bundle)
# =============================================================================

set -euo pipefail

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"
VF="${VMWARE_CONF:-~/.vmware.conf}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: clean slate" \
    "Setup: install and configure aba" \
    "Light bundle: create with operators" \
    "Light bundle: verify contents" \
    "Full bundle: create without operator filters" \
    "Full bundle: verify contents"

suite_begin "bundle-disk"

# ============================================================================
# 1. Clean slate
# ============================================================================
test_begin "Setup: clean slate"

# Remove RPMs so aba can test its auto-install logic (matches original test4 RPM list)
e2e_run "Remove RPMs for clean install test" \
    "sudo dnf remove git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer -y 2>/dev/null || true"

# Clean podman images and storage
e2e_run -q "Clean podman" \
    "podman system prune --all --force 2>/dev/null; podman rmi --all 2>/dev/null; sudo rm -rf ~/.local/share/containers/storage; true"

# Remove oc-mirror caches
e2e_run -q "Remove oc-mirror caches" \
    "rm -rf ~/.cache/agent; rm -rf \$HOME/*/.oc-mirror/.cache; true"

# Clean up leftover state from previous test runs
e2e_run -q "Remove old files" \
    "rm -rf sno compact standard ~/.aba.previous.backup ~/.ssh/quay_installer* ~/.containers ~/.docker || true"

# Ensure make is available (needed for aba reset)
e2e_run -q "Ensure make is installed" \
    "which make || sudo dnf install make -y"

# Reset aba if it was previously installed (-i: ignore failure if not installed)
e2e_run -i "Reset aba (if installed)" \
    "aba reset -f 2>/dev/null || true"

test_end 0

# ============================================================================
# 2. Install and configure
# ============================================================================
test_begin "Setup: install and configure aba"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-p}"

e2e_run -q "Show ocp_version" "grep -o '^ocp_version=[^ ]*' aba.conf"

# Copy vmware.conf and set the test VM folder
e2e_run "Copy vmware.conf" "cp -v $VF vmware.conf"
e2e_run -q "Set VC_FOLDER in vmware.conf" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"
e2e_run -q "Verify vmware.conf" "grep vm/abatesting vmware.conf"

# Suppress interactive prompts during testing
e2e_run -q "Set ask=false" "aba --noask"

# Configure NTP
e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"

# Set up operator-sets (kiali-ossm operator set for testing)
echo kiali-ossm > templates/operator-set-abatest
e2e_run "Set operator sets in aba.conf" "aba --op-sets abatest"

# Create mirror directory and mirror.conf (needed by the bundle command)
e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"

# Resolve the actual ocp_version from aba.conf.
# IMPORTANT: must run in current shell (not through e2e_run) so $ocp_version
# is available for the rest of the suite.
source <(normalize-aba-conf)
_e2e_log "Resolved: ocp_version=$ocp_version ocp_channel=$ocp_channel"
echo "  ocp_version=$ocp_version  ocp_channel=$ocp_channel"

test_end 0

# ============================================================================
# 3. Light bundle: create with specific operators
# ============================================================================
test_begin "Light bundle: create with operators"

e2e_run -q "Create temp dir" "mkdir -v -p ~/tmp"
e2e_run -q "Clean previous light bundles" "rm -fv ~/tmp/delete-me*tar"

e2e_run -r 3 3 "Create light bundle (channel=$TEST_CHANNEL version=$ocp_version ops=abatest+extras)" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel $TEST_CHANNEL --version $ocp_version --op-sets abatest --ops web-terminal yaks nginx-ingress-operator flux --base-domain $(pool_domain) -o ~/tmp/delete-me -y"

test_end 0

# ============================================================================
# 4. Light bundle: verify contents
# ============================================================================
test_begin "Light bundle: verify contents"

e2e_run "Show tar file size" "ls -l ~/tmp/delete-me*tar"
e2e_run "Show tar file size (human)" "ls -lh ~/tmp/delete-me*tar"
e2e_run "List tar contents" "tar tvf ~/tmp/delete-me*tar"
e2e_run -q "Clean up light bundle" "rm -fv ~/tmp/delete-me*tar"

test_end 0

# ============================================================================
# 5. Full bundle: create without operator filters
# ============================================================================
test_begin "Full bundle: create without operator filters"

e2e_run -q "Clean previous full bundles" "rm -fv /tmp/delete-me*tar"

e2e_run -r 3 3 "Create full bundle (channel=$TEST_CHANNEL version=$ocp_version all operators)" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel $TEST_CHANNEL --version $ocp_version --op-sets --ops --base-domain $(pool_domain) -o /tmp/delete-me -y"

test_end 0

# ============================================================================
# 6. Full bundle: verify contents
# ============================================================================
test_begin "Full bundle: verify contents"

e2e_run "Show tar file size" "ls -l /tmp/delete-me*tar"
e2e_run "Show tar file size (human)" "ls -lh /tmp/delete-me*tar"
e2e_run "List tar contents" "tar tvf /tmp/delete-me*tar"
e2e_run "Verify mirror_000001.tar in bundle" \
    "tar tvf /tmp/delete-me*tar | grep mirror/save/mirror_000001.tar"
e2e_run -q "Clean up full bundle" "rm -fv /tmp/delete-me*tar"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-bundle-disk.sh"
