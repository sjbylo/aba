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
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
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
    "SNO: verify operators from all catalogs"

suite_begin "cluster-ops"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

# Resolve OCP version: use OCP_VERSION env or fall back to "p" (previous)
# We need the actual x.y.z version for the registry setup script.
e2e_run "Install aba (needed for version resolution)" "./install"
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

# Lightweight setup: clean caches only; do NOT touch podman/containers --
# the pre-populated Quay must stay alive.
e2e_run "Remove oc-mirror caches" \
    "sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rf"

# Clean-start bootstrap: remove packages ABA must auto-reinstall (ported from old test1-5)
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
e2e_run "Set dns_servers via CLI" "aba --dns $(pool_dns_server)"
e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER in vmware.conf" "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Verify vmware.conf" "grep aba-e2e vmware.conf"

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

# Generate the pull secret for the pool registry
e2e_run "Generate pool-registry pull secret" \
    "enc_pw=\$(echo -n 'init:p4ssw0rd' | base64 -w0) && cat > /tmp/pool-reg-pull-secret.json <<EOPS
{
  \"auths\": {
    \"${CON_HOST}:8443\": {
      \"auth\": \"\$enc_pw\"
    }
  }
}
EOPS"

# Register the pool registry as an existing external registry via ABA.
# This creates state.sh (REG_VENDOR=existing) so reg-install.sh's fast-path
# skips installation and just verifies, allowing 'aba mirror sync' to work.
e2e_run "Register pool registry" \
    "aba -d mirror register pull_secret_mirror=/tmp/pool-reg-pull-secret.json ca_cert=$POOL_REG_DIR/certs/ca.crt"

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

    e2e_run "Create cluster.conf for $cname" \
        "rm -rf $cname && aba cluster -n $cname -t $ctype -i $local_starting_ip --step cluster.conf"
    e2e_run "Fix mac_prefix for $cname" \
        "sed -i 's#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g' $cname/cluster.conf"
    e2e_run "Generate install-config.yaml for $cname" \
        "aba --dir $cname install-config.yaml"
    e2e_run "Generate agent-config.yaml for $cname" \
        "aba --dir $cname agent-config.yaml"
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
    e2e_run "Diff $cname install-config.yaml against example" \
        "yaml_diff $cname/install-config.yaml test/$ctype/install-config.yaml.example --strip-secrets"

    e2e_run "Diff $cname agent-config.yaml against example" \
        "yaml_diff $cname/agent-config.yaml test/$ctype/agent-config.yaml.example"
done

# Clean up compact/standard dirs -- only needed for config validation, not cluster install
e2e_run "Clean compact cluster dir (config-only)" "aba --dir $COMPACT clean"
e2e_run "Clean standard cluster dir (config-only)" "aba --dir $STANDARD clean"

test_end

# ============================================================================
# 7. SNO: install cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_run "Clean up previous $SNO cluster dir" "rm -rf $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Create and install SNO cluster" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False$' | wc -l | grep ^0\$"
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

e2e_run "Delete SNO cluster" "aba --dir $SNO delete"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-cluster-ops.sh"
