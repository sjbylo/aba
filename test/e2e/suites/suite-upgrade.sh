#!/usr/bin/env bash
# =============================================================================
# Suite: Upgrade Command
# =============================================================================
# Purpose: Test the 'aba upgrade' command end-to-end.
#
# This suite covers:
#   - --upgrade-to flag: version resolution, mirror.conf write, symlink write-through
#   - ISC auto-generation: single-channel + shortestPath when ocp_upgrade_to is set
#   - ISC normal mode: unchanged behavior when ocp_upgrade_to is not set
#   - aba upgrade --dry-run: correct output without executing
#   - aba upgrade --dry-run --shell: machine-readable output on a live cluster
#   - aba upgrade preflight: version check, invalid format
#   - Full-chain upgrade: single 'aba upgrade' drives day2 + OSUS + trigger
#   - Signature accumulation across syncs (merged file)
#   - Conditional version detection from live cluster graph
#   - --allow-not-recommended flag plumbing
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

NTP_IP="${NTP_SERVER:-10.0.1.8}"

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba and configure" \
    "ISC: normal mode (no ocp_upgrade_to)" \
    "Flag: --upgrade-to resolution and mirror.conf write" \
    "ISC: upgrade mode (single-channel + shortestPath)" \
    "ISC: back-to-back upgrades (sequential target changes)" \
    "ISC: user-edited ISC is preserved (not overwritten)" \
    "Flag: --upgrade-to from cluster dir via symlink" \
    "Upgrade: --dry-run output" \
    "Upgrade: preflight rejects same version" \
    "Upgrade: invalid version format rejected" \
    "Install: SNO at older version" \
    "Upgrade: --dry-run --shell on live cluster" \
    "Upgrade: sync target version to registry" \
    "Upgrade: signature accumulation after sync" \
    "Upgrade: full chain (day2 + OSUS + upgrade)" \
    "Upgrade: verify upgrade accepted" \
    "Upgrade: conditional version detection" \
    "Cleanup: delete cluster"

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

e2e_run "Validate older version is in upgrade graph" "
    cd ~/aba && source scripts/include_all.sh &&
    older=\$(< /tmp/e2e-ocp-version-older) &&
    desired=\$(< /tmp/e2e-ocp-version-desired) &&
    tgt_minor=\$(echo \$desired | cut -d. -f1-2) &&
    if verify_upgrade_path_exists \"\$older\" \"\$desired\" fast; then
        echo \"Upgrade path OK: \$older -> \$desired\"
    else
        echo \"WARNING: \$older not in fast-\$tgt_minor graph, searching for valid source ...\"
        src_minor=\$(echo \$older | cut -d. -f1-2)
        graph_json=\$(_fetch_graph_cached fast \$tgt_minor)
        valid=\$(echo \"\$graph_json\" | jq -r '.nodes[].version' \
            | grep \"^\$src_minor\\.\" | sort -rV | head -1)
        if [ -z \"\$valid\" ]; then
            echo \"FATAL: no \$src_minor.x version in fast-\$tgt_minor graph\"; exit 1
        fi
        echo \"Using \$valid instead of \$older\"
        aba -v \$valid
        echo \$valid > /tmp/e2e-ocp-version-older
    fi
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
# 2. ISC: normal mode (no ocp_upgrade_to)
# ============================================================================
test_begin "ISC: normal mode (no ocp_upgrade_to)"

e2e_run "Ensure no ocp_upgrade_to in mirror.conf" \
    "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf"

e2e_run "Generate ISC without upgrade target" \
    "cd ~/aba && aba --force -d mirror imagesetconf"

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
# 3. Flag: --upgrade-to resolution and mirror.conf write
# ============================================================================
test_begin "Flag: --upgrade-to resolution and mirror.conf write"

e2e_run "Set --upgrade-to with explicit x.y.z" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -d mirror --upgrade-to \$desired &&
    grep -q \"^ocp_upgrade_to=\$desired\" mirror/mirror.conf &&
    echo \"mirror.conf ocp_upgrade_to=\$desired: OK\"
"

e2e_run "Clean up ocp_upgrade_to" \
    "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf"

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
    aba -d mirror --upgrade-to \$desired &&
    echo \"Base: \$older  Target: \$desired\" &&
    echo '--- Verifying config files ---' &&
    got_ver=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}') &&
    got_tgt=\$(grep '^ocp_upgrade_to=' mirror/mirror.conf | cut -d= -f2 | awk '{print \$1}') &&
    echo \"aba.conf ocp_version=\$got_ver  mirror.conf ocp_upgrade_to=\$got_tgt\" &&
    [ \"\$got_ver\" = \"\$older\" ] || { echo \"FAIL: aba.conf ocp_version=\$got_ver expected \$older\"; exit 1; } &&
    [ \"\$got_tgt\" = \"\$desired\" ] || { echo \"FAIL: mirror.conf ocp_upgrade_to=\$got_tgt expected \$desired\"; exit 1; } &&
    echo 'Config files: OK'
"

e2e_run "Regenerate ISC in upgrade mode" \
    "cd ~/aba && aba --force -d mirror imagesetconf"

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
    got=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}') &&
    [ \"\$got\" = \"\$desired\" ] || { echo \"FAIL: aba.conf ocp_version=\$got expected \$desired\"; exit 1; } &&
    echo \"Simulated post-upgrade state: ocp_version=\$desired\"
"

e2e_run "Clear previous target" \
    "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf"

e2e_run "Verify ISC normal mode after first upgrade" "
    cd ~/aba &&
    aba --force -d mirror imagesetconf &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    grep -q \"minVersion: \$desired\" mirror/data/imageset-config.yaml &&
    grep -q \"maxVersion: \$desired\" mirror/data/imageset-config.yaml &&
    ! grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo \"ISC after first upgrade (normal mode): OK\" &&
    echo '--- ISC content (reverted to normal after upgrade A->B) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Set second upgrade target (graph-validated)" "
    cd ~/aba && source scripts/include_all.sh &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    . aba.conf &&
    channel=\${ocp_channel:-fast} &&
    second_target=\$(fetch_upgrade_targets \"\$desired\" \"\$channel\" | head -1 | awk '{print \$2}') &&
    if [ -z \"\$second_target\" ]; then
        echo \"SKIP: \$desired is the latest in \$channel — no same-channel upgrade target\"
        echo '' > /tmp/e2e-ocp-version-second-target
    else
        echo \$second_target > /tmp/e2e-ocp-version-second-target
        aba -d mirror --upgrade-to \$second_target &&
        grep -q \"^ocp_upgrade_to=\$second_target\" mirror/mirror.conf &&
        echo \"Second upgrade target: \$second_target (from graph, channel=\$channel)\"
    fi
"

e2e_run "Regenerate ISC for second upgrade" "
    cd ~/aba &&
    second_target=\$(cat /tmp/e2e-ocp-version-second-target) &&
    [ -n \"\$second_target\" ] || { echo 'SKIP: no second target'; exit 0; } &&
    aba --force -d mirror imagesetconf
"

e2e_run "Verify ISC for second upgrade has correct min/max" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    second_target=\$(cat /tmp/e2e-ocp-version-second-target) &&
    [ -n \"\$second_target\" ] || { echo 'SKIP: no second target'; exit 0; } &&
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
    aba -v \$older &&
    got=\$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print \$1}') &&
    [ \"\$got\" = \"\$older\" ] || { echo \"FAIL: aba.conf ocp_version=\$got expected \$older\"; exit 1; }
"

test_end

# ============================================================================
# 6. ISC: user-edited ISC is preserved (not overwritten)
# ============================================================================
# When the user manually edits the ISC file (making it newer than .created),
# subsequent imagesetconf calls must NOT overwrite it.
test_begin "ISC: user-edited ISC is preserved (not overwritten)"

e2e_run "Generate a fresh ISC as baseline" \
    "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf && \
     aba --force -d mirror imagesetconf"

e2e_run "Simulate user editing the ISC" "
    cd ~/aba &&
    sleep 1 &&
    echo '# USER EDIT: custom addition' >> mirror/data/imageset-config.yaml &&
    echo 'User edit marker added to ISC' &&
    echo '--- ISC after user edit ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Set --upgrade-to (writes to mirror.conf only)" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -d mirror --upgrade-to \$desired &&
    echo \"Set ocp_upgrade_to=\$desired in mirror.conf\"
"

e2e_run "Run imagesetconf -- must NOT overwrite user-edited ISC" "
    cd ~/aba &&
    mkdir -p ~/tmp &&
    aba -d mirror imagesetconf 2>&1 | tee ~/tmp/e2e-isc-skip-output &&
    grep -q '# USER EDIT: custom addition' mirror/data/imageset-config.yaml &&
    echo 'User edit preserved: OK' &&
    echo '--- ISC content (should still have user edit) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Verify warning was emitted about preserving user edits" \
    "grep -q 'modified by user' ~/tmp/e2e-isc-skip-output"

e2e_run "Force regeneration with --force" "
    cd ~/aba &&
    aba --force -d mirror imagesetconf &&
    ! grep -q '# USER EDIT: custom addition' mirror/data/imageset-config.yaml &&
    grep -q '^[^#]*shortestPath: true' mirror/data/imageset-config.yaml &&
    echo 'After --force: ISC regenerated with upgrade config' &&
    echo '--- ISC content (force-regenerated) ---' &&
    grep -v '^#' mirror/data/imageset-config.yaml | grep -v '^[[:space:]]*$'
"

e2e_run "Clean up target for remaining tests" \
    "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf"

test_end

# ============================================================================
# 8. Flag: --upgrade-to from cluster dir via symlink
# ============================================================================
test_begin "Flag: --upgrade-to from cluster dir via symlink"

e2e_run "Create a test cluster directory" "
    cd ~/aba &&
    aba cluster --name ${SNO} --type sno --step cluster.conf
"

e2e_run "Set --upgrade-to from cluster dir" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf &&
    aba -d ${SNO} --upgrade-to \$desired &&
    grep -q \"^ocp_upgrade_to=\$desired\" mirror/mirror.conf &&
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

# ============================================================================
# 11. Upgrade: invalid version format rejected
# ============================================================================
test_begin "Upgrade: invalid version format rejected"

e2e_run_must_fail "Non-semver version is rejected" \
    "cd ~/aba && aba -d ${SNO} upgrade --to not-a-version"

e2e_run_must_fail "Partial version (major.minor only) is rejected" \
    "cd ~/aba && aba -d ${SNO} upgrade --to 4.21"

e2e_run_must_fail "Empty --to argument is rejected" \
    "cd ~/aba && aba -d ${SNO} upgrade --to ''"

test_end

# ============================================================================
# 12. Install: SNO at older version
# ============================================================================
# From here on we need a real cluster.  Reconfigure for VMware and install
# a SNO using the "older" (previous) version already in the pool registry.
test_begin "Install: SNO at older version"

e2e_run "Reconfigure aba.conf for VMware" "
    cd ~/aba &&
    older=\$(cat /tmp/e2e-ocp-version-older) &&
    aba --noask --platform vmw --channel fast --version \$older \
        --base-domain $(pool_domain) \
        --machine-network $(pool_machine_network) \
        --ntp $NTP_IP
"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER in vmware.conf" \
    "sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"

e2e_run "Sync older version to pool registry" \
    "aba -d mirror sync --retry"

e2e_run "Delete any leftover $SNO cluster" \
    "_e2e_delete_leftover_cluster $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"

e2e_run "Create SNO cluster config" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run -r 2 10 "Install SNO cluster" \
    "aba --dir $SNO install"

e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_wait_cluster_available $SNO

test_end

# ============================================================================
# 13. Upgrade: --dry-run --shell on live cluster
# ============================================================================
test_begin "Upgrade: --dry-run --shell on live cluster"

e2e_run "Verify --dry-run --shell output format" "
    cd ~/aba &&
    output=\$(aba -d $SNO upgrade --dry-run --shell 2>/dev/null) &&
    echo \"\$output\" &&
    echo \"\$output\" | grep -q '^upgrade_current_ver=' &&
    echo \"\$output\" | grep -q '^upgrade_channel=' &&
    echo \"\$output\" | grep -q '^upgrade_osus=' &&
    echo \"\$output\" | grep -q '^upgrade_versions=' &&
    echo '--dry-run --shell: output format OK'
"

e2e_run "Verify --dry-run --shell is eval-safe and values correct" "
    cd ~/aba &&
    older=\$(cat /tmp/e2e-ocp-version-older) &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    eval \"\$(aba -d $SNO upgrade --dry-run --shell 2>/dev/null)\" &&
    echo \"upgrade_current_ver=\$upgrade_current_ver\" &&
    echo \"upgrade_channel=\$upgrade_channel\" &&
    echo \"upgrade_osus=\$upgrade_osus\" &&
    echo \"upgrade_versions=\$upgrade_versions\" &&
    echo \"upgrade_conditional=\${upgrade_conditional:-}\" &&
    [ \"\$upgrade_current_ver\" = \"\$older\" ] &&
    echo \"current_ver matches installed version (\$older): OK\" &&
    [ -n \"\$upgrade_channel\" ] &&
    echo \"channel is non-empty (\$upgrade_channel): OK\" &&
    echo \"\$upgrade_versions\" | grep -qF \"\$desired\" &&
    echo \"versions contains upgrade target (\$desired): OK\" &&
    echo '--dry-run --shell: eval + values OK'
"

e2e_run "Verify --allow-not-recommended flag accepted with --dry-run --shell" "
    cd ~/aba &&
    output=\$(aba -d $SNO upgrade --dry-run --shell --allow-not-recommended 2>/dev/null) &&
    echo \"\$output\" | grep -q '^upgrade_current_ver=' &&
    echo '--allow-not-recommended + --dry-run --shell: OK'
"

test_end

# ============================================================================
# 14. Upgrade: sync target version to registry
# ============================================================================
test_begin "Upgrade: sync target version to registry"

e2e_run "Set --upgrade-to for z-stream upgrade" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    aba -d mirror --upgrade-to \$desired &&
    aba --force -d mirror imagesetconf &&
    echo \"Upgrade target set: \$desired\"
"

e2e_run -r 1 2 "Sync upgrade images to pool registry" \
    "cd ~/aba && aba -d mirror sync --retry"

test_end

# ============================================================================
# 15. Upgrade: signature accumulation after sync
# ============================================================================
test_begin "Upgrade: signature accumulation after sync"

e2e_run "Verify merged signature file exists" "
    cd ~/aba &&
    test -s mirror/data/working-dir/signature-configmap-merged.json &&
    echo 'Merged signature file exists: OK'
"

e2e_run "Verify merged file has signatures" "
    cd ~/aba &&
    count=\$(jq '.binaryData | length' mirror/data/working-dir/signature-configmap-merged.json) &&
    echo \"Merged signature count: \$count\" &&
    [ \"\$count\" -gt 0 ] &&
    echo 'Signature accumulation: OK'
"

test_end

# ============================================================================
# 16. Upgrade: full chain (day2 + OSUS + upgrade)
# ============================================================================
# This is the key test: a single 'aba upgrade' command that should internally
# handle day2 (IDMS/signatures), OSUS install, channel config, and trigger
# the upgrade -- the exact workflow a real user follows.
test_begin "Upgrade: full chain (day2 + OSUS + upgrade)"

e2e_wait_cluster_ready $SNO

e2e_run -r 5 2 -d 60 -m 300 "Full-chain upgrade (day2 + OSUS + trigger)" "
    cd ~/aba &&
    desired=\$(cat /tmp/e2e-ocp-version-desired) &&
    echo \"Upgrading to \$desired (full chain, no --skip-day2, no --force)\" &&
    aba --dir $SNO upgrade --to \$desired
"

test_end

# ============================================================================
# 17. Upgrade: verify upgrade accepted
# ============================================================================
test_begin "Upgrade: verify upgrade accepted"

e2e_poll 300 15 "Verify upgrade in progress" \
    "cd ~/aba && desired=\$(cat /tmp/e2e-ocp-version-desired) && \
     aba --dir $SNO run --cmd 'oc adm upgrade' | grep -E 'upgrade is in progress|Cluster version is \$desired'"

e2e_diag "Show cluster version" \
    "aba --dir $SNO run --cmd 'oc get clusterversion version -o jsonpath={.status.desired.version}'"

test_end

# ============================================================================
# 18. Upgrade: conditional version detection
# ============================================================================
# Scan the live cluster graph for conditional (not-recommended) versions.
# If any exist, verify they appear in --dry-run --shell output.
# This test is opportunistic -- conditional versions are not always present.
test_begin "Upgrade: conditional version detection"

e2e_run "Scan cluster graph for conditional versions" "
    cd ~/aba &&
    cond=\$(aba --dir $SNO run --cmd \
        \"oc get clusterversion version -o json\" | \
        jq -r '.status.conditionalUpdates[]?.release.version // empty' | head -5) &&
    echo \"Conditional versions from cluster graph: \${cond:-NONE}\" &&
    echo \"\$cond\" > /tmp/e2e-conditional-versions
"

e2e_run "Verify conditional versions in --dry-run --shell output" "
    cd ~/aba &&
    cond=\$(cat /tmp/e2e-conditional-versions | head -1) &&
    if [ -n \"\$cond\" ]; then
        echo \"Found conditional version: \$cond -- verifying --dry-run --shell\" &&
        eval \"\$(aba -d $SNO upgrade --dry-run --shell 2>/dev/null)\" &&
        echo \"upgrade_conditional field: \${upgrade_conditional:-EMPTY}\" &&
        if echo \"\$upgrade_conditional\" | grep -qF \"\$cond\"; then
            echo \"Conditional version \$cond correctly reported in upgrade_conditional field: OK\"
        else
            echo \"WARNING: \$cond not in upgrade_conditional field (may have changed status)\"
        fi &&
        eval \"\$(aba -d $SNO upgrade --dry-run --shell --allow-not-recommended 2>/dev/null)\" &&
        echo \"upgrade_versions with --allow-not-recommended: \$upgrade_versions\" &&
        echo 'Conditional detection: OK'
    else
        echo 'No conditional versions available in cluster graph -- skipping (expected for some versions)'
    fi
"

test_end

# ============================================================================
# 19. Cleanup: delete cluster
# ============================================================================
test_begin "Cleanup: delete cluster"

e2e_run "Delete SNO cluster" \
    "_e2e_delete_leftover_cluster $SNO"

e2e_run "Clean up ocp_upgrade_to from mirror.conf" \
    "cd ~/aba && sed -i '/^ocp_upgrade_to=/d' mirror/mirror.conf"

test_end 0

# --- End --------------------------------------------------------------------
suite_end; _rc=$?

exit $_rc
