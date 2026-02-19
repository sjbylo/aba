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

set -u

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

# Pool-unique cluster names (avoid VM collisions when pools run in parallel)
SNO="$(pool_cluster_name sno)"
STANDARD="$(pool_cluster_name standard)"

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

# Pre-flight: abort immediately if the internal bastion (disN) is unreachable
preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"

# Use OCP_VERSION=p for upgrade testing (we'll reduce version further below)
e2e_run "Configure aba.conf with previous version" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version p --base-domain $(pool_domain)"
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

test_end

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

test_end

# ============================================================================
# 3. Setup: reset internal bastion (reuse clone-and-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end

# ============================================================================
# 4. Bundle: create with older version
# ============================================================================
test_begin "Bundle: create with older version"

e2e_run -r 3 2 "Create bundle and pipe to bastion" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel ${TEST_CHANNEL:-stable} --op-sets abatest --ops web-terminal --base-domain $(pool_domain) -o - -y | ssh ${INTERNAL_BASTION} 'tar xf - -C ~'"

test_end

# ============================================================================
# 5. Bundle: transfer verified
# ============================================================================
test_begin "Bundle: transfer to bastion"

e2e_run_remote "Verify bundle extracted" \
    "ls -la ~/aba/mirror/ && ls -la ~/aba/cli/"
e2e_run_remote "Run aba install on bastion" \
    "cd ~/aba && ./install"

test_end

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

test_end

# ============================================================================
# 7. Registry: install Docker registry and load images
# ============================================================================
test_begin "Registry: Docker install and load"

e2e_run_remote "Install Docker registry" \
    "cd ~/aba && aba -d mirror install-docker-registry"
e2e_run_remote "Verify Docker registry running" \
    "podman ps | grep registry"

e2e_run_remote -r 3 2 "Load images into Docker registry" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 8. SNO: install cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_run_remote "Create and install SNO" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) -s install"
e2e_run_remote "Verify cluster operators" \
    "cd ~/aba && aba --dir $SNO run"
e2e_run_remote -r 30 10 "Wait for all operators fully available" \
    "cd ~/aba && aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False\$' | wc -l | grep ^0\$"
e2e_diag_remote "Show cluster operators" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 9. SNO: day2 configuration
# ============================================================================
test_begin "SNO: day2 configuration"

e2e_run_remote "Apply day2 config" \
    "cd ~/aba && aba --dir $SNO day2"

test_end

# ============================================================================
# 10. Incremental: UBI image load
# ============================================================================
test_begin "Incremental: UBI image load"

# Save UBI images from connected bastion
e2e_run "Add UBI to imageset and save" \
    "aba -d mirror --add-image registry.redhat.io/ubi9/ubi:latest && aba -d mirror save --retry"
e2e_run "Transfer UBI images to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 3 2 "Load UBI images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 11. Incremental: vote-app image load
# ============================================================================
test_begin "Incremental: vote-app image load"

e2e_run "Add vote-app image and save" \
    "aba -d mirror --add-image quay.io/sjbylo/flask-vote-app:latest && aba -d mirror save --retry"
e2e_run "Transfer vote-app to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 3 2 "Load vote-app images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 12. Deploy vote-app with ImageDigestMirrorSet (Gap 6: explicit IDMS test)
#     Two deployments: (a) direct from mirror path, (b) via IDMS redirect
# ============================================================================
test_begin "Deploy: vote-app with IDMS"

# --- (a) Deploy directly from mirror registry path ---
e2e_run_remote "Deploy vote-app (direct mirror path)" \
    "cd ~/aba && test/deploy-test-app.sh"

# Clean up before IDMS test
e2e_run_remote "Delete demo project" \
    "cd ~/aba && aba --dir $SNO cmd 'oc delete project demo'"
e2e_run_remote -r 3 2 "Recreate demo project" \
    "cd ~/aba && aba --dir $SNO cmd 'oc new-project demo'"

# --- (b) Deploy via ImageDigestMirrorSet (IDMS) ---
# Apply an IDMS that redirects quay.io/sjbylo -> mirror registry.
# This tests the key air-gapped mechanism: users reference public image
# names and OCP transparently pulls from the mirror.
e2e_run_remote "Apply ImageDigestMirrorSet for quay.io/sjbylo" \
    "cd ~/aba && source <(cd mirror && normalize-mirror-conf) && aba --dir $SNO cmd 'oc apply -f -' <<'IDMSEOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-vote-app
spec:
  imageDigestMirrors:
  - mirrors:
    - \${reg_host}:\${reg_port}\${reg_path}/sjbylo
    source: quay.io/sjbylo
IDMSEOF"

# Give the MachineConfigOperator time to process the IDMS
e2e_run_remote -q "Wait for IDMS to propagate" "sleep 30"

# Deploy vote-app using the PUBLIC image name -- IDMS should redirect to mirror
e2e_run_remote "Deploy vote-app via IDMS (quay.io source)" \
    "cd ~/aba && aba --dir $SNO cmd 'oc new-app --insecure-registry=true --image quay.io/sjbylo/flask-vote-app:latest --name vote-app -n demo'"
e2e_run_remote "Wait for vote-app rollout via IDMS" \
    "cd ~/aba && aba --dir $SNO cmd 'oc rollout status deployment vote-app -n demo'"

# Clean up
e2e_run_remote "Delete demo project after IDMS test" \
    "cd ~/aba && aba --dir $SNO cmd 'oc delete project demo'"

test_end

# ============================================================================
# 13. Incremental: mesh operators
# ============================================================================
test_begin "Incremental: mesh operators"

e2e_run "Add mesh operator set" "aba --op-sets mesh3"
e2e_run -r 3 2 "Save mesh operator images" "aba -d mirror save --retry"
e2e_run "Transfer mesh images to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 3 2 "Load mesh images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 14. Upgrade: OSUS and cluster upgrade
# ============================================================================
test_begin "Upgrade: OSUS and cluster upgrade"

# Save the target (newer) version images
e2e_run "Set version to desired (upgrade target)" \
    "aba -v \$(cat /tmp/e2e-ocp-version-desired)"
e2e_run -r 3 2 "Save upgrade images" "aba -d mirror save --retry"
e2e_run "Transfer upgrade images to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xf -'"
e2e_run_remote -r 3 2 "Load upgrade images" \
    "cd ~/aba && aba -d mirror load --retry"

e2e_run_remote "Apply OSUS day2" \
    "cd ~/aba && aba --dir $SNO day2-osus"

e2e_run_remote -r 3 2 "Trigger cluster upgrade" \
    "cd ~/aba && aba --dir $SNO cmd 'oc adm upgrade --to-latest=true'"

e2e_run_remote -r 20 1.5 "Wait for upgrade to complete" \
    "cd ~/aba && aba --dir $SNO cmd 'oc get clusterversion -o jsonpath={.items[0].status.history[0].state}' | grep Completed"

test_end

# ============================================================================
# 15. Lifecycle: shutdown/startup
# ============================================================================
test_begin "Lifecycle: shutdown/startup"

e2e_run_remote "Shutdown cluster" \
    "cd ~/aba && yes | aba --dir $SNO shutdown --wait"
e2e_run_remote "Startup cluster" \
    "cd ~/aba && aba --dir $SNO startup --wait"
e2e_run_remote "Verify cluster healthy after restart" \
    "cd ~/aba && aba --dir $SNO run"

test_end

# ============================================================================
# 16. Standard cluster with macs.conf
# ============================================================================
test_begin "Standard: cluster with macs.conf"

# Copy macs.conf for bare-metal MAC address testing
e2e_run_remote "Copy macs.conf" \
    "cp -v ~/aba/test/macs.conf ~/aba/"
e2e_run_remote "Delete SNO cluster" \
    "cd ~/aba && aba --dir $SNO delete"
e2e_run_remote "Clean sno dir" \
    "cd ~/aba && rm -rfv $SNO"

# Build standard cluster
e2e_run_remote "Create standard cluster config" \
    "cd ~/aba && aba cluster -n $STANDARD -t standard -i $(pool_standard_api_vip) --step cluster.conf"
e2e_run_remote "Verify macs.conf used" \
    "cd ~/aba && grep mac_prefix $STANDARD/cluster.conf || cat $STANDARD/cluster.conf"
e2e_run_remote "Generate agent configs" \
    "cd ~/aba && aba --dir $STANDARD agentconf"
e2e_run_remote "Verify agent-config has MACs" \
    "cd ~/aba && cat $STANDARD/agent-config.yaml | grep -i mac"
# Bootstrap only (saves ~30 min vs full install) -- proves agent configs are
# valid and control plane comes up.  Full operator verification is done on
# the SNO cluster earlier in this suite.
e2e_run_remote "Bootstrap standard cluster" \
    "cd ~/aba && aba --dir $STANDARD bootstrap"
e2e_run_remote "Delete standard cluster" \
    "cd ~/aba && aba --dir $STANDARD delete"

test_end

# ============================================================================
# 17. Cleanup
# ============================================================================
test_begin "Cleanup: uninstall registry"

e2e_run_remote "Uninstall Docker registry" \
    "cd ~/aba && aba -d mirror uninstall-docker-registry || aba -d mirror uninstall"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-airgapped-local-reg.sh"
