#!/usr/bin/env bash
# =============================================================================
# Suite: Cluster Ops
# =============================================================================
# Purpose: ABI config generation, YAML validation against known-good examples,
#          SNO cluster install/verify, and operator availability check.
#          Uses a pre-populated mirror registry on conN (OCP images out-of-band)
#          and syncs operators via 'aba mirror sync' before cluster install.
#
# Prerequisite: Internet-connected host with aba installed.
#               Pre-populated Quay on conN (via setup-pool-registry.sh).
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-ops.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"
STANDARD="$(pool_cluster_name standard)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba and configure" \
    "Setup: configure mirror for local registry" \
    "Setup: sync operators to registry" \
    "ABI config: sno/compact/standard" \
    "ABI config: diff against known-good examples" \
    "SNO: install cluster" \
    "SNO: verify operators from all catalogs" \
    "SNO: IP conflict detection" \
    "verify_conf=conf skips network checks" \
    "Regression: verify_conf=conf extracts mirror binary" \
    "Upgrade: sync target and aba upgrade" \
    "Register: --reg-host and --reg-port CLI flags" \
    "Register: named mirror (enclave workflow)" \
    "Enclave: SNO install via named mirror" \
    "Cleanup: delete cluster and unregister mirror"

suite_begin "cluster-ops"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

# Resolve OCP version: use OCP_VERSION env or fall back to "p" (previous)
# We need the actual x.y.z version for the registry setup script.
e2e_install_aba
e2e_run "Configure aba.conf (temporary, for version resolution)" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

# Read the resolved x.y.z version from aba.conf
_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba and configure (lightweight -- no registry uninstall)
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_run "Remove oc-mirror caches" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"

e2e_run "Verify / available space > 200GB after reset" \
    "avail_gb=\$(df / --output=avail -BG | tail -1 | tr -d ' G'); echo \"[setup] / available: \${avail_gb}GB\"; [ \$avail_gb -gt 200 ]"

# Clean-start bootstrap: remove packages ABA must auto-reinstall (ported from old test1-5)
# || true: some packages may not be installed -- dnf returns non-zero if any are missing
e2e_run "Remove packages to test clean bootstrap" \
    "sudo dnf remove -y git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer --disableplugin=subscription-manager || true"

e2e_run "Install aba (must reinstall removed packages)" "./install"
e2e_run "Verify key tools restored" "which git make jq openssl skopeo hostname"
e2e_run "Install aba (verify idempotent)" "../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

# GAP 2: Verify aba auto-update mechanism (modifying scripts/aba.sh triggers re-install)
e2e_run "Auto-update: bump ABA_BUILD timestamp" \
    "new_v=\$(date +%Y%m%d%H%M%S) && sed -i \"s/^ABA_BUILD=.*/ABA_BUILD=\$new_v/g\" scripts/aba.sh && echo \$new_v > /tmp/e2e-aba-build-stamp"
e2e_run "Auto-update: run aba (triggers update)" \
    "aba -h | head -8"
e2e_run "Auto-update: verify installed binary has new build stamp" \
    "grep ^ABA_BUILD=\$(cat /tmp/e2e-aba-build-stamp) \$(which aba)"

e2e_run "Configure aba.conf" "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER in vmware.conf" "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Verify vmware.conf" "grep ^GOVC_URL= vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
# Operators verified after cluster install (one per catalog).
# The sync step (below) ensures these are actually in the registry.
e2e_run "Set test operators" "aba --ops cincinnati-operator nginx-ingress-operator flux"

e2e_run "Basic interactive test" "test/basic-interactive-test.sh"

e2e_run "Re-apply ask=false after interactive test" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set test operators (re-apply)" \
    "aba --ops cincinnati-operator nginx-ingress-operator flux"

test_end

# ============================================================================
# 3. Configure mirror to use local pre-populated registry
# ============================================================================
test_begin "Setup: configure mirror for local registry"

# Create mirror.conf pointing to conN's local pool registry (not disN)
e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set reg_host to local registry" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
    "sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
    "sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"
e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"

# Generate the pull secret for the pool registry
e2e_run "Generate pool-registry pull secret via aba" \
    "printf 'init\np4ssw0rd\n' | aba -d mirror password && cp ~/.aba/mirror/mirror/pull-secret-mirror.json /tmp/pool-reg-pull-secret.json"

# Register the pool registry as an existing external registry via ABA.
# This creates state.sh (REG_VENDOR=existing) so reg-install.sh's fast-path
# skips installation and just verifies, allowing 'aba mirror sync' to work.
e2e_run "Register pool registry" \
    "aba -d mirror register --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert $POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify mirror registry access" "aba -d mirror verify"
e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

test_end

# ============================================================================
# 4. Sync operators to registry
# ============================================================================
# Pool registry has OCP release images pre-populated (setup-pool-registry.sh).
# This incremental sync adds the operators configured in aba.conf and generates
# the working-dir (CatalogSources, IDMS/ITMS) that day2 needs.
test_begin "Setup: sync operators to registry"

e2e_run -r 3 2 "Sync images to local registry" "aba -d mirror sync --retry"

test_end

# ============================================================================
# 5. ABI config: generate and verify agent configs for sno/compact/standard
# ============================================================================
test_begin "ABI config: sno/compact/standard"

for ctype in sno compact standard; do
    cname="$(pool_cluster_name $ctype)"
    local_starting_ip=$(pool_starting_ip "$ctype")

    _extra_args=""
    [ "$ctype" = "standard" ] && _extra_args="-W 2"
    e2e_run "Delete any leftover $cname cluster" \
        "_e2e_delete_leftover_cluster $cname"
    e2e_run "Create cluster.conf for $cname" \
        "aba cluster -n $cname -t $ctype -i $local_starting_ip $_extra_args --step cluster.conf"
    e2e_run "Fix mac_prefix for $cname" \
        "sed -i 's#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g' $cname/cluster.conf"
    e2e_diag "Show $cname cluster.conf" "grep -E '^\w' $cname/cluster.conf"
    e2e_run "Generate install-config.yaml for $cname" \
        "aba --dir $cname install-config.yaml"
    e2e_run "Generate agent-config.yaml for $cname" \
        "aba --dir $cname agent-config.yaml"
    e2e_snapshot_file "${ctype}-generated" "$cname/install-config.yaml"
    e2e_snapshot_file "${ctype}-generated" "$cname/agent-config.yaml"
    e2e_snapshot_file "${ctype}-generated" "$cname/cluster.conf"
    e2e_run "Generate ISO for $cname" \
        "aba --dir $cname iso"
done

test_end

# ============================================================================
# 6. ABI config: diff against known-good examples
# ============================================================================
test_begin "ABI config: diff against known-good examples"

for ctype in sno compact standard; do
    cname="$(pool_cluster_name $ctype)"

    # vCenter generates "platform: vsphere:", ESXi/BM generates "platform: baremetal:"
    # SNO always uses "platform: none" regardless of hypervisor
    if [ "$ctype" != "sno" ] && ! grep -q 'vsphere:' "$cname/install-config.yaml"; then
        ic_example="test/e2e/examples/$ctype/install-config-esxi.yaml.example"
    else
        ic_example="test/e2e/examples/$ctype/install-config.yaml.example"
    fi

    e2e_snapshot_file "${ctype}-example" "$ic_example"
    e2e_snapshot_file "${ctype}-example" "test/e2e/examples/$ctype/agent-config.yaml.example"
    e2e_run "Diff $cname install-config.yaml against example" \
        "yaml_diff $cname/install-config.yaml <(adapt_example_for_pool $ic_example) --strip-secrets"

    e2e_run "Diff $cname agent-config.yaml against example" \
        "yaml_diff $cname/agent-config.yaml <(adapt_example_for_pool test/e2e/examples/$ctype/agent-config.yaml.example)"
done

# Clean up config-only dirs -- no VMs were created, safe to remove entirely
e2e_run "Remove compact cluster dir" "rm -rf $COMPACT"
e2e_run "Remove standard cluster dir" "rm -rf $STANDARD"

test_end

# ============================================================================
# 7. SNO: install cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_run "Delete any leftover $SNO cluster" \
    "_e2e_delete_leftover_cluster $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Create and install SNO cluster" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"

# Apply day2 (CatalogSources, IDMS/ITMS, trust CA)
e2e_run "Apply day2 configuration" "aba --dir $SNO day2"

test_end

# ============================================================================
# 8. SNO: verify operators from all three catalogs
# ============================================================================
test_begin "SNO: verify operators from all catalogs"

# After day2 applies CatalogSources, operators should appear in packagemanifests.
# Allow time for catalog pods to start and index.
e2e_poll 180 15 "Wait for cincinnati-operator (redhat catalog)" \
    "aba --dir $SNO run --cmd 'oc get packagemanifests' | grep ^cincinnati-operator"
e2e_poll 180 15 "Wait for nginx-ingress-operator (certified catalog)" \
    "aba --dir $SNO run --cmd 'oc get packagemanifests' | grep nginx-ingress-operator"
e2e_poll 180 15 "Wait for flux (community catalog)" \
    "aba --dir $SNO run --cmd 'oc get packagemanifests' | grep flux"

e2e_diag "Show all packagemanifests" "aba --dir $SNO run --cmd 'oc get packagemanifests'"

test_end

# ============================================================================
# 9. SNO: IP conflict detection
# ============================================================================
# The SNO cluster from test 7 is still running.  Attempt to create another
# cluster on the same IP and verify the preflight check catches the conflict.
test_begin "SNO: IP conflict detection"

SNO_DUP="${SNO}-dup"
e2e_run "Create duplicate SNO config with same IP" \
    "rm -rf $SNO_DUP && aba cluster -n $SNO_DUP -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"
e2e_run "Generate install-config.yaml for duplicate" \
    "aba --dir $SNO_DUP install-config.yaml"
e2e_run "Generate agent-config.yaml for duplicate" \
    "aba --dir $SNO_DUP agent-config.yaml"
e2e_run_must_fail "Preflight must detect IP conflict with running SNO" \
    "aba --dir $SNO_DUP preflight"

test_end

# ============================================================================
# 10. verify_conf=conf skips network checks (IP conflict still present)
# ============================================================================
# The SNO cluster is still running and the duplicate config still exists,
# so the IP conflict is real.  With verify_conf=conf, preflight must pass
# because network checks are skipped.
test_begin "verify_conf=conf skips network checks"

e2e_run "Set verify_conf=conf" \
    "aba --verify conf"
e2e_run "Preflight must pass with verify_conf=conf despite IP conflict" \
    "aba --dir $SNO_DUP preflight"
e2e_run "Restore verify_conf=all" \
    "aba --verify all"
e2e_run "Clean up duplicate cluster dir" "rm -rf $SNO_DUP"

test_end

# ============================================================================
# 11. Regression: verify_conf=conf must still extract mirror openshift-install
# ============================================================================
# OCP 4.21+ enforces sigstore verification for quay.io release images.
# The openshift-install binary extracted from the mirror references the mirror
# URL (not quay.io), bypassing sigstore enforcement.  A past bug caused
# --verify conf to skip this extraction entirely, leading to install failures.
test_begin "Regression: verify_conf=conf extracts mirror binary"

_REG_HOST=$(grep '^reg_host=' mirror/mirror.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Sanity: mirror binary exists from SNO install" \
	"test -x $SNO/openshift-install-mirror-$_REG_HOST"

e2e_run "Remove mirror binary to force re-extraction" \
	"rm -f $SNO/openshift-install-mirror-$_REG_HOST"

e2e_run "Set verify_conf=conf" \
	"aba --verify conf"

e2e_run "Run verify-release-image.sh with verify_conf=conf" \
	"cd $SNO && scripts/verify-release-image.sh"

e2e_run "Assert mirror binary re-extracted despite verify_conf=conf" \
	"test -x $SNO/openshift-install-mirror-$_REG_HOST"

e2e_run "Restore verify_conf=all" \
	"aba --verify all"

test_end

# ============================================================================
# 12. Upgrade: sync target version and aba upgrade
# ============================================================================
# The SNO from test 7 is running the "previous" version.  Sync the "latest"
# images into the same mirror and upgrade the cluster using 'aba upgrade'.
test_begin "Upgrade: sync target and aba upgrade"

e2e_run "Resolve latest version for upgrade target" "
    aba --channel $TEST_CHANNEL --version l
    upgrade_target=\$(grep ^ocp_version= aba.conf | cut -d= -f2 | awk '{print \$1}')
    echo \$upgrade_target > /tmp/e2e-upgrade-target
    echo \"Upgrade target: \$upgrade_target\"
"

e2e_run "Set --target-version and regenerate ISC" "
    cd ~/aba
    target=\$(cat /tmp/e2e-upgrade-target)
    aba -d mirror --target-version \$target
    rm -f mirror/data/imageset-config.yaml
    aba -d mirror imagesetconf
"

e2e_run -r 3 2 "Sync upgrade images" "aba -d mirror sync --retry"

e2e_run "Apply day2 (upgrade mirror resources)" "aba --dir $SNO day2"

e2e_run "Dry-run upgrade" \
    "aba -d $SNO upgrade --to \$(cat /tmp/e2e-upgrade-target) --dry-run"

e2e_run -r 3 2 "Trigger and verify upgrade" "
    target=\$(cat /tmp/e2e-upgrade-target)
    aba -d $SNO upgrade --to \$target --skip-day2 --force || true  # may exit non-zero if already at target; desired-version assertion validates outcome
    desired=\$(aba -d $SNO run --cmd 'oc get clusterversion version -o jsonpath={.status.desired.version}' | tail -1)
    echo \"Desired version: \$desired  (target: \$target)\"
    [ \"\$desired\" = \"\$target\" ]
"

e2e_run "Delete SNO cluster" "aba --dir $SNO delete"
e2e_remove_from_cluster_cleanup "$PWD/$SNO"

test_end

# ============================================================================
# Register/unregister CLI flag coverage
# ============================================================================
test_begin "Register: --reg-host and --reg-port CLI flags"

e2e_run "Unregister pool registry for re-registration test" \
    "aba -d mirror unregister"

e2e_run "Register with explicit --reg-host and --reg-port" \
    "aba -d mirror register --reg-host ${CON_HOST} --reg-port 8443 --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert $POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify registry access after --reg-host/--reg-port register" \
    "aba -d mirror verify"

e2e_run "Assert reg_host in mirror.conf matches CLI flag" \
    "grep -q 'reg_host=${CON_HOST}' mirror/mirror.conf"

e2e_run "Assert reg_port in mirror.conf matches CLI flag" \
    "grep -q 'reg_port=8443' mirror/mirror.conf"

test_end

# ============================================================================
# Named mirror + register (enclave workflow)
# ============================================================================
test_begin "Register: named mirror (enclave workflow)"

ENCLAVE_MIRROR="e2e-test-enclave"

e2e_run "Create named mirror directory" \
    "aba mirror --name $ENCLAVE_MIRROR || true"  # make exits non-zero with editor=none after creating dir

e2e_run "Assert enclave mirror directory exists" \
    "test -d $ENCLAVE_MIRROR && test -f $ENCLAVE_MIRROR/mirror.conf"

e2e_run "Register pool registry to named mirror" \
    "aba -d $ENCLAVE_MIRROR register --reg-host ${CON_HOST} --reg-port 8443 --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert $POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify named mirror registry access" \
    "aba -d $ENCLAVE_MIRROR verify"

e2e_run "Verify state.sh has REG_VENDOR=existing" \
    "grep REG_VENDOR=existing ~/.aba/mirror/$ENCLAVE_MIRROR/state.sh"

test_end

# ============================================================================
# Enclave: SNO install via named mirror (boot + SSH only)
# ============================================================================
# Creates a SNO cluster that references the named enclave mirror instead of
# the default 'mirror/' directory.  Validates the full register -> cluster
# workflow.  We only wait for node boot + SSH -- no full install-complete.
test_begin "Enclave: SNO install via named mirror"

ENCLAVE_SNO="$(pool_cluster_name sno-enc)"

e2e_run "Sync OCP images through enclave mirror" \
    "aba -d $ENCLAVE_MIRROR sync --retry"

e2e_run "Create SNO cluster config via enclave mirror" \
    "aba cluster -n $ENCLAVE_SNO -t sno --starting-ip $(pool_sno_ip) --mirror-name $ENCLAVE_MIRROR --step cluster.conf"

e2e_run "Fix mac_prefix for enclave SNO" \
    "sed -i 's#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g' $ENCLAVE_SNO/cluster.conf"

e2e_diag "Show enclave SNO cluster.conf" "grep -E '^\w' $ENCLAVE_SNO/cluster.conf"

e2e_run "Verify cluster.conf references enclave mirror" \
    "grep -q 'mirror_name=$ENCLAVE_MIRROR' $ENCLAVE_SNO/cluster.conf"

e2e_run "Generate ISO for enclave SNO" "aba --dir $ENCLAVE_SNO iso"
e2e_run "Upload ISO for enclave SNO" "aba --dir $ENCLAVE_SNO upload"
e2e_add_to_cluster_cleanup "$PWD/$ENCLAVE_SNO"
e2e_run "Boot enclave SNO VM" "aba --dir $ENCLAVE_SNO refresh"

e2e_run -r 1 1 "Wait for enclave SNO node SSH" \
    "timeout 8m bash -c 'until aba --dir $ENCLAVE_SNO ssh --cmd hostname; do sleep 10; done'"

e2e_diag "Show enclave SNO node IP info" \
    "aba --dir $ENCLAVE_SNO ssh --cmd 'ip a'"

e2e_run "Delete enclave SNO VMs" "aba --dir $ENCLAVE_SNO delete"
e2e_remove_from_cluster_cleanup "$PWD/$ENCLAVE_SNO"
e2e_run "Remove enclave SNO cluster dir" "rm -rf $ENCLAVE_SNO"

e2e_run "Unregister enclave mirror" \
    "aba -d $ENCLAVE_MIRROR unregister"
e2e_run "Remove enclave mirror directory" "rm -rf $ENCLAVE_MIRROR"

test_end

# ============================================================================
# End-of-suite cleanup: delete cluster and unregister mirror
# ============================================================================
test_begin "Cleanup: delete cluster and unregister mirror"

e2e_run "Delete SNO cluster" \
    "_e2e_delete_leftover_cluster $SNO"
e2e_run "Delete enclave SNO if leftover" \
    "_e2e_delete_leftover_cluster $ENCLAVE_SNO"
e2e_run "Unregister enclave mirror if leftover" \
    "if [ -d $ENCLAVE_MIRROR ]; then aba -d $ENCLAVE_MIRROR unregister && rm -rf $ENCLAVE_MIRROR; else echo '[cleanup] enclave mirror already removed'; fi"
e2e_run "Unregister pool registry" \
    "aba -d mirror unregister"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-cluster-ops.sh"

exit 0
