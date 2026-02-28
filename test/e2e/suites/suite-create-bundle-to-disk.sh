#!/usr/bin/env bash
# =============================================================================
# Suite: Bundle to Disk (rewrite of test4-airgapped-bundle-to-disk.sh)
# =============================================================================
# Purpose: Create light and full install bundles and verify their contents.
#          No cluster install, no VMs needed -- the leanest E2E test.
#
# What it tests:
#   - Clean-slate aba install
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
STANDARD="$(pool_cluster_name standard)"

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
    "mirror clean: removes files and re-extraction works" \
    "Load bundle to internal bastion" \
    "Bare-metal simulation: platform=bm two-step install"

suite_begin "create-bundle-to-disk"

# ============================================================================
# 1. Clean slate
# ============================================================================
test_begin "Setup: clean slate"

# podman prune/rmi with --force are idempotent (return 0 even when empty).
e2e_run "Clean podman" \
    "podman system prune --all --force; podman rmi --all --force; sudo rm -rf ~/.local/share/containers/storage"

# Remove oc-mirror caches
e2e_run -q "Remove oc-mirror caches" \
    "rm -rf ~/.cache/agent; rm -rf \$HOME/*/.oc-mirror/.cache"

# Clean up leftover state from previous test runs
e2e_run -q "Remove old files" \
    "rm -rf $(pool_cluster_name sno) $(pool_cluster_name compact) $(pool_cluster_name standard) ~/.aba.previous.backup ~/.ssh/quay_installer* ~/.containers ~/.docker"

# Ensure make is available (needed for aba reset)
e2e_run -q "Ensure make is installed" \
    "which make || sudo dnf install make -y"

# Conditional: aba may not be installed yet (first run).
e2e_run "Reset aba (if installed)" \
    "if command -v aba >/dev/null 2>&1 && [ -d mirror ]; then aba reset -f; else echo 'aba not installed or no mirror dir -- skipping reset'; fi"

test_end 0

# ============================================================================
# 2. Install and configure
# ============================================================================
test_begin "Setup: install and configure aba"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

# Simulate manual edit: set dns_servers to pool dnsmasq host
e2e_run "Set dns_servers manually" \
    "sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

e2e_run -q "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run -q "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run -q "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run -q "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

# Copy vmware.conf and set the test VM folder
e2e_run "Copy vmware.conf" "cp -v $VF vmware.conf"
e2e_run -q "Set VC_FOLDER in vmware.conf" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run -q "Verify vmware.conf" "grep vm/aba-e2e vmware.conf"

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

e2e_run -r 3 2 "Create light bundle (channel=$TEST_CHANNEL version=$ocp_version ops=abatest+extras)" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --op-sets abatest --ops web-terminal yaks nginx-ingress-operator flux -o ~/tmp/delete-me -y"

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
e2e_run -r 3 2 "Create bundle without operators (channel=$TEST_CHANNEL version=$ocp_version)" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --op-sets --ops -o /tmp/delete-me -y"

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

# TODO: Replace with a proper verification for op-sets=all (backlog item)

# Restore original operator settings so we leave things clean
e2e_run -q "Restore op-sets to abatest" "aba --op-sets abatest"

test_end 0

# ============================================================================
# 8. mirror clean removes extracted files and re-extraction works (Gap 8)
#    Note: the bundle creation flow (make -C mirror save) calls
#    download-registries directly, so no mirror:* run_once state exists here.
#    This test verifies the clean/re-extract cycle.
# ============================================================================
test_begin "mirror clean: removes files and re-extraction works"

# Ensure mirror-registry binary exists (from bundle operations above)
e2e_run "Verify mirror-registry exists before clean" \
    "test -f mirror/mirror-registry || make -C mirror mirror-registry"

# Run mirror clean -- should delete extracted files
e2e_run "Run mirror clean" "aba --dir mirror clean"

# Verify the binary was removed
e2e_run "Verify mirror-registry removed after clean" \
    "test ! -f mirror/mirror-registry"

# Verify run_once state for mirror:reg:install does not exist
e2e_run "Verify no leftover run_once state for reg:install" \
    "test ! -d ~/.aba/runner/mirror:reg:install"

# Re-extract -- should succeed after clean
e2e_run "Re-extract mirror-registry after clean" \
    "make -C mirror mirror-registry"
e2e_run "Verify mirror-registry re-extracted" \
    "test -x mirror/mirror-registry"

test_end 0

# ============================================================================
# 9. Load the no-operator bundle to the internal bastion
#    This creates ~/aba on dis and installs the mirror registry there,
#    which is required by the BM two-step install test below.
# ============================================================================
test_begin "Load bundle to internal bastion"

e2e_run "Stream bundle to internal bastion" \
    "cat /tmp/delete-me*tar | ssh ${INTERNAL_BASTION} 'rm -rf ~/aba && tar xf - -C ~'"
e2e_run -q "Clean up local bundle tarball" "rm -fv /tmp/delete-me*tar"
e2e_run_remote "Verify ~/aba exists on internal bastion" "ls ~/aba/aba.conf"
e2e_run_remote "Install aba on internal bastion" "cd ~/aba && ./install"
e2e_run_remote "Install mirror registry from bundle" "cd ~/aba && aba mirror"

test_end 0

# ============================================================================
# 10. Bare-metal simulation: platform=bm two-step install (ported from old test1)
#
#    Tests the BM two-step install flow from the BUNDLE-LOAD perspective:
#      - govc download-all behavior with platform=bm (on connected bastion)
#      - Two-step bare-metal install (agent configs -> ISO) on internal bastion
#
#    WHY on internal bastion?  In the bundle-to-disk workflow, the registry
#    is installed on the disconnected side (dis) during bundle extraction.
#    The connected bastion (con) cannot resolve the registry hostname.
#    ISO creation needs registry access (verify-release-image.sh), so the
#    BM install must run where the registry lives.
#
#    The companion BM test in suite-mirror-sync.sh covers the same two-step
#    flow but from the SYNC perspective (registry reachable from con via sync).
#    Both tests are kept for defense-in-depth.
#
#    BM two-step flow (controlled by .bm-message / .bm-nextstep gate files):
#      1st `aba install` -> creates agent configs, prints "Check & edit"
#      2nd `aba install` -> creates ISO, prints "Boot your servers"
#      (3rd would monitor cluster -- not tested since no real BM servers)
# ============================================================================
test_begin "Bare-metal simulation: platform=bm two-step install"

# govc download-all test runs on connected bastion (CLI behavior check)
e2e_run "Switch to bare-metal platform" "aba --platform bm"

e2e_run "Remove govc tarball" "rm -f cli/govc*"
e2e_run "Verify govc tarball removed" "test ! -f cli/govc*gz"
e2e_run "Run download-all (govc should still be downloaded)" \
    "aba -d cli download-all"
e2e_run "Verify govc tarball exists after download-all" \
    "test -f cli/govc*gz"

# BM two-step install runs on internal bastion (registry is there, loaded from bundle)
e2e_run_remote "Switch to bare-metal platform on internal bastion" \
    "cd ~/aba && aba --platform bm"
e2e_run_remote "Clean standard cluster dir" \
    "cd ~/aba && rm -rf $STANDARD"
e2e_run_remote "Create agent configs (bare-metal)" \
    "cd ~/aba && aba cluster -n $STANDARD -t standard -i $(pool_standard_api_vip) -s agentconf"
e2e_run_remote "Verify cluster.conf" "ls ~/aba/$STANDARD/cluster.conf"
e2e_run_remote "Verify agent configs" \
    "ls ~/aba/$STANDARD/install-config.yaml ~/aba/$STANDARD/agent-config.yaml"
e2e_run_remote "Verify ISO not yet created" \
    "! ls ~/aba/$STANDARD/iso-agent-based/agent.*.iso"

# Phase 1: "aba install" stops after agent configs, shows MAC review instructions
e2e_run_remote "First aba install (creates configs, stops for MAC review)" \
    "cd ~/aba && aba --dir $STANDARD install 2>&1 | tee /tmp/bm-phase1.out && grep 'Check & edit' /tmp/bm-phase1.out"
e2e_run_remote "Verify .bm-message exists" "test -f ~/aba/$STANDARD/.bm-message"
e2e_run_remote "Verify ISO not yet created (still)" \
    "! ls ~/aba/$STANDARD/iso-agent-based/agent.*.iso"

# Phase 2: "aba install" creates ISO, shows boot instructions
e2e_run_remote "Second aba install (creates ISO, stops for server boot)" \
    "cd ~/aba && aba --dir $STANDARD install 2>&1 | tee /tmp/bm-phase2.out && grep 'Boot your servers' /tmp/bm-phase2.out"
e2e_run_remote "Verify .bm-nextstep exists" "test -f ~/aba/$STANDARD/.bm-nextstep"
e2e_run_remote "Verify ISO created" \
    "ls -l ~/aba/$STANDARD/iso-agent-based/agent.*.iso"

# Clean up and restore platform on both sides
e2e_run_remote -q "Clean up BM test dir on internal bastion" \
    "cd ~/aba && rm -rf $STANDARD && aba --platform vmw"
e2e_run -q "Restore VMware platform" "aba --platform vmw"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-create-bundle-to-disk.sh"
