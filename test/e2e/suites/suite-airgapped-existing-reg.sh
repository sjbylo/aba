#!/usr/bin/env bash
# =============================================================================
# Suite: Airgapped with Existing Registry (rewrite of test2)
# =============================================================================
# Purpose: Air-gapped workflow with a pre-existing registry. Save images,
#          tar-pipe transfer, load into existing registry, install cluster,
#          deploy app, install ACM.
#
# Unique: must-fail checks, existing registry integration, ACM/MCH,
#         NTP chronyc verification.
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
COMPACT="$(pool_cluster_name compact)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Setup: reset internal bastion" \
    "Existing registry: install on bastion" \
    "Must-fail checks" \
    "Save images to disk" \
    "Tar-pipe transfer to bastion" \
    "Load without regcreds (must fail)" \
    "Load images into existing registry" \
    "Compact: install and delete cluster" \
    "SNO: install cluster" \
    "Deploy vote-app" \
    "ACM: install operators" \
    "ACM: MultiClusterHub" \
    "NTP: day2 and chronyc verify" \
    "Shutdown cluster"

suite_begin "airgapped-existing-reg"

# Pre-flight: abort immediately if the internal bastion (disN) is unreachable
preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers via CLI" "aba --dns $(pool_dns_server)"
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

e2e_run "Reset aba" "aba reset -f"
e2e_run "Clean cluster dirs" "rm -rf $SNO $COMPACT"

# aba reset -f wipes aba.conf; re-apply configuration to avoid vi/editor hangs
e2e_run "Re-apply config after reset" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Re-set dns_servers via CLI" "aba --dns $(pool_dns_server)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets (re-apply)" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

test_end

# ============================================================================
# 2. Install "existing" registry on internal bastion
# ============================================================================
test_begin "Existing registry: install on bastion"

e2e_run -r 2 2 "Download mirror-registry tarball" \
    "aba --dir test mirror-registry-amd64.tar.gz"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror hostname in mirror.conf" \
    "sed -i 's/registry.$(pool_domain)/${DIS_HOST} /g' ./mirror/mirror.conf"
e2e_run "Set operator sets in mirror.conf" "aba --op-sets abatest"

e2e_register_mirror "$PWD/mirror" remote
e2e_run "Install test registry on internal bastion" \
    "test/reg-test-install-remote.sh ${DIS_HOST}"

test_end

# ============================================================================
# 4. Must-fail checks (unique to test2)
# ============================================================================
test_begin "Must-fail checks"

# These commands should fail -- verify they do
e2e_run_must_fail "Sync to unknown host should fail" \
    "aba -d mirror sync -H unknown.example.com --retry"

e2e_run_must_fail "Install mirror to host where mirror already exists should fail" \
    "aba -d mirror -k ~/.ssh/id_rsa -H $DIS_HOST install"

e2e_run_must_fail "Install to localhost (no mirror on localhost) should fail" \
    "aba -d mirror install"

test_end

# ============================================================================
# 5. Save images to disk
# ============================================================================
test_begin "Save images to disk"

e2e_run -r 3 2 "Save images" "aba -d mirror save --retry"

e2e_run "Show saved files" "ls -lh mirror/save/"

test_end

# ============================================================================
# 6. Tar-pipe transfer to bastion
# ============================================================================
test_begin "Tar-pipe transfer to bastion"

# Stdout purity regression test: force the dnf install code path (by removing
# a known RPM) and verify `aba -d mirror tar --out -` produces valid tar on
# stdout with no text contamination.  This catches regressions where install
# messages leak to stdout and corrupt the tar stream (see install >&2 fix).
e2e_run "Remove dialog RPM to force dnf path" \
    "sudo dnf remove -y dialog"
e2e_run "Remove stale dnf log" \
    "rm -f mirror/.dnf-install.log"
e2e_run "Verify tar stdout purity under dnf install" \
    "aba -d mirror tar --out - 2>/tmp/e2e-tar-stderr.log | tar tf - > /dev/null"
e2e_run "Verify dnf install actually ran" \
    "test -s mirror/.dnf-install.log"
e2e_run "Verify dialog was reinstalled" \
    "rpm -q dialog"

# Now do the real tar-pipe transfer
e2e_run -r 3 2 "Pipe tar to internal bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'tar xvf -'"

e2e_run_remote "Remove dialog RPM to force dnf install path" \
    "sudo dnf remove -y dialog"
e2e_run_remote "Remove stale dnf log" \
    "cd ~/aba && rm -f .dnf-install.log"
e2e_run_remote "Install aba on internal bastion" \
    "cd ~/aba && ./install"
e2e_run_remote "Verify dialog was reinstalled" \
    "rpm -q dialog"
e2e_run_remote "Verify single dnf batch (no duplicate install)" \
    "cd ~/aba && test \$(grep -c 'Transaction Summary' .dnf-install.log) -eq 1"

# Populate regcreds dir on disN so ABA can talk to the existing registry.
# reg-install.sh puts creds in ~/.docker/config.json and CA in ~/quay-install/.
e2e_run_remote "Create regcreds dir" \
    "mkdir -p ~/.aba/mirror/mirror"
e2e_run_remote "Copy pull secret to regcreds" \
    "cp -v ~/.docker/config.json ~/.aba/mirror/mirror/pull-secret-mirror.json"
e2e_run_remote "Copy root CA to regcreds" \
    "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/.aba/mirror/mirror/"

test_end

# ============================================================================
# 7. Load without regcreds -- must fail (Gap 4: common user mistake)
# ============================================================================
test_begin "Load without regcreds (must fail)"

# Back up regcreds before removing, then restore after the must-fail test.
# This is safer than manually reconstructing from ~/.docker/config.json.
e2e_run_remote -q "Back up regcreds" \
    "cp -a ~/.aba/mirror/mirror/ /tmp/e2e-regcreds-backup/"

e2e_run_remote -q "Remove regcreds" \
    "rm -rf ~/.aba/mirror/mirror/"

e2e_run_must_fail_remote "Load without regcreds should fail" \
    "cd ~/aba && aba -d mirror load --retry"

e2e_run_remote "Restore regcreds from backup" \
    "rm -rf ~/.aba/mirror/mirror && cp -a /tmp/e2e-regcreds-backup ~/.aba/mirror/mirror && rm -rf /tmp/e2e-regcreds-backup"
e2e_run_remote "Verify registry access with restored regcreds" \
    "cd ~/aba && aba -d mirror verify"

test_end

# ============================================================================
# 8. Load images into existing registry
# ============================================================================
test_begin "Load images into existing registry"

e2e_run_remote -r 3 2 "Load images into registry" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 9. Compact: bootstrap and delete (Gap 1: coverage for 3-node combo)
#    Full install takes ~40 min; bootstrap proves images loaded correctly
#    and the cluster can start (control plane comes up). Saves ~30 min.
# ============================================================================
test_begin "Compact: install and delete cluster"

e2e_register_cluster "$PWD/$COMPACT" remote
e2e_run_remote -r 1 1 "Create compact cluster (bootstrap only)" \
    "cd ~/aba && aba cluster -n $COMPACT -t compact --starting-ip $(pool_compact_api_vip) --step bootstrap"
e2e_run_remote "Delete compact cluster" \
    "cd ~/aba && aba --dir $COMPACT delete"
e2e_run_remote -q "Clean compact dir" \
    "cd ~/aba && rm -rf $COMPACT"

test_end

# ============================================================================
# 10. Install SNO cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_register_cluster "$PWD/$SNO" remote
e2e_run_remote -r 1 1 "Create SNO cluster" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run_remote "Show cluster operator status" \
    "cd ~/aba && aba --dir $SNO run"
e2e_poll_remote 600 30 "Wait for all operators fully available" \
    "cd ~/aba && aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False\$' | wc -l | grep ^0\$"
e2e_diag_remote "Show cluster operators" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get co'"

e2e_run_remote "Apply day2 config" \
    "cd ~/aba && aba --dir $SNO day2"

test_end

# ============================================================================
# 11. Deploy vote-app
# ============================================================================
test_begin "Deploy vote-app"

# Pre-check: verify vote-app image exists in mirror before attempting deploy
e2e_run_remote "Verify vote-app image in mirror (skopeo)" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && skopeo inspect --tls-verify=false docker://\$reg_host:\$reg_port\$reg_path/sjbylo/flask-vote-app:latest"

e2e_run_remote "Create demo project" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc new-project demo' || true"
e2e_run_remote -r 3 2 "Launch vote-app from mirror" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && aba --dir $SNO run --cmd \"oc new-app --insecure-registry=true --image \$reg_host:\$reg_port\$reg_path/sjbylo/flask-vote-app --name vote-app -n demo\""
e2e_run_remote "Wait for vote-app rollout" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc rollout status deployment vote-app -n demo'"

test_end

# ============================================================================
# 12. ACM: install operators
# ============================================================================
test_begin "ACM: install operators"

# Add ACM operator to imageset and sync
e2e_run "Set op_sets=acm" "aba --op-sets acm"
e2e_run -r 3 2 "Save ACM images" "aba -d mirror save --retry"
e2e_run -r 3 2 "Pipe ACM tar to internal bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'tar xvf -'"
e2e_run_remote -r 3 2 "Load ACM images" \
    "cd ~/aba && aba -d mirror load --retry"

e2e_run_remote "Apply day2 config (ACM operator resources)" \
    "cd ~/aba && aba --dir $SNO day2"

test_end

# ============================================================================
# 13. ACM: MultiClusterHub
# ============================================================================
test_begin "ACM: MultiClusterHub"

e2e_run_remote "Install ACM subscription" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc apply -f test/acm-subs.yaml'"
e2e_run_remote -r 10 1.5 "Wait for ACM operator" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get csv -n open-cluster-management -o name | grep advanced-cluster-management'"
e2e_run_remote "Install MultiClusterHub" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc apply -f test/acm-mch.yaml'"
e2e_run_remote -r 20 1.5 "Wait for MCH ready" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get multiclusterhub -n open-cluster-management -o jsonpath={.items[0].status.phase} | grep Running'"

test_end

# ============================================================================
# 14. NTP: day2 configuration and chronyc verify
# ============================================================================
test_begin "NTP: day2 and chronyc verify"

e2e_run_remote "Apply day2 NTP config" \
    "cd ~/aba && aba --dir $SNO day2-ntp"
e2e_run_remote -r 3 2 "Verify chronyc sources" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc debug node/\$(oc get nodes -o name | head -1 | cut -d/ -f2) -- chroot /host chronyc sources' | grep $NTP_IP"

test_end

# ============================================================================
# 15. Shutdown
# ============================================================================
test_begin "Shutdown cluster"

e2e_run_remote "Shutdown SNO cluster" \
    "cd ~/aba && yes | aba --dir $SNO shutdown --wait"

test_end

# ============================================================================
# End-of-suite cleanup: uninstall registry on disN + verify
# ============================================================================
test_begin "Cleanup: uninstall registry on disN"

e2e_run "Uninstall registry on internal bastion" \
    "aba -d mirror uninstall"
e2e_run "Verify registry unreachable on disN" \
    "! curl -sk --connect-timeout 5 https://${DIS_HOST}:8443/health/instance"

test_end

suite_end

echo "SUCCESS: suite-airgapped-existing-reg.sh"
