#!/bin/bash
# =============================================================================
# Suite: Connected Public (rewrite of test3)
# =============================================================================
# Purpose: Install from public registry (no mirror). Test direct and proxy
#          internet modes. Verify install-config.yaml assertions.
#
# This is the simplest suite -- no mirror, no air-gap, no internal bastion.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"

# Pool-unique cluster names (avoid VM collisions when pools run in parallel)
SNO="$(pool_cluster_name sno)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Direct mode: create SNO config" \
    "Direct mode: verify install-config.yaml" \
    "Proxy mode: create SNO config" \
    "Proxy mode: install SNO cluster" \
    "Proxy mode: verify and shutdown"

suite_begin "connected-public"

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"

test_end

# ============================================================================
# 2. Direct mode: create SNO config with -I direct
# ============================================================================
test_begin "Direct mode: create SNO config"

e2e_run "Clean sno dir" "rm -rfv $SNO"
e2e_run "Create SNO config with -I direct" \
    "aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I direct --step cluster.conf"
e2e_run "Generate agent config" "aba -d $SNO agentconf"

test_end

# ============================================================================
# 3. Direct mode: verify install-config.yaml content
# ============================================================================
test_begin "Direct mode: verify install-config.yaml"

# Direct mode should NOT have mirror/digest sources or proxy config
assert_file_exists "$SNO/install-config.yaml"
e2e_run "Verify no ImageDigestSources in direct mode" \
    "! grep -q ImageDigestSources $SNO/install-config.yaml"
e2e_run "Verify no imageContentSources in direct mode" \
    "! grep -q imageContentSources $SNO/install-config.yaml"
e2e_run "Verify no additionalTrustBundle in direct mode" \
    "! grep -q additionalTrustBundle $SNO/install-config.yaml"
e2e_run "Verify public registry references" \
    "grep -q registry.redhat.io $SNO/install-config.yaml || grep -q quay.io $SNO/install-config.yaml"

test_end

# ============================================================================
# 4. Proxy mode: create SNO config with -I proxy
# ============================================================================
test_begin "Proxy mode: create SNO config"

e2e_run "Clean sno dir" "rm -rfv $SNO"
e2e_run "Create SNO config with -I proxy" \
    "aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"

test_end

# ============================================================================
# 5. Proxy mode: install SNO cluster from public registry
# ============================================================================
test_begin "Proxy mode: install SNO cluster"

e2e_run "Install SNO from public registry (proxy mode)" \
    "aba -d $SNO install"

test_end

# ============================================================================
# 6. Proxy mode: verify and shutdown
# ============================================================================
test_begin "Proxy mode: verify and shutdown"

e2e_run "Verify cluster operators" "aba --dir $SNO run"
e2e_run -r 180 10 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False\$' | wc -l | grep ^0\$"
e2e_run "Check cluster operators" "aba --dir $SNO cmd 'oc get co'"
e2e_run "Shutdown cluster" "yes | aba --dir $SNO shutdown --wait"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-connected-public.sh"
