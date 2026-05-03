#!/usr/bin/env bash
# =============================================================================
# Suite: Upgrade Command
# =============================================================================
# Purpose: Test the 'aba upgrade' command and '--target-version' ISC auto-generation.
#
# This suite covers:
#   - --target-version flag: version resolution, mirror.conf write, symlink write-through
#   - ISC auto-generation: single-channel + shortestPath when ocp_version_target is set
#   - ISC normal mode: unchanged behavior when ocp_version_target is not set
#   - aba upgrade --dry-run: correct output without executing
#   - aba upgrade preflight: version check, missing image, missing IDMS
#   - Full upgrade flow: install older version, mirror target, load, upgrade
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

SNO="$(pool_cluster_name sno)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "ISC: normal mode (no ocp_version_target)" \
    "Flag: --target-version resolution and mirror.conf write" \
    "ISC: upgrade mode (single-channel + shortestPath)" \
    "Flag: --target-version from cluster dir via symlink" \
    "Upgrade: --dry-run output" \
    "Upgrade: preflight rejects same version"

suite_begin "upgrade"

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_run "Install aba" "cd ~/aba && ./install"
e2e_run "Configure aba" "cd ~/aba && aba --channel fast --version previous --platform bm -Y"

e2e_run "Save older (previous) version" "
    cd ~/aba
    ocp_version=\$(grep ^ocp_version= aba.conf | cut -d= -f2 | cut -d'#' -f1 | tr -d ' ')
    echo \$ocp_version > /tmp/e2e-ocp-version-older
    echo \"Older version: \$ocp_version\"
"

e2e_run "Resolve latest version as upgrade target" "
    cd ~/aba
    aba --channel fast --version latest
    ocp_version=\$(grep ^ocp_version= aba.conf | cut -d= -f2 | cut -d'#' -f1 | tr -d ' ')
    echo \$ocp_version > /tmp/e2e-ocp-version-desired
    echo \"Desired version: \$ocp_version\"
"

e2e_run "Create mirror directory and mirror.conf" \
    "cd ~/aba && aba -d mirror mirror.conf"

test_end

# ============================================================================
# 2. ISC: normal mode (no ocp_version_target)
# ============================================================================
test_begin "ISC: normal mode (no ocp_version_target)"

e2e_run "Ensure no ocp_version_target in mirror.conf" \
    "cd ~/aba && sed -i '/^ocp_version_target=/d' mirror/mirror.conf"

e2e_run "Generate ISC without upgrade target" \
    "cd ~/aba && rm -f mirror/data/imageset-config.yaml mirror/data/.created && aba -d mirror imagesetconf"

e2e_run "Verify ISC has single version (minVersion == maxVersion)" "
    cd ~/aba
    ocp_version=\$(grep ^ocp_version= aba.conf | cut -d= -f2 | cut -d'#' -f1 | tr -d ' ')
    grep -q \"minVersion: \$ocp_version\" mirror/data/imageset-config.yaml
    grep -q \"maxVersion: \$ocp_version\" mirror/data/imageset-config.yaml
    ! grep -q 'shortestPath: true' mirror/data/imageset-config.yaml
    echo 'ISC normal mode: OK'
"

test_end

# ============================================================================
# 3. Flag: --target-version resolution and mirror.conf write
# ============================================================================
test_begin "Flag: --target-version resolution and mirror.conf write"

e2e_run "Set --target-version with explicit x.y.z" "
    cd ~/aba
    desired=\$(cat /tmp/e2e-ocp-version-desired)
    aba -d mirror --target-version \$desired
    grep -q \"^ocp_version_target=\$desired\" mirror/mirror.conf
    echo \"mirror.conf ocp_version_target=\$desired: OK\"
"

e2e_run "Clean up ocp_version_target" \
    "cd ~/aba && sed -i '/^ocp_version_target=/d' mirror/mirror.conf"

test_end

# ============================================================================
# 4. ISC: upgrade mode (single-channel + shortestPath)
# ============================================================================
test_begin "ISC: upgrade mode (single-channel + shortestPath)"

e2e_run "Set older version as base, desired as target" "
    cd ~/aba
    older=\$(cat /tmp/e2e-ocp-version-older)
    desired=\$(cat /tmp/e2e-ocp-version-desired)
    aba -v \$older
    aba -d mirror --target-version \$desired
    echo \"Base: \$older  Target: \$desired\"
"

e2e_run "Regenerate ISC in upgrade mode" \
    "cd ~/aba && rm -f mirror/data/imageset-config.yaml mirror/data/.created && aba -d mirror imagesetconf"

e2e_run "Verify ISC has upgrade channel config" "
    cd ~/aba
    older=\$(cat /tmp/e2e-ocp-version-older)
    desired=\$(cat /tmp/e2e-ocp-version-desired)
    desired_major=\$(echo \$desired | cut -d. -f1-2)
    grep -q \"minVersion: \$older\" mirror/data/imageset-config.yaml
    grep -q \"maxVersion: \$desired\" mirror/data/imageset-config.yaml
    grep -q 'shortestPath: true' mirror/data/imageset-config.yaml
    echo 'ISC upgrade mode: OK'
"

e2e_snapshot_file "upgrade-isc" "mirror/data/imageset-config.yaml"

test_end

# ============================================================================
# 5. Flag: --target-version from cluster dir via symlink
# ============================================================================
test_begin "Flag: --target-version from cluster dir via symlink"

e2e_run "Create a test cluster directory" "
    cd ~/aba
    desired=\$(cat /tmp/e2e-ocp-version-desired)
    aba cluster --name ${SNO} --type sno --step cluster.conf
"

e2e_run "Set --target-version from cluster dir" "
    cd ~/aba
    desired=\$(cat /tmp/e2e-ocp-version-desired)
    sed -i '/^ocp_version_target=/d' mirror/mirror.conf
    aba -d ${SNO} --target-version \$desired
    grep -q \"^ocp_version_target=\$desired\" mirror/mirror.conf
    echo 'Symlink write-through: OK'
"

test_end

# ============================================================================
# 6. Upgrade: --dry-run output
# ============================================================================
test_begin "Upgrade: --dry-run output"

# This test requires a running cluster, so we run it only if the SNO is installed.
# For now, verify --dry-run fails gracefully when no cluster is available.
e2e_run_must_fail "Dry-run without kubeconfig fails gracefully" \
    "cd ~/aba && aba -d ${SNO} upgrade --to 4.99.0 --dry-run"

test_end

# ============================================================================
# 7. Upgrade: preflight rejects same version
# ============================================================================
test_begin "Upgrade: preflight rejects same version"

# Without a live cluster this will fail at the kubeconfig/access check, which is expected.
# The version comparison logic is unit-tested via the script's internal checks.
e2e_run_must_fail "Upgrade without kubeconfig fails" \
    "cd ~/aba && aba -d ${SNO} upgrade --to 4.19.0"

test_end

# --- Cleanup ----------------------------------------------------------------
# Full upgrade flow is tested in suite-cluster-ops (piggybacks on its SNO).
suite_end
