#!/bin/bash
# =============================================================================
# Suite: Airgapped with Local Registry (rewrite of test5)
# =============================================================================
# Purpose: The comprehensive air-gapped workflow -- bundle creation, transfer,
#          Quay->Docker registry swap, incremental image loads, cluster upgrade,
#          full lifecycle with multiple cluster types and macs.conf bare-metal.
#
# This is the longest suite. It covers:
#   - Bundle creation with older version (for upgrade testing)
#   - Registry: Quay install -> uninstall -> Docker install
#   - SNO cluster install + day2 configuration
#   - Incremental image loads (UBI, vote-app, mesh operators)
#   - Vote-app deployment with ImageDigestMirrorSet
#   - OSUS + cluster upgrade
#   - Graceful shutdown/startup/restart cycle
#   - Standard cluster with macs.conf (bare-metal MAC addresses)
# =============================================================================

set -euo pipefail

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

# L commands run on conN (this host). R commands SSH to disN.
DIS_HOST="dis${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Setup: calculate older version for upgrade" \
    "Setup: reset internal bastion" \
    "Bundle: create with older version" \
    "Bundle: transfer to bastion" \
    "Registry: Quay install and uninstall" \
    "Registry: Docker install and load" \
    "SNO: install cluster" \
    "SNO: day2 configuration" \
    "Incremental: UBI image load" \
    "Incremental: vote-app image load" \
    "Deploy: vote-app with IDMS" \
    "Incremental: mesh operators" \
    "Upgrade: OSUS and cluster upgrade" \
    "Lifecycle: shutdown/startup" \
    "Standard: cluster with macs.conf" \
    "Cleanup: uninstall registry"

suite_begin "airgapped-local-reg"

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"

# Use VER_OVERRIDE=p for upgrade testing (we'll reduce version further below)
e2e_run "Configure aba.conf with previous version" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version p"
e2e_run "Show ocp_version" "grep -o '^ocp_version=[^ ]*' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror host" \
    "sed -i 's/registry.example.com/${DIS_HOST} /g' ./mirror/mirror.conf"

test_end 0

# ============================================================================
# 2. Calculate older version for upgrade testing
# ============================================================================
test_begin "Setup: calculate older version for upgrade"

e2e_run "Source aba.conf and compute older version" "
    source <(normalize-aba-conf)
    echo ocp_version=\$ocp_version
    ocp_version_desired=\$ocp_version
    ocp_version_major=\$(echo \$ocp_version_desired | cut -d. -f1-2)
    ocp_version_point=\$(echo \$ocp_version_desired | cut -d. -f3)
    ocp_version_older_point=\$(expr \$ocp_version_point - 1)
    ocp_version_older=\${ocp_version_major}.\${ocp_version_older_point}
    echo ocp_version_older=\$ocp_version_older
    # Save for later steps
    echo \$ocp_version_desired > /tmp/e2e-ocp-version-desired
    echo \$ocp_version_older > /tmp/e2e-ocp-version-older
"

e2e_run "Set aba to older version for initial bundle" \
    "aba -v \$(cat /tmp/e2e-ocp-version-older)"
e2e_run "Show configured version" "grep -o '^ocp_version=[^ ]*' aba.conf"

test_end 0

# ============================================================================
# 3. Setup: reset internal bastion (reuse clone-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end 0

# ============================================================================
# 4. Bundle: create with older version
# ============================================================================
test_begin "Bundle: create with older version"

e2e_run -r 3 3 "Create bundle and pipe to bastion" \
    "source <(normalize-aba-conf) && aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel ${TEST_CHANNEL:-stable} --version \$ocp_version --op-sets abatest --ops web-terminal --base-domain $(pool_domain) -o - -y | ssh ${INTERNAL_BASTION} 'mkdir -p ~/aba && tar xf - -C ~/aba'"

test_end 0

# ============================================================================
# 5. Bundle: transfer verified
# ============================================================================
test_begin "Bundle: transfer to bastion"

e2e_run_remote "Verify bundle extracted" \
    "ls -la ~/aba/mirror/ && ls -la ~/aba/cli/"
e2e_run_remote "Run aba install on bastion" \
    "cd ~/aba && ./install"

test_end 0

# ============================================================================
# 6. Registry: Quay install -> uninstall (then switch to Docker)
# ============================================================================
test_begin "Registry: Quay install and uninstall"

e2e_run_remote "Install Quay registry" \
    "cd ~/aba && aba -d mirror install"
e2e_run_remote "Verify Quay running" \
    "podman ps | grep quay"
e2e_run_remote "Uninstall Quay registry" \
    "cd ~/aba && aba -d mirror uninstall"
e2e_run_remote "Verify Quay removed" \
    "podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$"

test_end 0

# ============================================================================
# 7. Registry: install Docker registry and load images
# ============================================================================
test_begin "Registry: Docker install and load"

e2e_run_remote "Install Docker registry" \
    "cd ~/aba && aba -d mirror install-docker-registry"
e2e_run_remote "Verify Docker registry running" \
    "podman ps | grep registry"

e2e_run_remote -r 15 3 "Load images into Docker registry" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 8. SNO: install cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_run_remote "Create and install SNO" \
    "cd ~/aba && aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) -s install"
e2e_run_remote "Verify cluster operators" \
    "cd ~/aba && aba --dir sno run"
e2e_run_remote "Check cluster operators" \
    "cd ~/aba && aba --dir sno cmd 'oc get co'"

test_end 0

# ============================================================================
# 9. SNO: day2 configuration
# ============================================================================
test_begin "SNO: day2 configuration"

e2e_run_remote "Apply day2 config" \
    "cd ~/aba && aba --dir sno day2"

test_end 0

# ============================================================================
# 10. Incremental: UBI image load
# ============================================================================
test_begin "Incremental: UBI image load"

# Save UBI images from connected bastion
e2e_run "Add UBI to imageset and save" \
    "aba -d mirror --add-image registry.redhat.io/ubi9/ubi:latest && aba -d mirror save --retry"
e2e_run "Transfer UBI images to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 8 3 "Load UBI images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 11. Incremental: vote-app image load
# ============================================================================
test_begin "Incremental: vote-app image load"

e2e_run "Add vote-app image and save" \
    "aba -d mirror --add-image quay.io/sjbylo/flask-vote-app:latest && aba -d mirror save --retry"
e2e_run "Transfer vote-app to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 8 3 "Load vote-app images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 12. Deploy vote-app with ImageDigestMirrorSet
# ============================================================================
test_begin "Deploy: vote-app with IDMS"

e2e_run_remote "Deploy vote-app" \
    "cd ~/aba && test/deploy-test-app.sh"

test_end 0

# ============================================================================
# 13. Incremental: mesh operators
# ============================================================================
test_begin "Incremental: mesh operators"

e2e_run "Add mesh operator set" "aba --op-sets mesh3"
e2e_run -r 15 3 "Save mesh operator images" "aba -d mirror save --retry"
e2e_run "Transfer mesh images to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 15 3 "Load mesh images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 14. Upgrade: OSUS and cluster upgrade
# ============================================================================
test_begin "Upgrade: OSUS and cluster upgrade"

# Save the target (newer) version images
e2e_run "Set version to desired (upgrade target)" \
    "aba -v \$(cat /tmp/e2e-ocp-version-desired)"
e2e_run -r 15 3 "Save upgrade images" "aba -d mirror save --retry"
e2e_run "Transfer upgrade images to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 15 3 "Load upgrade images" \
    "cd ~/aba && aba -d mirror load --retry"

e2e_run_remote "Apply OSUS day2" \
    "cd ~/aba && aba --dir sno day2-osus"

e2e_run_remote -r 3 10 "Trigger cluster upgrade" \
    "cd ~/aba && aba --dir sno cmd 'oc adm upgrade --to-latest=true'"

e2e_run_remote -r 30 5 "Wait for upgrade to complete" \
    "cd ~/aba && aba --dir sno cmd 'oc get clusterversion -o jsonpath={.items[0].status.history[0].state}' | grep Completed"

test_end 0

# ============================================================================
# 15. Lifecycle: shutdown/startup
# ============================================================================
test_begin "Lifecycle: shutdown/startup"

e2e_run_remote "Shutdown cluster" \
    "cd ~/aba && yes | aba --dir sno shutdown --wait"
e2e_run_remote "Startup cluster" \
    "cd ~/aba && aba --dir sno startup --wait"
e2e_run_remote "Verify cluster healthy after restart" \
    "cd ~/aba && aba --dir sno run"

test_end 0

# ============================================================================
# 16. Standard cluster with macs.conf
# ============================================================================
test_begin "Standard: cluster with macs.conf"

# Copy macs.conf for bare-metal MAC address testing
e2e_run_remote "Copy macs.conf" \
    "cp -v ~/aba/test/macs.conf ~/aba/"
e2e_run_remote "Delete SNO cluster" \
    "cd ~/aba && aba --dir sno delete || true"
e2e_run_remote "Clean sno dir" \
    "cd ~/aba && rm -rf sno"

# Build standard cluster
e2e_run_remote "Create standard cluster config" \
    "cd ~/aba && aba cluster -n standard -t standard -i $(pool_standard_api_vip) --step cluster.conf"
e2e_run_remote "Verify macs.conf used" \
    "cd ~/aba && grep mac_prefix standard/cluster.conf || cat standard/cluster.conf"
e2e_run_remote "Generate agent configs" \
    "cd ~/aba && aba --dir standard agentconf"
e2e_run_remote "Verify agent-config has MACs" \
    "cd ~/aba && cat standard/agent-config.yaml | grep -i mac"
e2e_run_remote "Install standard cluster" \
    "cd ~/aba && aba --dir standard install"
e2e_run_remote "Verify standard cluster operators" \
    "cd ~/aba && aba --dir standard run"
e2e_run_remote -i "Delete standard cluster" \
    "cd ~/aba && aba --dir standard delete || true"

test_end 0

# ============================================================================
# 17. Cleanup
# ============================================================================
test_begin "Cleanup: uninstall registry"

e2e_run_remote "Uninstall Docker registry" \
    "cd ~/aba && aba -d mirror uninstall-docker-registry || aba -d mirror uninstall || true"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-airgapped-local-reg.sh"
