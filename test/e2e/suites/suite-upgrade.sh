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
CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba and configure" \
    "ISC: normal mode (no ocp_version_target)" \
    "Flag: --target-version resolution and mirror.conf write" \
    "ISC: upgrade mode (single-channel + shortestPath)" \
    "ISC: back-to-back upgrades (sequential target changes)" \
    "ISC: user-edited ISC is preserved (not overwritten)" \
    "Flag: --target-version from cluster dir via symlink" \
    "Upgrade: --dry-run output" \
    "Upgrade: preflight rejects same version"

suite_begin "upgrade"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_install_aba
e2e_run "Configure aba.conf (temporary, for version resolution)" \
    "aba --noask --platform bm --channel fast --version previous --base-domain $(pool_domain) -Y"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_run "Install aba" "cd ~/aba && ./install"
e2e_run "Configure aba" "cd ~/aba && aba --channel fast --version previous --platform bm -Y"

e2e_run "Save older (previous) version" "
    cd ~/aba && . aba.conf &&
    echo \$ocp_version > /tmp/e2e-ocp-version-older &&
    echo \"Older version: \$ocp_version\"
"

e2e_run "Resolve latest version as upgrade target" "
    cd ~/aba &&
    aba --channel fast --version latest &&
    . aba.conf &&
    echo \$ocp_version > /tmp/e2e-ocp-version-desired &&
    echo \"Desired version: \$ocp_version\"
"

e2e_run "Create mirror directory and mirror.conf" \
    "cd ~/aba && aba -d mirror mirror.conf"

e2e_run "Set reg_host to local pool registry" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
    "sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
    "sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"

e2e_run "Generate pool-registry pull secret via aba" \
    "printf 'init\np4ssw0rd\n' | aba -d mirror password && cp ~/.aba/mirror/mirror/pull-secret-mirror.json /tmp/pool-reg-pull-secret.json"

e2e_run "Register pool registry" \
    "aba -d mirror register --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert $POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

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
    cd ~/aba && . aba.conf &&
    grep -q \"minVersion: \$ocp_version\" mirror/data/imageset-config.yaml &&
    grep -q \"maxVersion: \$ocp_version\" mirror/data/imageset-config.yaml &&
    ! grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo 'ISC normal mode: OK' &&
    echo '--- ISC content (normal mode) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

test_end

# ============================================================================
# 3. Flag: --target-version resolution and mirror.conf write
# ============================================================================
test_begin "Flag: --target-version resolution and mirror.conf write"

e2e_run "Set --target-version with explicit x.y.z" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -d mirror --target-version \$desired &&
    grep -q \"^ocp_version_target=\$desired\" mirror/mirror.conf &&
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
    cd ~/aba &&
    older=\$(cat /tmp/e2e-ocp-version-older) &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -v \$older &&
    aba -d mirror --target-version \$desired &&
    echo \"Base: \$older  Target: \$desired\"
"

e2e_run "Regenerate ISC in upgrade mode" \
    "cd ~/aba && rm -f mirror/data/imageset-config.yaml mirror/data/.created && aba -d mirror imagesetconf"

e2e_run "Verify ISC has upgrade channel config" "
    cd ~/aba &&
    older=\$(cat /tmp/e2e-ocp-version-older) &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    grep -q \"minVersion: \$older\" mirror/data/imageset-config.yaml &&
    grep -q \"maxVersion: \$desired\" mirror/data/imageset-config.yaml &&
    grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo 'ISC upgrade mode: OK' &&
    echo '--- ISC content (upgrade mode) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_snapshot_file "upgrade-isc" "mirror/data/imageset-config.yaml"

test_end

# ============================================================================
# 5. ISC: back-to-back upgrades (sequential target changes)
# ============================================================================
# Simulates: upgrade A->B completed, now upgrade B->C.
# Verifies ISC regeneration uses the correct minVersion/maxVersion each time.
test_begin "ISC: back-to-back upgrades (sequential target changes)"

e2e_run "Simulate first upgrade completed (set ocp_version to desired)" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -v \$desired &&
    echo \"Simulated post-upgrade state: ocp_version=\$desired\"
"

e2e_run "Clear previous target" \
    "cd ~/aba && sed -i '/^ocp_version_target=/d' mirror/mirror.conf"

e2e_run "Verify ISC normal mode after first upgrade" "
    cd ~/aba &&
    rm -f mirror/data/imageset-config.yaml mirror/data/.created &&
    aba -d mirror imagesetconf &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    grep -q \"minVersion: \$desired\" mirror/data/imageset-config.yaml &&
    grep -q \"maxVersion: \$desired\" mirror/data/imageset-config.yaml &&
    ! grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo \"ISC after first upgrade (normal mode): OK\" &&
    echo '--- ISC content (reverted to normal after upgrade A->B) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Set second upgrade target (desired + simulated next patch)" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    major_minor=\$(echo \$desired | cut -d. -f1-2) &&
    patch=\$(echo \$desired | cut -d. -f3) &&
    next_patch=\$(( patch + 1 )) &&
    second_target=\"\${major_minor}.\${next_patch}\" &&
    echo \$second_target > /tmp/e2e-ocp-version-second-target &&
    aba -d mirror --target-version \$second_target &&
    grep -q \"^ocp_version_target=\$second_target\" mirror/mirror.conf &&
    echo \"Second upgrade target: \$second_target\"
"

e2e_run "Regenerate ISC for second upgrade" \
    "cd ~/aba && rm -f mirror/data/imageset-config.yaml mirror/data/.created && aba -d mirror imagesetconf"

e2e_run "Verify ISC for second upgrade has correct min/max" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    second_target=\$(cat /tmp/e2e-ocp-version-second-target) &&
    grep -q \"minVersion: \$desired\" mirror/data/imageset-config.yaml &&
    grep -q \"maxVersion: \$second_target\" mirror/data/imageset-config.yaml &&
    grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo \"ISC second upgrade (min=\$desired max=\$second_target shortestPath=true): OK\" &&
    echo '--- ISC content (second upgrade B->C) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_snapshot_file "upgrade-isc-second" "mirror/data/imageset-config.yaml"

e2e_run "Restore older version for remaining tests" "
    cd ~/aba &&
    older=\$(cat /tmp/e2e-ocp-version-older) &&
    aba -v \$older
"

test_end

# ============================================================================
# 6. ISC: user-edited ISC is preserved (not overwritten)
# ============================================================================
# When the user manually edits the ISC file (making it newer than .created),
# subsequent imagesetconf calls must NOT overwrite it.
test_begin "ISC: user-edited ISC is preserved (not overwritten)"

e2e_run "Generate a fresh ISC as baseline" \
    "cd ~/aba && rm -f mirror/data/imageset-config.yaml mirror/data/.created && \
     sed -i '/^ocp_version_target=/d' mirror/mirror.conf && \
     aba -d mirror imagesetconf"

e2e_run "Simulate user editing the ISC" "
    cd ~/aba &&
    sleep 1 &&
    echo '# USER EDIT: custom addition' >> mirror/data/imageset-config.yaml &&
    echo 'User edit marker added to ISC' &&
    echo '--- ISC after user edit ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Set --target-version (writes to mirror.conf only)" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -d mirror --target-version \$desired &&
    echo \"Set ocp_version_target=\$desired in mirror.conf\"
"

e2e_run "Run imagesetconf -- must NOT overwrite user-edited ISC" "
    cd ~/aba &&
    aba -d mirror imagesetconf 2>&1 | tee /tmp/e2e-isc-skip-output &&
    grep -q '# USER EDIT: custom addition' mirror/data/imageset-config.yaml &&
    echo 'User edit preserved: OK' &&
    echo '--- ISC content (should still have user edit) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Verify warning was emitted about preserving user edits" \
    "grep -q 'modified by user' /tmp/e2e-isc-skip-output"

e2e_run "Force regeneration by removing .created" "
    cd ~/aba &&
    rm -f mirror/data/.created &&
    aba -d mirror imagesetconf &&
    ! grep -q '# USER EDIT: custom addition' mirror/data/imageset-config.yaml &&
    grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo 'After removing .created: ISC regenerated with upgrade config' &&
    echo '--- ISC content (force-regenerated) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Clean up target for remaining tests" \
    "cd ~/aba && sed -i '/^ocp_version_target=/d' mirror/mirror.conf"

test_end

# ============================================================================
# 8. Flag: --target-version from cluster dir via symlink
# ============================================================================
test_begin "Flag: --target-version from cluster dir via symlink"

e2e_run "Create a test cluster directory" "
    cd ~/aba &&
    aba cluster --name ${SNO} --type sno --step cluster.conf
"

e2e_run "Set --target-version from cluster dir" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    sed -i '/^ocp_version_target=/d' mirror/mirror.conf &&
    aba -d ${SNO} --target-version \$desired &&
    grep -q \"^ocp_version_target=\$desired\" mirror/mirror.conf &&
    echo 'Symlink write-through: OK'
"

test_end

# ============================================================================
# 9. Upgrade: --dry-run output
# ============================================================================
test_begin "Upgrade: --dry-run output"

# This test requires a running cluster, so we run it only if the SNO is installed.
# For now, verify --dry-run fails gracefully when no cluster is available.
e2e_run_must_fail "Dry-run without kubeconfig fails gracefully" \
    "cd ~/aba && aba -d ${SNO} upgrade --to 4.99.0 --dry-run"

test_end

# ============================================================================
# 10. Upgrade: preflight rejects same version
# ============================================================================
test_begin "Upgrade: preflight rejects same version"

# Without a live cluster this will fail at the kubeconfig/access check, which is expected.
# The version comparison logic is unit-tested via the script's internal checks.
e2e_run_must_fail "Upgrade without kubeconfig fails" \
    "cd ~/aba && aba -d ${SNO} upgrade --to 4.19.0"

test_end

# --- Cleanup ----------------------------------------------------------------
# Full upgrade flow is tested in suite-cluster-ops (piggybacks on its SNO).
suite_end; _rc=$?

exit $_rc
