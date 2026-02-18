#!/bin/bash
# =============================================================================
# Suite: Cluster Ops
# =============================================================================
# Purpose: ABI config generation, YAML validation against known-good examples,
#          and SNO cluster install/verify. Exercises the cluster-building
#          pipeline without testing mirroring specifics.
#
# Prerequisite: Internet-connected host with aba installed.
#               Internal bastion VM available for registry install.
#               (Later: pre-populated registry on conN removes the disN dependency.)
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

DIS_HOST="dis${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"
STANDARD="$(pool_cluster_name standard)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Setup: reset internal bastion" \
    "Setup: sync images to registry" \
    "ABI config: sno/compact/standard" \
    "ABI config: diff against known-good examples" \
    "SNO: install cluster"

suite_begin "cluster-ops"

preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

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
# 2. Setup: reset internal bastion
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end

# ============================================================================
# 3. Setup: sync images to registry
# ============================================================================
# TODO: Replace with pre-populated registry on conN once available.
#       This step exists only to populate disN so cluster install has images.
test_begin "Setup: sync images to registry"

e2e_run -r 3 2 "Sync images to remote registry" \
    "aba -d mirror sync --retry -H $DIS_HOST -k ~/.ssh/id_rsa"

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
# 6. SNO: install cluster from synced mirror
# ============================================================================
test_begin "SNO: install cluster"

e2e_run "Clean up previous $SNO" "rm -rfv $SNO"
e2e_run "Create and install SNO cluster" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Verify cluster operators" "aba --dir $SNO run"
e2e_run -r 30 10 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Delete SNO cluster" "aba --dir $SNO delete"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-cluster-ops.sh"
