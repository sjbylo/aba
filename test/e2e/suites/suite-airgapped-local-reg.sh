#!/usr/bin/env bash
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
#   - Vote-app deployment with IDMS redirect
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
DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
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
    "Cleanup: uninstall registry on disN"

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
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version p --base-domain $(pool_domain)"

# Simulate manual edit: set dns_servers to pool dnsmasq host
e2e_run "Set dns_servers manually" \
    "sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror hostname in mirror.conf" \
    "sed -i 's/registry.$(pool_domain)/${DIS_HOST} /g' ./mirror/mirror.conf"

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
e2e_run "Verify aba.conf: version matches older" "grep ^ocp_version=\$(cat /tmp/e2e-ocp-version-older) aba.conf"

test_end

# ============================================================================
# 3. Bundle: create with older version
# ============================================================================
test_begin "Bundle: create with older version"

e2e_run -r 3 2 "Create bundle and pipe to internal bastion" \
    "aba -f bundle --pull-secret '~/.pull-secret.json' --op-sets abatest --ops web-terminal -o - -y | ssh ${INTERNAL_BASTION} 'tar xf - -C ~'"

test_end

# ============================================================================
# 5. Bundle: transfer verified
# ============================================================================
test_begin "Bundle: transfer to bastion"

e2e_run_remote "Verify bundle extracted" \
    "ls -la ~/aba/mirror/ && ls -la ~/aba/cli/"
e2e_run_remote "Remove dialog RPM to force dnf install path" \
    "sudo dnf remove -y dialog"
e2e_run_remote "Remove stale dnf log" \
    "cd ~/aba && rm -f .dnf-install.log"
e2e_run_remote "Run aba install on internal bastion" \
    "cd ~/aba && ./install"
e2e_run_remote "Verify dialog was reinstalled" \
    "rpm -q dialog"
e2e_run_remote "Verify single dnf batch (no duplicate install)" \
    "cd ~/aba && test \$(grep -c 'Transaction Summary' .dnf-install.log) -eq 1"

test_end

# ============================================================================
# 6. Registry: Quay install -> uninstall (then switch to Docker)
# ============================================================================
test_begin "Registry: Quay install and uninstall"

e2e_run_remote "Install Quay registry" \
    "cd ~/aba && aba -d mirror install"
e2e_poll_remote 60 5 "Wait for Quay container" \
    "podman ps | grep quay"
e2e_run_remote "Verify Quay running" \
    "podman ps | grep quay"
e2e_run_remote "Uninstall Quay registry" \
    "cd ~/aba && aba -d mirror uninstall"
e2e_run_remote "Verify Quay removed" \
    "podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$"

# Negative path: load without data/ dir should fail
e2e_run_remote -q "Remove data dir for must-fail test" \
    "cd ~/aba && mv mirror/data mirror/data.bak"
e2e_run_must_fail_remote "Load without data dir should fail" \
    "cd ~/aba && aba -d mirror load"
e2e_run_remote -q "Restore data dir" \
    "cd ~/aba && mv mirror/data.bak mirror/data"

test_end

# ============================================================================
# 7. Registry: install Docker registry and load images
# ============================================================================
test_begin "Registry: Docker install and load"

e2e_add_to_mirror_cleanup "$PWD/mirror" remote
e2e_run_remote "Install Docker registry" \
    "cd ~/aba && aba -d mirror install --vendor docker"
e2e_poll_remote 60 5 "Wait for Docker registry container" \
    "podman ps | grep registry"
e2e_run_remote "Verify Docker registry running" \
    "podman ps | grep registry"
e2e_run_remote "Verify Docker registry accessible" \
    "cd ~/aba && aba -d mirror verify"

e2e_run_remote -r 3 2 "Load images into Docker registry" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

test_end

# ============================================================================
# 8. SNO: install cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_add_to_cluster_cleanup "$PWD/$SNO" remote
# Mesh operators + upgrade need more resources than default (old test uses 24 CPU / 24GB)
e2e_run_remote "Generate SNO cluster.conf" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"
e2e_run_remote "Increase SNO resources for mesh/upgrade" \
    "cd ~/aba && sed -i 's/^master_cpu_count=.*/master_cpu_count=24/' $SNO/cluster.conf && \
     sed -i 's/^master_mem=.*/master_mem=24/' $SNO/cluster.conf"
e2e_run_remote -r 2 10 "Install SNO cluster" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) -s install"
e2e_run_remote "Show cluster operator status" \
    "cd ~/aba && aba --dir $SNO run"
e2e_poll_remote 600 30 "Wait for all operators fully available" \
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

# oc-mirror v2 requires a fresh imageset config with ONLY the incremental
# images -- if the platform/release section is still present, oc-mirror tries
# to re-resolve release images from the cache and fails with
# "no release images found".  The old E2E tests create a fresh file here.
e2e_run "Backup existing imageset config" \
    "cp -v mirror/data/imageset-config.yaml mirror/data/bk.imageset-config.yaml.\$(date +%Y%m%d%H%M%S)"
e2e_run "Create fresh imageset config for UBI only" \
    "tee mirror/data/imageset-config.yaml <<'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
EOF"
e2e_run -r 3 2 "Save UBI image to disk" \
    "aba -d mirror save --retry"
e2e_run "Transfer UBI archive+config to internal bastion" \
    "scp mirror/data/mirror_*.tar mirror/data/imageset-config.yaml ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_run_remote -r 3 2 "Load UBI images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

# Verify UBI image exists in mirror (fail fast instead of waiting for deploy timeout)
e2e_run_remote "Verify UBI image in mirror (skopeo)" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && skopeo inspect --tls-verify=false docker://\$reg_host:\$reg_port\$reg_path/ubi9/ubi:latest"

e2e_run_remote "Apply day2 config (UBI mirror resources)" \
    "cd ~/aba && aba --dir $SNO day2"

test_end

# ============================================================================
# 11. Incremental: vote-app image load
# ============================================================================
test_begin "Incremental: vote-app image load"

# Fresh config with only vote-app -- same rationale as UBI load above
e2e_run "Create fresh imageset config for vote-app only" \
    "tee mirror/data/imageset-config.yaml <<'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: quay.io/sjbylo/flask-vote-app:latest
EOF"
e2e_run -r 3 2 "Save vote-app image to disk" \
    "aba -d mirror save --retry"
e2e_run "Transfer vote-app archive+config to internal bastion" \
    "scp mirror/data/mirror_*.tar mirror/data/imageset-config.yaml ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_run_remote -r 3 2 "Load vote-app images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

# Verify vote-app image exists in mirror (fail fast instead of waiting for deploy timeout)
e2e_run_remote "Verify vote-app image in mirror (skopeo)" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && skopeo inspect --tls-verify=false docker://\$reg_host:\$reg_port\$reg_path/sjbylo/flask-vote-app:latest"

# Apply oc-mirror generated cluster resources (IDMS/ITMS for vote-app)
# Without this, the cluster has no mirror config for quay.io/sjbylo.
e2e_run_remote "Apply day2 config (vote-app mirror resources)" \
    "cd ~/aba && aba --dir $SNO day2"

test_end

# ============================================================================
# 12. Deploy vote-app with ImageDigestMirrorSet (IDMS redirect test)
#     Two deployments: (a) direct from mirror path, (b) via IDMS redirect
# ============================================================================
test_begin "Deploy: vote-app with IDMS"

# --- (a) Deploy directly from mirror registry path ---
e2e_run_remote "Create demo project" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc new-project demo' || true"
e2e_run_remote -r 3 2 "Launch vote-app from mirror (direct path)" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && aba --dir $SNO run --cmd \"oc new-app --insecure-registry=true --image \$reg_host:\$reg_port\$reg_path/sjbylo/flask-vote-app --name vote-app -n demo\""
e2e_poll_remote 480 30 "Wait for vote-app rollout" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc rollout status deployment vote-app -n demo'"

# Clean up before IDMS test
e2e_run_remote "Delete demo project" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc delete project demo'"
e2e_run_remote -r 3 2 "Recreate demo project" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc new-project demo'"

# --- (b) Deploy via ImageDigestMirrorSet (IDMS) ---
# Apply an IDMS that redirects quay.io/sjbylo -> mirror registry.
# The day2 step above already applied the oc-mirror generated ITMS,
# but we also apply a manual IDMS to explicitly test the mechanism:
# users reference public image names and OCP transparently pulls from mirror.
e2e_run_remote "Apply ImageDigestMirrorSet for quay.io/sjbylo" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && aba --dir $SNO run --cmd 'oc apply -f -' <<IDMSEOF
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

# Give the MachineConfigOperator time to process
e2e_run_remote -q "Wait for IDMS to propagate" "sleep 30"

# Deploy vote-app using the PUBLIC image name -- IDMS should redirect to mirror
e2e_run_remote "Deploy vote-app via IDMS (quay.io source)" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc new-app --insecure-registry=true --image quay.io/sjbylo/flask-vote-app:latest --name vote-app -n demo'"
e2e_poll_remote 480 30 "Wait for vote-app rollout via IDMS" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc rollout status deployment vote-app -n demo'"

# Clean up
e2e_run_remote "Delete demo project after IDMS test" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc delete project demo'"

test_end

# ============================================================================
# 13. Incremental: mesh operators
# ============================================================================
test_begin "Incremental: mesh operators"

e2e_run "Add mesh operator set" "aba --op-sets mesh3"

# Simulate user waiting for background catalog downloads to complete.
# In normal use, 'aba save' / 'aba sync' run catalogs-wait automatically via
# Makefile dependencies (imageset-config.yaml depends on catalogs-download
# catalogs-wait).  Here we call it explicitly because this test manually reads
# values from the generated catalog YAML to build a custom imageset config --
# the same thing a user would do by consulting the catalog reference file.
OCP_VER_MAJOR=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}' | cut -d. -f1-2)
e2e_run "Wait for catalog downloads" "make -sC mirror catalogs-wait"
e2e_run "Verify catalog YAML exists" \
    "test -s mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml"
e2e_run "Verify servicemeshoperator3 in catalog" \
    "grep -A2 'name: servicemeshoperator3\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml"

# For incremental operator saves, create a minimal imageset config with ONLY the
# operators section (no platform).  oc-mirror v2 errors with "no release images
# found" when the config includes a platform section but the delta tar doesn't
# contain release images.  No aba/make target generates this minimal format,
# so the file is created directly here.
e2e_run "Create operators-only imageset config for mesh" \
    "cat > mirror/data/imageset-config.yaml <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_VER_MAJOR}
    packages:
\$(grep -A2 'name: servicemeshoperator3\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml)
EOF"

e2e_run -r 3 2 "Save mesh operator images" "aba -d mirror save --retry"
e2e_run "Transfer mesh archive+config to internal bastion" \
    "scp mirror/data/mirror_*.tar mirror/data/imageset-config.yaml ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_run_remote -r 3 2 "Load mesh images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

e2e_run_remote "Apply day2 config (mesh operator resources)" \
    "cd ~/aba && aba --dir $SNO day2"

test_end

# ============================================================================
# 14. Upgrade: OSUS and cluster upgrade
# ============================================================================
test_begin "Upgrade: OSUS and cluster upgrade"

# Save the target (newer) version images.
# Must match the old test approach: minVersion=older, maxVersion=desired,
# channel=fast (for upgrade graph), shortestPath enabled.
e2e_run "Set version to desired (upgrade target)" \
    "aba -v \$(cat /tmp/e2e-ocp-version-desired)"

# Regenerate imageset config (incremental tests overwrote it with minimal config)
e2e_run "Regenerate full imageset config for upgrade" \
    "rm -f mirror/data/imageset-config.yaml && aba -d mirror imagesetconf"

# Modify config for upgrade: fast channel, minVersion=older, enable shortestPath
e2e_run "Configure imageset for upgrade path" \
    "_older=\$(cat /tmp/e2e-ocp-version-older) && \
     _desired=\$(cat /tmp/e2e-ocp-version-desired) && \
     _major=\$(echo \$_desired | cut -d. -f1-2) && \
     sed -i \"s/^    - name: stable-\${_major}/    - name: fast-\${_major}/\" mirror/data/imageset-config.yaml && \
     sed -i \"s/^      minVersion: \${_desired}/      minVersion: \${_older}/\" mirror/data/imageset-config.yaml && \
     sed -i 's/^#      shortestPath: true.*/      shortestPath: true/' mirror/data/imageset-config.yaml"

# Append cincinnati-operator to the existing operators packages list (not a new section).
# The catalog YAML should already exist from the earlier catalogs-wait; verify it.
e2e_run "Verify catalog YAML for upgrade" \
    "_ocp_major=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}' | cut -d. -f1-2) && \
     test -s mirror/imageset-config-redhat-operator-catalog-v\${_ocp_major}.yaml"
e2e_run "Append cincinnati-operator to imageset config" \
    "_ocp_major=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}' | cut -d. -f1-2) && \
     grep -A2 'name: cincinnati-operator\$' mirror/imageset-config-redhat-operator-catalog-v\${_ocp_major}.yaml >> mirror/data/imageset-config.yaml"

e2e_run -r 3 2 "Save upgrade images" "aba -d mirror save --retry"
e2e_run "Transfer upgrade archive+config to internal bastion" \
    "scp mirror/data/mirror_*.tar mirror/data/imageset-config.yaml ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_run_remote -r 3 2 "Load upgrade images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

e2e_run_remote "Apply day2 config (upgrade mirror resources)" \
    "cd ~/aba && aba --dir $SNO day2"

# Wait for cincinnati-operator to appear in OperatorHub before applying OSUS
e2e_poll_remote 180 15 "Wait for cincinnati-operator in OperatorHub" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get packagemanifests' | grep ^cincinnati-operator"

e2e_run_remote "Apply OSUS day2" \
    "cd ~/aba && aba --dir $SNO day2-osus"

# Wait for all COs to be available (AVAILABLE=True)
e2e_wait_operators_available $SNO remote

# Set the cluster update channel to fast (matching the imageset config)
_OCP_MAJOR=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}' | cut -d. -f1-2)
e2e_run_remote "Set update channel to fast-${_OCP_MAJOR}" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc adm upgrade channel fast-${_OCP_MAJOR}'"

# Wait until 'oc adm upgrade' lists recommended updates (cluster is healthy and ready)
e2e_poll_remote 600 30 "Wait for cluster ready to upgrade" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc adm upgrade' 2>&1 | grep 'Recommended updates'"

# Re-verify operator health right before triggering -- cluster can degrade between
# the poll above and the trigger (imagestream reconciliation after mesh/OSUS install)
e2e_wait_operators_available $SNO remote

e2e_wait_operators_ready $SNO remote

e2e_run_remote -r 5 2 -d 60 "Trigger cluster upgrade" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc adm upgrade --to-latest=true --allow-not-recommended'"

sleep 3
e2e_poll_remote 120 10 "Verify upgrade in progress" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc adm upgrade' | grep 'upgrade is in progress'"

test_end

# ============================================================================
# 15. Lifecycle: shutdown/startup
# ============================================================================
test_begin "Lifecycle: shutdown/startup"

e2e_run_remote "Shutdown cluster" \
    "cd ~/aba && yes | aba --dir $SNO shutdown --wait"

# GAP 3: Verify 'aba ls' shows node power state after shutdown
e2e_run_remote "Verify 'aba ls' shows poweredOff" \
    "cd ~/aba && aba --dir $SNO ls | grep -i poweredOff"

e2e_run_remote "Startup cluster" \
    "cd ~/aba && aba --dir $SNO startup --wait"

# GAP 3: Verify 'aba ls' shows node power state after startup
e2e_run_remote "Verify 'aba ls' shows poweredOn" \
    "cd ~/aba && aba --dir $SNO ls | grep -i poweredOn"

# Wait for API server and operators to stabilize after startup before asserting
e2e_wait_operators_available $SNO remote

# GAP 4: Verify 'aba login' and 'aba shell' set up kubeconfig correctly
e2e_run_remote "Verify 'aba login' sets kubeconfig" \
    "cd ~/aba && eval \"\$(aba --dir $SNO login)\" && oc get nodes"
e2e_run_remote "Verify 'aba shell' exports work" \
    "cd ~/aba && eval \"\$(aba --dir $SNO shell)\" && oc get clusterversion"

e2e_wait_operators_ready $SNO remote

test_end

# ============================================================================
# 16. Standard cluster with macs.conf
# ============================================================================
test_begin "Standard: cluster with macs.conf"

e2e_run_remote "Delete SNO cluster" \
    "cd ~/aba && aba --dir $SNO delete"
e2e_run_remote "Clean sno cluster dir" \
    "cd ~/aba && aba --dir $SNO clean"

# Build standard cluster
e2e_run_remote "Clean standard cluster dir" \
    "cd ~/aba && rm -rf $STANDARD"
e2e_run_remote "Create standard cluster config" \
    "cd ~/aba && aba cluster -n $STANDARD -t standard -i $(pool_starting_ip standard) --num-workers 2 --step cluster.conf"
e2e_run_remote "Assert $STANDARD/cluster.conf exists" \
    "cd ~/aba && test -f $STANDARD/cluster.conf"

# Generate macs.conf in the cluster dir with random test MACs (test5 pattern).
# Includes surrounding "blah" text to exercise the MAC extraction regex in
# create-agent-config.sh.  All MACs share one random byte for traceability.
e2e_run_remote "Create macs.conf with test MACs" \
    "cd ~/aba && R=\$(printf '%02x' \$((RANDOM%256))) && printf '00:50:56:20:%s:01  blah\nblah 00:50:56:20:%s:02\n00:50:56:20:%s:03\nblah 00:50:56:20:%s:04\n00:50:56:20:%s:05\n00:50:56:20:%s:06 blah\n' \$R \$R \$R \$R \$R \$R > $STANDARD/macs.conf"
e2e_run_remote "Verify macs.conf created" \
    "cd ~/aba && test -f $STANDARD/macs.conf && cat $STANDARD/macs.conf"

e2e_run_remote "Generate agent configs" \
    "cd ~/aba && aba --dir $STANDARD agentconf"
e2e_run_remote "Verify agent-config has MACs" \
    "cd ~/aba && cat $STANDARD/agent-config.yaml | grep -i mac"
# Bootstrap only (saves ~30 min vs full install) -- proves agent configs are
# valid and control plane comes up.  Full operator verification is done on
# the SNO cluster earlier in this suite.
e2e_add_to_cluster_cleanup "$PWD/$STANDARD" remote
e2e_run_remote "Bootstrap standard cluster" \
    "cd ~/aba && aba --dir $STANDARD bootstrap"
e2e_run_remote "Delete standard cluster" \
    "cd ~/aba && aba --dir $STANDARD delete"

test_end

# ============================================================================
# End-of-suite cleanup: uninstall Docker registry on disN + verify
# ============================================================================
test_begin "Cleanup: uninstall registry on disN"

e2e_run_remote "Uninstall Docker registry" \
    "cd ~/aba && aba -d mirror uninstall"
e2e_run_remote "Verify no registry containers" \
    "podman ps | grep -v -e quay -e registry -e CONTAINER | wc -l | grep ^0\$"
e2e_run "Verify registry unreachable on disN" \
    "! curl -sk --connect-timeout 5 https://${DIS_HOST}:8443/v2/"

test_end

suite_end

echo "SUCCESS: suite-airgapped-local-reg.sh"
