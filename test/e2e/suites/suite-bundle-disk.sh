#!/bin/bash
# =============================================================================
# Suite: Bundle to Disk (rewrite of test4)
# =============================================================================
# Purpose: Create bundles (light and full) and verify their contents.
#          No cluster install needed -- this is the leanest test.
# =============================================================================

set -euo pipefail

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Light bundle: create with operators" \
    "Light bundle: verify contents" \
    "Full bundle: create without operator filters" \
    "Full bundle: verify contents"

suite_begin "bundle-disk"

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch --platform vmw

e2e_run "Install aba" "./install"

# Use VER_OVERRIDE=p (previous) for version diversity with other suites
e2e_run "Configure aba.conf" \
    "aba --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-p}"
e2e_run "Show ocp_version" "grep -o '^ocp_version=[^ ]*' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

# Create mirror dir and conf for bundle operations
e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"

# Read the configured version for bundle creation
e2e_run "Source aba.conf" "source <(normalize-aba-conf) && echo ocp_version=\$ocp_version"

test_end 0

# ============================================================================
# 2. Light bundle: create with specific operators
# ============================================================================
test_begin "Light bundle: create with operators"

e2e_run "Create temp dir" "mkdir -v -p ~/tmp"
e2e_run "Clean previous bundles" "rm -fv ~/tmp/delete-me*tar"

e2e_run -r 3 3 "Create light bundle with operators" \
    "source <(normalize-aba-conf) && aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel ${TEST_CHANNEL:-stable} --version \$ocp_version --op-sets abatest --ops web-terminal yaks nginx-ingress-operator flux --base-domain example.com -o ~/tmp/delete-me -y"

test_end 0

# ============================================================================
# 3. Light bundle: verify contents
# ============================================================================
test_begin "Light bundle: verify contents"

e2e_run "Show tar file size" "ls -l ~/tmp/delete-me*tar"
e2e_run "Show tar file size (human)" "ls -lh ~/tmp/delete-me*tar"
e2e_run "List tar contents" "tar tvf ~/tmp/delete-me*tar"
e2e_run "Clean up light bundle" "rm -fv ~/tmp/delete-me*tar"

test_end 0

# ============================================================================
# 4. Full bundle: create without operator filters
# ============================================================================
test_begin "Full bundle: create without operator filters"

e2e_run "Clean previous bundles" "rm -fv /tmp/delete-me*tar"

e2e_run -r 3 3 "Create full bundle (all operators)" \
    "source <(normalize-aba-conf) && aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel ${TEST_CHANNEL:-stable} --version \$ocp_version --op-sets --ops --base-domain example.com -o /tmp/delete-me -y"

test_end 0

# ============================================================================
# 5. Full bundle: verify contents
# ============================================================================
test_begin "Full bundle: verify contents"

e2e_run "Show tar file size" "ls -l /tmp/delete-me*tar"
e2e_run "Show tar file size (human)" "ls -lh /tmp/delete-me*tar"
e2e_run "List tar contents" "tar tvf /tmp/delete-me*tar"
e2e_run "Verify mirror_000001.tar in bundle" \
    "tar tvf /tmp/delete-me*tar | grep mirror/save/mirror_000001.tar"
e2e_run "Clean up full bundle" "rm -fv /tmp/delete-me*tar"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-bundle-disk.sh"
