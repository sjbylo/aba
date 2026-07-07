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
source "$_SUITE_DIR/../lib/pool-ops.sh"
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
    "Registry: Docker install and verify (custom params)" \
    "Registry: Quay install and load" \
    "SNO: install cluster" \
    "SNO: day2 configuration" \
    "SNO: day2-ntp from scratch" \
    "Incremental: UBI image load" \
    "Incremental: vote-app image load" \
    "Deploy: vote-app with IDMS" \
    "Incremental: mesh operators" \
    "Deploy: service mesh demo" \
    "Lifecycle: shutdown/startup" \
    "Upgrade: cross-minor with admin ack gate" \
    "Standard: cluster with macs.conf" \
    "Cleanup: uninstall registry on disN"

suite_begin "airgapped-local-reg"

# Pre-flight: abort immediately if the internal bastion (disN) is unreachable
preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_install_aba

e2e_run "Remove oc-mirror caches (conN)" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"
e2e_run_remote -q "Remove oc-mirror caches (disN)" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"

# Use fast channel for cross-minor upgrade testing.
# We configure with --version p (N-1), then compute N-2 in the next step
# and reconfigure with the exact N-2 version. N-2 is installed, then
# upgraded to N-1 later in the suite.
e2e_run "Configure aba.conf (fast channel, initial setup)" \
    "aba --noask --platform vmw --channel fast --version p --base-domain $(pool_domain)"

e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=fast aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"

e2e_run "Clear NTP (install without NTP, day2-ntp will add it later)" \
    "sed -i 's/^ntp_servers=.*/ntp_servers=/' aba.conf"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"
e2e_run "Verify aba.conf: op_sets" "grep '^op_sets=abatest' aba.conf"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror hostname in mirror.conf" \
    "sed -i 's/registry.$(pool_domain)/${DIS_HOST} /g' ./mirror/mirror.conf"
e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"

test_end

# ============================================================================
# 2. Calculate cross-minor versions for upgrade testing
# ============================================================================
test_begin "Setup: calculate older version for upgrade"

# aba.conf has N-1 (from --version p above). That becomes the upgrade target.
# Compute N-2 (the install version) using fetch_older_version, then
# reconfigure aba.conf with the N-2 version.
e2e_run "Compute cross-minor versions (N-2 install, N-1 upgrade target)" "
    source scripts/include_all.sh
    desired=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}')
    older=\$(fetch_older_version fast)
    [ -n \"\$desired\" ] || { echo 'FAIL: N-1 version not set in aba.conf'; exit 1; }
    [ -n \"\$older\" ] || { echo 'FAIL: cannot resolve N-2 version'; exit 1; }
    older_minor=\$(echo \$older | cut -d. -f1-2)
    desired_minor=\$(echo \$desired | cut -d. -f1-2)
    [ \"\$older_minor\" != \"\$desired_minor\" ] || { echo \"FAIL: versions are same minor (\$older vs \$desired)\"; exit 1; }
    # Walk back z-streams if the latest N-2 isn't in the upgrade target's graph yet
    if ! verify_upgrade_path_exists \"\$older\" \"\$desired\" fast 2>/dev/null; then
        echo \"Latest N-2 (\$older) not in fast-\${desired_minor} graph -- searching for valid version\"
        all_versions=\$(fetch_all_versions fast \"\$older_minor\")
        found=\"\"
        for v in \$(echo \"\$all_versions\" | sort -rV); do
            if verify_upgrade_path_exists \"\$v\" \"\$desired\" fast 2>/dev/null; then
                echo \"Found valid N-2: \$v\"
                older=\"\$v\"
                found=1
                break
            fi
        done
        [ -n \"\$found\" ] || { echo \"FAIL: no \$older_minor version found in fast-\$desired_minor graph\"; exit 1; }
    fi
    echo \"Install (N-2): \$older  Upgrade target (N-1): \$desired\"
    sudo rm -f /tmp/e2e-ocp-version-desired /tmp/e2e-ocp-version-older
    echo \$desired > /tmp/e2e-ocp-version-desired
    echo \$older > /tmp/e2e-ocp-version-older
"

# Now set aba.conf to the N-2 version for the initial install
e2e_run "Set aba.conf to N-2 version for install" \
    "aba -v \$(cat /tmp/e2e-ocp-version-older)"
e2e_run "Verify aba.conf: version matches N-2" "grep ^ocp_version=\$(cat /tmp/e2e-ocp-version-older) aba.conf"

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
e2e_run_remote "Check bundle mode is active" \
    "cd ~/aba && test -f .bundle"
e2e_run_remote "See install bundle banner and help on internal bastion" \
    "cd ~/aba && aba"
e2e_run_remote "Verify dialog was reinstalled" \
    "rpm -q dialog"
e2e_run_remote "Verify single dnf batch (no duplicate install)" \
    "cd ~/aba && test \$(grep -c 'Transaction Summary' .dnf-install.log) -eq 1"

test_end

# ============================================================================
# 6. Registry: Docker install and verify (smoke test with custom params)
#    Exercises non-default mirror.conf values: port, user, password, path,
#    data_dir.  Verifies install + accessibility, then uninstalls immediately.
# ============================================================================
test_begin "Registry: Docker install and verify (custom params)"

_DOCKER_PORT=5002
_DOCKER_USER=e2etester
_DOCKER_PW='T3st!@#P4ss&*()'
_DOCKER_PATH=/e2e/mirror
_DOCKER_DATADIR="~/e2e-mirror-datadir1"

e2e_run_remote "Create mirror.conf on bastion" \
    "cd ~/aba && aba -d mirror mirror.conf"
e2e_run_remote "Set reg_host to local hostname" \
    "sed -i 's/^reg_host=.*/reg_host=${DIS_HOST}/g' ~/aba/mirror/mirror.conf"

e2e_add_to_mirror_cleanup "$PWD/mirror" remote
e2e_run_remote "Install Docker registry (custom port/user/pw/path/data_dir)" \
    "cd ~/aba && aba -d mirror install --vendor docker --reg-port $_DOCKER_PORT --reg-user $_DOCKER_USER --reg-password '${_DOCKER_PW}' --reg-path $_DOCKER_PATH --data-dir '$_DOCKER_DATADIR'"
e2e_poll_remote 60 5 "Wait for Docker registry container" \
    "podman ps | grep registry"
e2e_run_remote "Verify Docker registry running" \
    "podman ps | grep registry"
e2e_run_remote "Verify Docker registry listening on port $_DOCKER_PORT" \
    "ss -tlnp | grep ':${_DOCKER_PORT} '"
e2e_run_remote "Verify Docker registry accessible with custom creds" \
    "cd ~/aba && aba -d mirror verify"
e2e_run_remote "Uninstall Docker registry (smoke test done)" \
    "cd ~/aba && aba -d mirror uninstall"
e2e_run "Assert: Docker registry fully removed on disN" "e2e_assert_registry_removed"
e2e_run_remote "Remove custom data dir on disN" \
    "sudo rm -rf $_DOCKER_DATADIR"

# Negative path: load without data/ dir should fail
e2e_run_remote -q "Remove data dir for must-fail test" \
    "cd ~/aba && mv mirror/data mirror/data.bak"
e2e_run_must_fail_remote "Load without data dir should fail" \
    "cd ~/aba && aba -d mirror load"
e2e_run_remote -q "Restore data dir" \
    "cd ~/aba && mv mirror/data.bak mirror/data"

test_end

# ============================================================================
# 7. Registry: Quay install and load (full pipeline with custom port)
#    Quay on non-default port exercises the entire air-gapped workflow:
#    install -> load -> cluster install -> day2 -> upgrade.
# ============================================================================
test_begin "Registry: Quay install and load"

_QUAY_PORT=8448
e2e_run_remote "Set vendor=quay and reg_port=$_QUAY_PORT for Quay" \
    "cd ~/aba && aba --dir mirror --vendor quay --reg-port $_QUAY_PORT"
e2e_diag_remote "Show mirror.conf on bastion" "grep -E '^\w' ~/aba/mirror/mirror.conf"

e2e_run_remote "Install Quay registry on port $_QUAY_PORT" \
    "cd ~/aba && aba -d mirror install"
e2e_poll_remote 60 5 "Wait for Quay container" \
    "podman ps | grep quay"
e2e_run_remote "Verify Quay running" \
    "podman ps | grep quay"
e2e_run_remote "Verify Quay listening on custom port $_QUAY_PORT" \
    "ss -tlnp | grep ':${_QUAY_PORT} '"
e2e_run_remote "Verify Quay accessible on custom port" \
    "curl -k -sf https://${DIS_HOST}:${_QUAY_PORT}/health/instance"

e2e_run_remote "Override op_sets in mirror.conf (exercises mirror.conf override)" \
    "cd ~/aba && sed -i '/^#op_sets=/c\\op_sets=abatest' mirror/mirror.conf"

e2e_snapshot_file_remote "initial-load" "aba/mirror/data/imageset-config.yaml"
e2e_run_remote -r 3 2 "Load images into Quay registry" \
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
    "cd ~/aba && sed -i 's/^master_cpu_count=.*/master_cpu_count=28/' $SNO/cluster.conf && \
     sed -i 's/^master_mem=.*/master_mem=28/' $SNO/cluster.conf"
e2e_diag_remote "Show SNO cluster.conf" "grep -E '^\w' ~/aba/$SNO/cluster.conf"
e2e_run_remote -r 2 10 "Install SNO cluster" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) -s install"
e2e_run_remote "Show cluster operator status" \
    "cd ~/aba && aba --dir $SNO run"
e2e_wait_cluster_ready $SNO remote
e2e_diag_remote "Show cluster operators" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 9. SNO: day2 configuration
# ============================================================================
test_begin "SNO: day2 configuration"

e2e_run_remote "Apply day2 config" \
    "cd ~/aba && aba --dir $SNO day2"

e2e_run_remote "Verify CatalogSources present after day2" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get catalogsource -n openshift-marketplace --no-headers' | grep ."

test_end

# ============================================================================
# 9b. SNO: day2-ntp from scratch (cluster was installed WITHOUT NTP)
# ============================================================================
# Cluster was installed with ntp_servers empty.  Now apply both the IP and
# hostname as day2 NTP config, forcing a fresh MachineConfig creation and
# MCO reboot.  This exercises the Phase 1 MCP wait in day2-config-ntp.sh.
test_begin "SNO: day2-ntp from scratch"

e2e_run_remote "Set NTP in cluster.conf (IP + hostnames)" \
    "cd ~/aba && aba -d $SNO --ntp $NTP_IP ntp.example.com ntp.lan"

e2e_run_remote "Apply day2 NTP config (no prior NTP)" \
    "cd ~/aba && aba --dir $SNO day2-ntp"

e2e_run_remote "Verify chronyc sources show IP" \
    "cd ~/aba && aba --dir $SNO ssh --cmd 'chronyc -N sources' | grep $NTP_IP"

e2e_run_remote "Verify chrony.conf contains ntp.example.com" \
    "cd ~/aba && aba --dir $SNO ssh --cmd 'cat /etc/chrony.conf' | grep 'server ntp.example.com iburst'"

e2e_run_remote "Verify chrony.conf contains ntp.lan" \
    "cd ~/aba && aba --dir $SNO ssh --cmd 'cat /etc/chrony.conf' | grep 'server ntp.lan iburst'"

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
e2e_snapshot_file "ubi-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save UBI image to disk" \
    "aba -d mirror save --retry"
e2e_run "Transfer UBI archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_snapshot_file_remote "ubi-load" "aba/mirror/data/imageset-config.yaml"
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
e2e_snapshot_file "voteapp-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save vote-app image to disk" \
    "aba -d mirror save --retry"
e2e_run "Transfer vote-app archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_snapshot_file_remote "voteapp-load" "aba/mirror/data/imageset-config.yaml"
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
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get project demo || oc new-project demo'"
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

# Save+Load config: ALL operators (old + new) so the archive is self-contained.
# oc-mirror v2 diskToMirror resolves catalog data from the archive; operators
# not in the archive cause oc-mirror to reach upstream (fails on disconnected
# hosts).  No platform section -- oc-mirror v2 errors with "no release images
# found" when platform is present but the delta tar has no release images.
# oc-mirror only saves the delta since the last mirrorToDisk, so including
# already-mirrored operators (kiali-ossm) adds negligible overhead.
e2e_run "Create config with all operators for save+load" \
    "cat > mirror/data/imageset-config.yaml <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_VER_MAJOR}
    packages:
\$(grep -A2 'name: kiali-ossm\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml)
\$(grep -A2 'name: servicemeshoperator3\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml)
EOF"
e2e_diag "Show save+load config" "cat mirror/data/imageset-config.yaml"

e2e_snapshot_file "mesh-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save mesh operator images" "aba -d mirror save --retry"

e2e_run "Transfer archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_snapshot_file_remote "mesh-load" "aba/mirror/data/imageset-config.yaml"
e2e_run_remote -r 3 2 "Load mesh images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

e2e_run_remote "Apply day2 config (mesh operator resources)" \
    "cd ~/aba && aba --dir $SNO day2"

# Verify previously loaded operators survived the incremental load.
# oc-mirror rebuilds the catalog index during load; a partial config would
# silently drop operators not listed (see ai/OC-MIRROR-INTERNALS.md).
e2e_poll_remote 180 15 "Verify kiali-ossm still in OperatorHub after mesh load" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get packagemanifests' | grep ^kiali-ossm"

test_end

# ============================================================================
# 13b. Deploy: service mesh demo application
# FIXME: Disabled -- mesh demo install (00-install-all-mesh3.sh) fails with
#        "No route available" on current OCP versions. Re-enable once the
#        openshift-service-mesh-demo repo is updated/fixed.
# ============================================================================
test_begin "Deploy: service mesh demo"
echo "  SKIPPED: mesh demo install broken upstream (openshift-service-mesh-demo repo)"
if false; then

# Mirror the Kiali demo app images (not included in operator catalogs).
e2e_run "Create imageset config for mesh demo app images" \
    "cat > mirror/data/imageset-config.yaml <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: quay.io/kiali/demo_travels_cars:v1
  - name: quay.io/kiali/demo_travels_control:v1
  - name: quay.io/kiali/demo_travels_discounts:v1
  - name: quay.io/kiali/demo_travels_flights:v1
  - name: quay.io/kiali/demo_travels_hotels:v1
  - name: quay.io/kiali/demo_travels_insurances:v1
  - name: quay.io/kiali/demo_travels_mysqldb:v1
  - name: quay.io/kiali/demo_travels_portal:v1
  - name: quay.io/kiali/demo_travels_travels:v1
EOF"
e2e_snapshot_file "mesh-demo-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save mesh demo app images" "aba -d mirror save --retry"
e2e_run "Transfer demo app archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_run_remote -r 3 2 "Load mesh demo app images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"
e2e_run_remote "Apply day2 config (mesh demo image resources)" \
    "cd ~/aba && aba --dir $SNO day2"

# Clone the demo repo on the connected side, rewrite image references to
# point at the mirror registry, then transfer and run on the air-gapped side.
e2e_run "Clone service mesh demo repo" \
    "rm -rf /tmp/mesh-demo && git clone --depth 1 https://github.com/sjbylo/openshift-service-mesh-demo.git /tmp/mesh-demo"

# Rewrite image references: quay.io -> mirror registry
e2e_run "Rewrite image refs to mirror" \
    "source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && \
     find /tmp/mesh-demo -name '*.yaml' -exec sed -i \"s#quay\\.io#\${reg_host}:\${reg_port}\${reg_path}#g\" {} + && \
     sed -i 's/source: .*/source: redhat-operators/g' /tmp/mesh-demo/operators/*"

e2e_run "Transfer mesh demo to internal bastion" \
    "scp -rp /tmp/mesh-demo ${INTERNAL_BASTION}:mesh-demo"

e2e_run_remote "Install service mesh demo" \
    "cd ~/mesh-demo && export KUBECONFIG=~/aba/$SNO/iso-agent-based/auth/kubeconfig && echo y | ./00-install-all-mesh3.sh"

e2e_poll_remote 600 30 "Wait for Istio control plane ready" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get istio default -n istio-system -o jsonpath={.status.state}' | grep -q Healthy"

e2e_poll_remote 300 15 "Wait for travels app pods ready" \
    "cd ~/aba && for ns in travel-control travel-agency travel-portal; do \
       _pods=\$(aba --dir $SNO run --cmd \"oc get pods -n \$ns --no-headers\") && \
       echo \"\$_pods\" | grep -q Running || exit 1; \
       echo \"\$_pods\" | grep -Ev 'Running|Completed' | grep -q . && exit 1; \
     done"

e2e_diag_remote "Show Istio control plane status" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get istio,istiocni -A'"
e2e_diag_remote "Show travels app pods" \
    "cd ~/aba && for ns in travel-control travel-agency travel-portal; do echo \"--- \$ns ---\"; aba --dir $SNO run --cmd \"oc get pods -n \$ns\"; done"

# Cleanup: uninstall mesh demo (free resources before upgrade)
e2e_run_remote "Uninstall service mesh demo" \
    "cd ~/mesh-demo && export KUBECONFIG=~/aba/$SNO/iso-agent-based/auth/kubeconfig && echo y | ./99-uninstall-all-mesh3.sh"
e2e_run_remote "Remove mesh demo dir" "rm -rf ~/mesh-demo"
e2e_run "Remove local mesh demo clone" "rm -rf /tmp/mesh-demo"
fi

test_end

# ============================================================================
# 14. Lifecycle: shutdown/startup
# ============================================================================
test_begin "Lifecycle: shutdown/startup"

e2e_run_remote "Shutdown cluster" \
    "cd ~/aba && yes | aba --dir $SNO shutdown --wait"

e2e_poll_remote 180 10 "Wait for VM to power off" \
    "cd ~/aba && aba --dir $SNO ls | grep -i poweredOff"

e2e_run_remote "Startup cluster" \
    "cd ~/aba && aba --dir $SNO startup --wait"

e2e_poll_remote 180 10 "Wait for VM to power on" \
    "cd ~/aba && aba --dir $SNO ls | grep -i poweredOn"

# Wait for API server and operators to stabilize after startup before asserting
e2e_wait_cluster_available $SNO remote

e2e_run_remote "Verify 'aba login' sets kubeconfig" \
    "cd ~/aba && eval \"\$(aba --dir $SNO login)\" && oc get nodes"
e2e_run_remote "Verify 'aba shell' exports work" \
    "cd ~/aba && eval \"\$(aba --dir $SNO shell)\" && oc get clusterversion"

e2e_wait_cluster_ready $SNO remote

test_end

# ============================================================================
# 15. Upgrade: cross-minor with admin ack gate
# ============================================================================
test_begin "Upgrade: cross-minor with admin ack gate"

# Save the target (N-1) version images using --upgrade-to (auto-generates
# ISC with shortestPath, minVersion=current, maxVersion=target).
# Force ISC regeneration: earlier tests (mesh, UBI, vote-app) manually appended to the ISC,
# making it appear "user-edited" (newer than .created). Without this, the save step would
# preserve the stale mesh-only ISC instead of generating the upgrade ISC with shortestPath.
e2e_run "Set --upgrade-to for cross-minor upgrade" \
    "cd ~/aba && desired=\$(cat /tmp/e2e-ocp-version-desired) && \
     aba -d mirror --upgrade-to \$desired && \
     got=\$(grep '^ocp_upgrade_to=' mirror/mirror.conf | cut -d= -f2 | awk '{print \$1}') && \
     [ \"\$got\" = \"\$desired\" ] || { echo \"FAIL: mirror.conf ocp_upgrade_to=\$got expected \$desired\"; exit 1; } && \
     aba --force -d mirror imagesetconf"

# Append cincinnati-operator to the existing operators packages list (not a new section).
# The catalog YAML should already exist from the earlier catalogs-wait; verify it.
e2e_run "Verify catalog YAML for upgrade" \
    "_ocp_major=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}' | cut -d. -f1-2) && \
     test -s mirror/imageset-config-redhat-operator-catalog-v\${_ocp_major}.yaml"
e2e_run "Append cincinnati-operator to imageset config (if not already present)" \
    "_ocp_major=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}' | cut -d. -f1-2) && \
     if ! grep -q 'name: cincinnati-operator' mirror/data/imageset-config.yaml; then \
         grep -A2 'name: cincinnati-operator\$' mirror/imageset-config-redhat-operator-catalog-v\${_ocp_major}.yaml >> mirror/data/imageset-config.yaml; \
     else \
         echo 'cincinnati-operator already in imageset config -- skipping'; \
     fi"

e2e_snapshot_file "upgrade-save" "mirror/data/imageset-config.yaml"
e2e_run -r 1 2 "Save upgrade images" "aba -d mirror save --retry"
e2e_run "Transfer upgrade archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_snapshot_file_remote "upgrade-load" "aba/mirror/data/imageset-config.yaml"
e2e_run_remote -r 1 2 "Load upgrade images" \
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
e2e_wait_cluster_available $SNO remote

# Wait up to 30 min for all operators to stabilize before upgrading.
# Operators can flap after heavy deployments (OSUS, service mesh) on SNO.
e2e_wait_cluster_ready $SNO remote 1800

# Cross-minor upgrade: first attempt WITHOUT --force must FAIL.
# Admin acknowledgment gates (Upgradeable=False) block cross-minor upgrades
# until the admin explicitly acknowledges API removals. Without --force, oc
# refuses the upgrade.
e2e_run_must_fail_remote "Upgrade without --force must fail (admin ack gate)" \
    "cd ~/aba && aba --dir $SNO upgrade --to $(cat /tmp/e2e-ocp-version-desired) --skip-day2"

# Second attempt WITH --force must PASS -- bypasses admin ack gates.
e2e_run_remote "Upgrade with --force (bypass admin ack gate)" \
    "cd ~/aba && aba --dir $SNO upgrade --to $(cat /tmp/e2e-ocp-version-desired) --force --skip-day2"

sleep 3
e2e_poll_remote 120 10 "Verify upgrade in progress" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc adm upgrade' | grep 'upgrade is in progress'"

# Wait for upgrade to complete before cleanup
e2e_wait_cluster_ready $SNO remote 2700

test_end

# ============================================================================
# 16. Standard cluster with macs.conf
# ============================================================================
test_begin "Standard: cluster with macs.conf"

e2e_run_remote "Delete SNO cluster" \
    "cd ~/aba && aba --dir $SNO delete"
e2e_remove_from_cluster_cleanup "$PWD/$SNO" remote
e2e_run_remote "Remove sno cluster dir" \
    "cd ~/aba && rm -rf $SNO"

# Build standard cluster -- delete any leftover VMs before removing the dir
_e2e_delete_leftover_cluster_remote "$STANDARD"
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
e2e_run_remote "Verify agent-config has MACs from macs.conf" \
    "cd ~/aba && grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' $STANDARD/agent-config.yaml | grep -q ."
# Bootstrap only (saves ~30 min vs full install) -- proves agent configs are
# valid and control plane comes up.  Full operator verification is done on
# the SNO cluster earlier in this suite.
e2e_add_to_cluster_cleanup "$PWD/$STANDARD" remote
e2e_run_remote "Bootstrap standard cluster" \
    "cd ~/aba && aba --dir $STANDARD bootstrap"
e2e_run_remote "Delete standard cluster" \
    "cd ~/aba && aba --dir $STANDARD delete"
e2e_remove_from_cluster_cleanup "$PWD/$STANDARD" remote
e2e_run_remote "Clean standard cluster dir" \
    "cd ~/aba && rm -rf $STANDARD"

test_end

# ============================================================================
# End-of-suite cleanup: uninstall Quay registry on disN + verify
# ============================================================================
test_begin "Cleanup: uninstall registry on disN"

e2e_run_remote "Uninstall Quay registry" \
    "cd ~/aba && aba -d mirror uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"
e2e_run "Verify registry unreachable on disN" \
    "! curl -sk --connect-timeout 5 https://${DIS_HOST}:${_QUAY_PORT}/v2/"

test_end

suite_end; _rc=$?

exit $_rc
