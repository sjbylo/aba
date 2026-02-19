#!/bin/bash
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
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"
e2e_run "Show ocp_version" "grep -o '^ocp_version=[^ ]*' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Reset aba" "aba reset -f"
e2e_run "Clean cluster dirs" "rm -rfv $SNO $COMPACT"

# aba reset -f wipes aba.conf; re-apply configuration to avoid vi/editor hangs
e2e_run "Re-apply config after reset" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets (re-apply)" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

test_end

# ============================================================================
# 2. Setup: reset internal bastion (reuse clone-and-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end

# ============================================================================
# 3. Install "existing" registry on internal bastion
# ============================================================================
test_begin "Existing registry: install on bastion"

e2e_run -r 2 2 "Download mirror-registry tarball" \
    "aba --dir test mirror-registry-amd64.tar.gz"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror host" \
    "sed -i 's/registry.example.com/${DIS_HOST} /g' ./mirror/mirror.conf"
e2e_run "Set operator sets in mirror.conf" "aba --op-sets abatest"

e2e_run "Install test registry on bastion" \
    "test/reg-test-install-remote.sh ${DIS_HOST}"

test_end

# ============================================================================
# 4. Must-fail checks (unique to test2)
# ============================================================================
test_begin "Must-fail checks"

# These commands should fail -- verify they do
e2e_run_must_fail "Sync to unknown host should fail" \
    "aba -d mirror sync -H unknown.example.com --retry"

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

e2e_run -r 3 2 "Pipe tar to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xvf -'"

test_end

# ============================================================================
# 7. Load without regcreds -- must fail (Gap 4: common user mistake)
# ============================================================================
test_begin "Load without regcreds (must fail)"

# Before regcreds are in place, loading should fail with a clear error.
# This validates error handling for a common user mistake.
e2e_run_remote -q "Remove any existing regcreds" \
    "cd ~/aba && rm -rfv mirror/regcreds"

e2e_run_must_fail_remote "Load without regcreds should fail" \
    "cd ~/aba && aba -d mirror load --retry"

# Now restore regcreds so subsequent steps work
e2e_run_remote "Restore regcreds from existing registry" \
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

e2e_run_remote "Create compact cluster (bootstrap only)" \
    "cd ~/aba && aba cluster -n $COMPACT -t compact --starting-ip $(pool_compact_api_vip) --step bootstrap"
e2e_run_remote "Delete compact cluster" \
    "cd ~/aba && aba --dir $COMPACT delete"
e2e_run_remote -q "Clean compact dir" \
    "cd ~/aba && rm -rfv $COMPACT"

test_end

# ============================================================================
# 10. Install SNO cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_run_remote "Create SNO cluster" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run_remote "Verify cluster operators" \
    "cd ~/aba && aba --dir $SNO run"
e2e_run_remote -r 30 10 "Wait for all operators fully available" \
    "cd ~/aba && aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False\$' | wc -l | grep ^0\$"
e2e_diag_remote "Show cluster operators" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 11. Deploy vote-app
# ============================================================================
test_begin "Deploy vote-app"

e2e_run_remote "Deploy vote-app" \
    "cd ~/aba && test/deploy-test-app.sh"

test_end

# ============================================================================
# 12. ACM: install operators
# ============================================================================
test_begin "ACM: install operators"

# Add ACM operator to imageset and sync
e2e_run "Set op_sets=acm" "aba --op-sets acm"
e2e_run -r 3 2 "Save ACM images" "aba -d mirror save --retry"
e2e_run -r 3 2 "Pipe ACM tar to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xvf -'"
e2e_run_remote -r 3 2 "Load ACM images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end

# ============================================================================
# 13. ACM: MultiClusterHub
# ============================================================================
test_begin "ACM: MultiClusterHub"

e2e_run_remote "Install ACM subscription" \
    "cd ~/aba && aba --dir $SNO cmd 'oc apply -f test/acm-subs.yaml'"
e2e_run_remote -r 10 1.5 "Wait for ACM operator" \
    "cd ~/aba && aba --dir $SNO cmd 'oc get csv -n open-cluster-management -o name | grep advanced-cluster-management'"
e2e_run_remote "Install MultiClusterHub" \
    "cd ~/aba && aba --dir $SNO cmd 'oc apply -f test/acm-mch.yaml'"
e2e_run_remote -r 20 1.5 "Wait for MCH ready" \
    "cd ~/aba && aba --dir $SNO cmd 'oc get multiclusterhub -n open-cluster-management -o jsonpath={.items[0].status.phase} | grep Running'"

test_end

# ============================================================================
# 14. NTP: day2 configuration and chronyc verify
# ============================================================================
test_begin "NTP: day2 and chronyc verify"

e2e_run_remote "Apply day2 NTP config" \
    "cd ~/aba && aba --dir $SNO day2-ntp"
e2e_run_remote -r 3 2 "Verify chronyc sources" \
    "cd ~/aba && aba --dir $SNO cmd 'oc debug node/\$(oc get nodes -o name | head -1 | cut -d/ -f2) -- chroot /host chronyc sources' | grep $NTP_IP"

test_end

# ============================================================================
# 15. Shutdown
# ============================================================================
test_begin "Shutdown cluster"

e2e_run_remote "Shutdown SNO cluster" \
    "cd ~/aba && yes | aba --dir $SNO shutdown --wait"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-airgapped-existing-reg.sh"
