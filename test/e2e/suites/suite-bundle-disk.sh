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

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"
VF="${VMWARE_CONF:-~/.vmware.conf}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: clean slate" \
    "Setup: install and configure aba" \
    "Bundle with operator filters: create" \
    "Bundle with operator filters: verify contents" \
    "Bundle without operator filters: create" \
    "Bundle without operator filters: verify contents" \
    "All-operators imageset: generate and verify YAML" \
    "run_once: mirror clean clears state"

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
# 3. Bundle WITH operator filters (downloads only specified operators)
# ============================================================================
test_begin "Bundle with operator filters: create"

e2e_run -q "Create temp dir" "mkdir -v -p ~/tmp"
e2e_run -q "Clean previous light bundles" "rm -fv ~/tmp/delete-me*tar"

e2e_run -r 3 3 "Create light bundle (channel=$TEST_CHANNEL version=$ocp_version ops=abatest+extras)" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel $TEST_CHANNEL --version $ocp_version --op-sets abatest --ops web-terminal yaks nginx-ingress-operator flux --base-domain $(pool_domain) -o ~/tmp/delete-me -y"

test_end 0

# ============================================================================
# 4. Bundle with operator filters: verify contents
# ============================================================================
test_begin "Bundle with operator filters: verify contents"

e2e_run "Show tar file size" "ls -l ~/tmp/delete-me*tar"
e2e_run "Show tar file size (human)" "ls -lh ~/tmp/delete-me*tar"
e2e_run "List tar contents" "tar tvf ~/tmp/delete-me*tar"
e2e_run -q "Clean up light bundle" "rm -fv ~/tmp/delete-me*tar"

test_end 0

# ============================================================================
# 5. Bundle WITHOUT operator filters (zero operators -- smallest bundle)
# ============================================================================
test_begin "Bundle without operator filters: create"

e2e_run -q "Clean previous bundles" "rm -fv /tmp/delete-me*tar"

# No --op-sets, no --ops: zero operators are downloaded (only OCP release images)
e2e_run -r 3 3 "Create bundle without operators (channel=$TEST_CHANNEL version=$ocp_version)" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel $TEST_CHANNEL --version $ocp_version --op-sets --ops --base-domain $(pool_domain) -o /tmp/delete-me -y"

test_end 0

# ============================================================================
# 6. Bundle without operator filters: verify contents
# ============================================================================
test_begin "Bundle without operator filters: verify contents"

e2e_run "Show tar file size" "ls -l /tmp/delete-me*tar"
e2e_run "Show tar file size (human)" "ls -lh /tmp/delete-me*tar"
e2e_run "List tar contents" "tar tvf /tmp/delete-me*tar"
e2e_run "Verify mirror_000001.tar in bundle" \
    "tar tvf /tmp/delete-me*tar | grep mirror/save/mirror_000001.tar"
e2e_run -q "Clean up full bundle" "rm -fv /tmp/delete-me*tar"

test_end 0

# ============================================================================
# 7. All-operators imageset: generate YAML and verify (no download -- too large)
# ============================================================================
test_begin "All-operators imageset: generate and verify YAML"

# Configure op-sets=all (downloads ALL operators if aba save were run, ~1TB!)
# We only generate the imageset-config YAML and verify its structure.
e2e_run -q "Set op-sets to 'all' in aba.conf" "aba --op-sets all"

# Remove any previously generated imageset YAML so it's regenerated
e2e_run -q "Clean old imageset YAML" "rm -f mirror/save/imageset-config-save.yaml"

# Generate the imageset config YAML (without actually saving images)
e2e_run "Generate imageset-config for ops=all" "aba -d mirror imagesetconf"

# Verify: the YAML must contain the redhat-operator-index catalog entry
e2e_run "Verify redhat-operator-index in imageset YAML" \
    "grep 'redhat-operator-index' mirror/save/imageset-config-save.yaml"

# Verify: with op-sets=all there should be NO 'packages:' filter
# (an unfiltered catalog entry = all operators)
e2e_run "Verify no package filter (all operators)" \
    "! grep -q 'packages:' mirror/save/imageset-config-save.yaml"

# Restore original operator settings so we leave things clean
e2e_run -q "Restore op-sets to abatest" "aba --op-sets abatest"

test_end 0

# ============================================================================
# 8. run_once regression: mirror clean must clear run_once state (Gap 8)
#    Verifies that 'aba --dir mirror clean' properly resets run_once state
#    so subsequent operations don't silently skip re-extraction or re-download.
# ============================================================================
test_begin "run_once: mirror clean clears state"

# Ensure mirror-registry binary exists (from bundle operations above)
e2e_run "Verify mirror-registry exists before clean" \
    "test -f mirror/mirror-registry || make -C mirror mirror-registry"

# Verify run_once state directory exists
e2e_run "Verify run_once state exists" \
    "ls -d ~/.aba/runner/mirror:* 2>/dev/null | head -3 || echo 'no run_once state yet'"

# Run mirror clean -- should delete extracted files AND clear run_once state
e2e_run "Run mirror clean" "aba --dir mirror clean"

# Verify the binary was removed
e2e_run "Verify mirror-registry removed after clean" \
    "test ! -f mirror/mirror-registry"

# Verify run_once state for mirror:reg:install was cleared
e2e_run "Verify run_once state cleared for reg:install" \
    "test ! -d ~/.aba/runner/mirror:reg:install"

# Re-extract -- should succeed because run_once state was cleared
e2e_run "Re-extract mirror-registry after clean" \
    "make -C mirror mirror-registry"
e2e_run "Verify mirror-registry re-extracted" \
    "test -x mirror/mirror-registry"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-bundle-disk.sh"
