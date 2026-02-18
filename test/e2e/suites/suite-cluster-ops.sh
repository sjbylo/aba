#!/bin/bash
# =============================================================================
# Suite: Cluster Ops
# =============================================================================
# Purpose: ABI config generation, YAML validation against known-good examples,
#          SNO cluster install/verify, and operator availability check.
#          Uses a pre-populated mirror registry on conN (installed out-of-band)
#          so tests start immediately without waiting for sync/save/load.
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

CON_HOST="con${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
NTP_IP="${NTP_SERVER:-10.0.1.8}"
POOL_REG_DIR="$HOME/.e2e-pool-registry"

SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"
STANDARD="$(pool_cluster_name standard)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba and configure" \
    "Setup: configure mirror for local registry" \
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
    "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"

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

# Lightweight setup: remove RPMs (test auto-install), clean caches, but
# do NOT touch podman/containers -- the pre-populated Quay must stay alive.
e2e_run "Remove RPMs for clean install test" \
    "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y"
e2e_run "Remove oc-mirror caches" \
    "find ~/ -type d -name .oc-mirror | xargs rm -rfv"

e2e_run "Install aba" "./install"
e2e_run "Install aba (verify idempotent)" "../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

e2e_run "Configure aba.conf" "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=${TEST_CHANNEL:-stable} aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER in vmware.conf" "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"
e2e_run "Verify vmware.conf" "grep abatesting vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Basic interactive test" "test/basic-interactive-test.sh"

e2e_run "Re-apply ask=false after interactive test" \
    "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} --base-domain $(pool_domain)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets (re-apply)" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

test_end

# ============================================================================
# 3. Configure mirror to use local pre-populated registry
# ============================================================================
test_begin "Setup: configure mirror for local registry"

# Create mirror.conf pointing to conN's local Quay (not disN)
e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"

# Override mirror.conf to point at the local pre-populated registry
e2e_run "Set reg_host to local registry" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
    "sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
    "sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"

# Set up regcreds/ with the pre-populated registry's CA and pull secret
e2e_run "Create regcreds directory" "mkdir -p mirror/regcreds"
e2e_run "Copy Quay root CA to regcreds" \
    "cp -v ~/quay-install/quay-rootCA/rootCA.pem mirror/regcreds/"

# Generate pull-secret-mirror.json for the local registry
e2e_run "Generate mirror pull secret" \
    "enc_pw=\$(echo -n 'init:p4ssw0rd' | base64 -w0) && cat > mirror/regcreds/pull-secret-mirror.json <<EOPS
{
  \"auths\": {
    \"${CON_HOST}:8443\": {
      \"auth\": \"\$enc_pw\"
    }
  }
}
EOPS"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

# Link oc-mirror working-dir so day2 can find IDMS/ITMS/CatalogSources
e2e_run "Link oc-mirror working-dir for day2" \
    "mkdir -p mirror/sync && ln -sfn ${POOL_REG_DIR}/sync/working-dir mirror/sync/working-dir"

e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

test_end

# ============================================================================
# 4. ABI config: generate and verify agent configs for sno/compact/standard
# ============================================================================
test_begin "ABI config: sno/compact/standard"

for ctype in sno compact standard; do
    cname="$(pool_cluster_name $ctype)"
    local_starting_ip=""
    [ "$ctype" = "sno" ] && local_starting_ip=$(pool_sno_ip)
    [ "$ctype" = "compact" ] && local_starting_ip=$(pool_compact_api_vip)
    [ "$ctype" = "standard" ] && local_starting_ip=$(pool_standard_api_vip)

    e2e_run "Create cluster.conf for $cname" \
        "rm -rfv $cname && aba cluster -n $cname -t $ctype -i $local_starting_ip --step cluster.conf"
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
# 5. ABI config: diff against known-good examples
# ============================================================================
test_begin "ABI config: diff against known-good examples"

for ctype in sno compact standard; do
    cname="$(pool_cluster_name $ctype)"
    e2e_run "Diff $cname install-config.yaml against example" \
        "diff <(python3 -c \"
import yaml, sys
d = yaml.safe_load(open('$cname/install-config.yaml'))
for k in ('additionalTrustBundle', 'pullSecret'):
    d.pop(k, None)
vs = d.get('platform', {}).get('vsphere', {})
for vc in vs.get('vcenters', []):
    vc.pop('password', None)
fds = vs.get('failureDomains', [])
if fds:
    for k in ('name', 'region', 'zone'):
        fds[0].pop(k, None)
    fds[0].get('topology', {}).pop('datastore', None)
yaml.dump(d, sys.stdout, default_flow_style=False, sort_keys=False)
\") <(python3 -c \"
import yaml, sys
yaml.dump(yaml.safe_load(open('test/$ctype/install-config.yaml.example')), sys.stdout, default_flow_style=False, sort_keys=False)
\")"

    e2e_run "Diff $cname agent-config.yaml against example" \
        "diff <(python3 -c \"
import yaml, sys
yaml.dump(yaml.safe_load(open('$cname/agent-config.yaml')), sys.stdout, default_flow_style=False, sort_keys=False)
\") <(python3 -c \"
import yaml, sys
yaml.dump(yaml.safe_load(open('test/$ctype/agent-config.yaml.example')), sys.stdout, default_flow_style=False, sort_keys=False)
\")"
done

test_end

# ============================================================================
# 6. SNO: install cluster from pre-populated registry
# ============================================================================
test_begin "SNO: install cluster"

e2e_run "Clean up previous $SNO" "rm -rfv $SNO"
e2e_run "Create and install SNO cluster" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Verify cluster operators" "aba --dir $SNO run"
e2e_run -r 30 10 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"

# Apply day2 (CatalogSources, IDMS/ITMS, trust CA)
e2e_run "Apply day2 configuration" "aba --dir $SNO day2"

test_end

# ============================================================================
# 7. SNO: verify operators from all three catalogs
# ============================================================================
test_begin "SNO: verify operators from all catalogs"

# After day2 applies CatalogSources, operators should appear in packagemanifests.
# Allow time for catalog pods to start and index.
e2e_run -r 20 15 "Wait for cincinnati-operator (redhat catalog)" \
    "aba --dir $SNO run --cmd 'oc get packagemanifests' | grep cincinnati-operator"
e2e_run -r 20 15 "Wait for nginx-ingress-operator (certified catalog)" \
    "aba --dir $SNO run --cmd 'oc get packagemanifests' | grep nginx-ingress-operator"
e2e_run -r 20 15 "Wait for flux (community catalog)" \
    "aba --dir $SNO run --cmd 'oc get packagemanifests' | grep flux"

e2e_diag "Show all packagemanifests" "aba --dir $SNO run --cmd 'oc get packagemanifests'"

e2e_run "Delete SNO cluster" "aba --dir $SNO delete"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-cluster-ops.sh"
