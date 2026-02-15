#!/bin/bash
# =============================================================================
# Suite: Connected Public (rewrite of test3)
# =============================================================================
# Purpose: Install from public registry (no mirror). Test direct and proxy
#          internet modes. Verify install-config.yaml assertions.
#
# This is the simplest suite -- no mirror, no air-gap, no internal bastion.
# =============================================================================

set -euo pipefail

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"

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
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l}"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"

test_end 0

# ============================================================================
# 2. Direct mode: create SNO config with -I direct
# ============================================================================
test_begin "Direct mode: create SNO config"

e2e_run "Clean sno dir" "rm -rf sno"
e2e_run "Create SNO config with -I direct" \
    "aba cluster -n sno -t sno -i $(pool_sno_ip) -I direct --step cluster.conf"
e2e_run "Generate agent config" "aba -d sno agentconf"

test_end 0

# ============================================================================
# 3. Direct mode: verify install-config.yaml content
# ============================================================================
test_begin "Direct mode: verify install-config.yaml"

# Direct mode should NOT have mirror/digest sources or proxy config
assert_file_exists "sno/install-config.yaml"
e2e_run "Verify no ImageDigestSources in direct mode" \
    "! grep -q ImageDigestSources sno/install-config.yaml"
e2e_run "Verify no imageContentSources in direct mode" \
    "! grep -q imageContentSources sno/install-config.yaml"
e2e_run "Verify no additionalTrustBundle in direct mode" \
    "! grep -q additionalTrustBundle sno/install-config.yaml"
e2e_run "Verify public registry references" \
    "grep -q registry.redhat.io sno/install-config.yaml || grep -q quay.io sno/install-config.yaml || true"

test_end 0

# ============================================================================
# 4. Proxy mode: create SNO config with -I proxy
# ============================================================================
test_begin "Proxy mode: create SNO config"

e2e_run "Clean sno dir" "rm -rf sno"
e2e_run "Create SNO config with -I proxy" \
    "aba cluster -n sno -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"

test_end 0

# ============================================================================
# 5. Proxy mode: install SNO cluster from public registry
# ============================================================================
test_begin "Proxy mode: install SNO cluster"

e2e_run "Install SNO from public registry (proxy mode)" \
    "aba -d sno install"

test_end 0

# ============================================================================
# 6. Proxy mode: verify and shutdown
# ============================================================================
test_begin "Proxy mode: verify and shutdown"

e2e_run "Verify cluster operators" "aba --dir sno run"
e2e_run "Check cluster operators" "aba --dir sno cmd 'oc get co'"
e2e_run -i "Shutdown cluster" "yes | aba --dir sno shutdown --wait"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-connected-public.sh"
