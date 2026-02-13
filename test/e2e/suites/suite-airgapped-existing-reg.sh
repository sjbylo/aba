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
    "Setup: reset internal bastion" \
    "Existing registry: install on bastion" \
    "Must-fail checks" \
    "Save images to disk" \
    "Tar-pipe transfer to bastion" \
    "Load images into existing registry" \
    "SNO: install cluster" \
    "Deploy vote-app" \
    "ACM: install operators" \
    "ACM: MultiClusterHub" \
    "NTP: day2 and chronyc verify" \
    "Shutdown cluster"

suite_begin "airgapped-existing-reg"

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch --platform vmw --op-sets abatest

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l}"
e2e_run "Show ocp_version" "grep -o '^ocp_version=[^ ]*' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Reset aba" "aba reset -f"
e2e_run "Clean cluster dirs" "rm -rf sno compact standard"

test_end 0

# ============================================================================
# 2. Setup: reset internal bastion (reuse clone-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end 0

# ============================================================================
# 3. Install "existing" registry on internal bastion
# ============================================================================
test_begin "Existing registry: install on bastion"

e2e_run -r 1 30 "Download mirror-registry tarball" \
    "aba --dir test mirror-registry-amd64.tar.gz"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set mirror host" \
    "sed -i 's/registry.example.com/${DIS_HOST} /g' ./mirror/mirror.conf"
e2e_run "Set operator sets in mirror.conf" "aba --op-sets abatest"

e2e_run "Install test registry on bastion" \
    "test/reg-test-install-remote.sh ${TEST_USER:-steve} ${DIS_HOST}"

test_end 0

# ============================================================================
# 4. Must-fail checks (unique to test2)
# ============================================================================
test_begin "Must-fail checks"

# These commands should fail -- verify they do
e2e_run_must_fail "Sync to unknown host should fail" \
    "aba -d mirror sync -H unknown.example.com --retry 2>/dev/null"

e2e_run_must_fail "Install to localhost (no mirror on localhost) should fail" \
    "aba -d mirror install 2>/dev/null"

test_end 0

# ============================================================================
# 5. Save images to disk
# ============================================================================
test_begin "Save images to disk"

e2e_run -r 15 3 "Save images" "aba -d mirror save --retry"

e2e_run "Show saved files" "ls -lh mirror/save/ || true"

test_end 0

# ============================================================================
# 6. Tar-pipe transfer to bastion
# ============================================================================
test_begin "Tar-pipe transfer to bastion"

e2e_run -r 3 3 "Pipe tar to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xvf -'"

test_end 0

# ============================================================================
# 7. Load images into existing registry
# ============================================================================
test_begin "Load images into existing registry"

e2e_run_remote -r 15 3 "Load images into registry" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 8. Install SNO cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_run_remote "Create SNO cluster" \
    "cd ~/aba && aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run_remote "Verify cluster operators" \
    "cd ~/aba && aba --dir sno run"
e2e_run_remote "Check cluster operators" \
    "cd ~/aba && aba --dir sno cmd 'oc get co'"

test_end 0

# ============================================================================
# 9. Deploy vote-app
# ============================================================================
test_begin "Deploy vote-app"

e2e_run_remote "Deploy vote-app" \
    "cd ~/aba && test/deploy-test-app.sh"

test_end 0

# ============================================================================
# 10. ACM: install operators
# ============================================================================
test_begin "ACM: install operators"

# Add ACM operator to imageset and sync
e2e_run "Set op_sets=acm" "aba --op-sets acm"
e2e_run -r 15 3 "Save ACM images" "aba -d mirror save --retry"
e2e_run -r 3 3 "Pipe ACM tar to bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'cd ~/aba && tar xvf -'"
e2e_run_remote -r 15 3 "Load ACM images" \
    "cd ~/aba && aba -d mirror load --retry"

test_end 0

# ============================================================================
# 11. ACM: MultiClusterHub
# ============================================================================
test_begin "ACM: MultiClusterHub"

e2e_run_remote "Install ACM subscription" \
    "cd ~/aba && aba --dir sno cmd 'oc apply -f test/acm-subs.yaml'"
e2e_run_remote -r 10 3 "Wait for ACM operator" \
    "cd ~/aba && aba --dir sno cmd 'oc get csv -n open-cluster-management -o name | grep advanced-cluster-management'"
e2e_run_remote "Install MultiClusterHub" \
    "cd ~/aba && aba --dir sno cmd 'oc apply -f test/acm-mch.yaml'"
e2e_run_remote -r 20 3 "Wait for MCH ready" \
    "cd ~/aba && aba --dir sno cmd 'oc get multiclusterhub -n open-cluster-management -o jsonpath={.items[0].status.phase} | grep Running'"

test_end 0

# ============================================================================
# 12. NTP: day2 configuration and chronyc verify
# ============================================================================
test_begin "NTP: day2 and chronyc verify"

e2e_run_remote "Apply day2 NTP config" \
    "cd ~/aba && aba --dir sno day2-ntp"
e2e_run_remote -r 5 3 "Verify chronyc sources" \
    "cd ~/aba && aba --dir sno cmd 'oc debug node/\$(oc get nodes -o name | head -1 | cut -d/ -f2) -- chroot /host chronyc sources' | grep $NTP_IP"

test_end 0

# ============================================================================
# 13. Shutdown
# ============================================================================
test_begin "Shutdown cluster"

e2e_run_remote -i "Shutdown SNO cluster" \
    "cd ~/aba && yes | aba --dir sno shutdown --wait"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-airgapped-existing-reg.sh"
