#!/usr/bin/env bash
# =============================================================================
# Suite: Airgapped with Existing Registry (rewrite of test2)
# =============================================================================
# Purpose: Air-gapped workflow using the pool registry on conN as an
#          "existing" (externally-managed) registry. Save images, tar-pipe
#          transfer, load into existing registry, install cluster, deploy
#          app, install ACM.
#
# Unique: pool registry registration via `aba register`, must-fail checks,
#         existing registry integration, ACM/MCH, NTP chronyc verification.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-ops.sh"
source "$_SUITE_DIR/../lib/setup.sh"
source "$_SUITE_DIR/../lib/suite-helpers.sh"

# --- Configuration ----------------------------------------------------------
# L commands run on conN (this host). R commands SSH to disN.

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

# Pool-unique cluster names (avoid VM collisions when pools run in parallel)
SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Existing registry: register pool registry" \
    "Must-fail checks" \
    "Save images to disk" \
    "Tar-pipe transfer to bastion" \
    "Load without regcreds (must fail)" \
    "Load without data dir (must fail)" \
    "Load images into existing registry" \
    "Compact: install and delete cluster" \
    "SNO: install cluster" \
    "Deploy vote-app" \
    "ACM: install operators" \
    "ACM: MultiClusterHub" \
    "NTP: day2 and chronyc verify" \
    "Delete cluster" \
    "Cleanup: deregister pool registry"

suite_begin "airgapped-existing-reg"

# Pre-flight: abort immediately if the internal bastion (disN) is unreachable
preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_install_aba

e2e_run "Remove oc-mirror caches (conN)" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"
e2e_run_remote -q "Remove oc-mirror caches (disN)" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"

suite_configure_aba
suite_verify_aba_conf

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER" \
    "sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"

e2e_run "Set NTP servers (IP only for install)" "aba --ntp $NTP_IP"
e2e_run "Verify aba.conf: ntp_servers" "grep '^ntp_servers=.*$NTP_IP' aba.conf"
e2e_run "Set operator sets" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"
e2e_run "Verify aba.conf: op_sets" "grep '^op_sets=abatest' aba.conf"

_e2e_delete_leftover_cluster_remote "$SNO"
_e2e_delete_leftover_cluster_remote "$COMPACT"
e2e_run "Reset aba" "aba reset -f"

# aba reset -f wipes aba.conf; re-apply configuration to avoid vi/editor hangs
suite_configure_aba
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply, IP only)" "aba --ntp $NTP_IP"
e2e_run "Set operator sets (re-apply)" \
    "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

test_end

# ============================================================================
# 2. Register pool registry on conN as the "existing" registry
# ============================================================================
test_begin "Existing registry: register pool registry"

# Ensure the pool registry is running on conN before registering it.
# setup-pool-registry.sh is idempotent: skips install/sync if already done.
_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pool registry running (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

suite_create_mirror_workdir
e2e_run "Set reg_host to pool registry on conN" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Set operator sets in mirror.conf" "aba --op-sets abatest"
e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"

e2e_run "Register pool registry with ABA" \
    "aba -d mirror register --pull-secret-mirror $POOL_REG_DIR/pool-reg-creds.json --ca-cert $POOL_REG_DIR/certs/ca.crt"
e2e_run "Verify pool registry access" \
    "aba -d mirror verify"

test_end

# ============================================================================
# 4. Must-fail checks (unique to test2)
# ============================================================================
test_begin "Must-fail checks"

# These commands should fail -- verify they do
e2e_run_must_fail "Uninstall existing reg should abort (state=existing)" \
    "aba -d mirror uninstall -y"

# ADR-007: -H with a host that differs from installed state must abort.
# The core fix in aba.sh checks persistent state and refuses to override.
e2e_run_must_fail "-H to different host should abort (state locks reg_host)" \
    "aba -d mirror sync -H unknown.example.com --retry"

# Pool registry is already registered -- idempotent install must succeed (skip)
e2e_run "Install on already-registered registry succeeds (idempotent)" \
    "aba -d mirror install"

# Existing registry detection (ported from old test2 line 178):
# Unregister first so ABA doesn't know about the registry, then try to install.
# Without state.sh, ABA probes the URL, finds a running registry it didn't install,
# and correctly aborts — you can't install over an unknown existing registry.
e2e_run "Unregister pool registry for must-fail install test" \
    "aba -d mirror unregister"
e2e_run_must_fail "Install over unregistered existing registry must fail" \
    "aba -d mirror install"
e2e_run "Re-register pool registry after must-fail test" \
    "aba -d mirror register --pull-secret-mirror $POOL_REG_DIR/pool-reg-creds.json --ca-cert $POOL_REG_DIR/certs/ca.crt"

test_end

# ============================================================================
# 5. Save images to disk
# ============================================================================
test_begin "Save images to disk"

e2e_snapshot_file "initial-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save images" "aba -d mirror save --retry"

e2e_run "Show saved files" "ls -lh mirror/data/"

test_end

# ============================================================================
# 6. Tar-pipe transfer to bastion
# ============================================================================
test_begin "Tar-pipe transfer to bastion"

# Stdout purity regression test: force the dnf install code path (by removing
# a known RPM) and verify `aba -d mirror tar --out -` produces valid tar on
# stdout with no text contamination.  This catches regressions where install
# messages leak to stdout and corrupt the tar stream (see install >&2 fix).
e2e_run "Remove dialog RPM to force dnf path" \
    "sudo dnf remove -y dialog"
e2e_run "Remove stale dnf log" \
    "rm -f mirror/.dnf-install.log"
e2e_run "Verify tar stdout purity under dnf install" \
    "aba -d mirror tar --out - 2>/tmp/e2e-tar-stderr.log | tar tf - > /dev/null"
e2e_run "Verify dnf install actually ran" \
    "test -s mirror/.dnf-install.log"
e2e_run "Verify dialog was reinstalled" \
    "rpm -q dialog"

# Stage pool registry creds into mirror/.test/ so they're included in the tar-pipe
e2e_run "Stage pool registry creds for transfer" \
    "mkdir -p mirror/.test && cp $POOL_REG_DIR/pool-reg-creds.json mirror/.test/pool-reg-creds.json && cp $POOL_REG_DIR/certs/ca.crt mirror/.test/pool-reg-rootCA.pem"

# Now do the real tar-pipe transfer
e2e_run -r 3 2 "Pipe tar to internal bastion" \
    "aba -d mirror tar --out - | ssh ${INTERNAL_BASTION} 'tar xvf - -C ~'"
e2e_run -q "Remove saved archives after transfer" "rm -f mirror/data/mirror_*.tar"

e2e_run_remote "Remove dialog RPM to force dnf install path" \
    "sudo dnf remove -y dialog"
e2e_run_remote "Remove stale dnf log" \
    "cd ~/aba && rm -f .dnf-install.log"
e2e_run_remote "Install aba on internal bastion" \
    "cd ~/aba && ./install"
e2e_run_remote "Check bundle mode is active" \
    "cd ~/aba && test -f .bundle"
e2e_run_remote "See install bundle banner and help on internal bastion" \
    "cd ~/aba && aba"
e2e_run_remote "Verify dialog was reinstalled" \
    "rpm -q dialog"
e2e_run_remote "Verify single dnf batch (no duplicate install)" \
    "cd ~/aba && test \$(grep -c 'Transaction Summary' .dnf-install.log) -eq 1"

# mirror.conf is no longer in the bundle; create and configure it on disN
e2e_run_remote "Create mirror.conf on bastion" \
    "cd ~/aba && aba -d mirror mirror.conf"
e2e_run_remote "Set reg_host to pool registry on conN" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' ~/aba/mirror/mirror.conf"
e2e_diag_remote "Show mirror.conf on bastion" "grep -E '^\w' ~/aba/mirror/mirror.conf"

# Register the pool registry on disN using the staged creds
# Paths are relative to mirror/ because aba -d mirror changes CWD there
e2e_run_remote "Register pool registry on disN" \
    "cd ~/aba && aba -d mirror register --pull-secret-mirror .test/pool-reg-creds.json --ca-cert .test/pool-reg-rootCA.pem"
e2e_run_remote "Verify pool registry access from disN" \
    "cd ~/aba && aba -d mirror verify"

test_end

# ============================================================================
# 7. Load without regcreds -- must fail (Gap 4: common user mistake)
# ============================================================================
test_begin "Load without regcreds (must fail)"

# Back up regcreds before removing, then restore after the must-fail test.
# This is safer than manually reconstructing from ~/.docker/config.json.
e2e_run_remote -q "Back up regcreds" \
    "cp -a ~/.aba/mirror/mirror/ /tmp/e2e-regcreds-backup/"

e2e_run_remote -q "Remove regcreds" \
    "rm -rf ~/.aba/mirror/mirror/"

e2e_run_must_fail_remote "Load without regcreds should fail" \
    "cd ~/aba && aba -d mirror load --retry"

e2e_run_remote "Restore regcreds from backup" \
    "rm -rf ~/.aba/mirror/mirror && cp -a /tmp/e2e-regcreds-backup ~/.aba/mirror/mirror && rm -rf /tmp/e2e-regcreds-backup"
e2e_run_remote "Verify registry access with restored regcreds" \
    "cd ~/aba && aba -d mirror verify"

test_end

# ============================================================================
# 7b. Load without save dir -- must fail
# ============================================================================
test_begin "Load without data dir (must fail)"

e2e_run_remote -q "Move data dir aside" \
	"cd ~/aba && mv mirror/data mirror/data.bak"

e2e_run_must_fail_remote "Load without data dir should fail" \
	"cd ~/aba && aba -d mirror load"

e2e_run_remote -q "Restore data dir" \
	"cd ~/aba && mv mirror/data.bak mirror/data"

# Negative path: data/ exists but no mirror_*.tar
e2e_run_remote -q "Move mirror_*.tar aside" \
	"cd ~/aba && mkdir -p mirror/data/.tmp-bak && mv mirror/data/mirror_*.tar mirror/data/.tmp-bak/ 2>/dev/null || true"
e2e_run_must_fail_remote "Load without mirror_*.tar should fail" \
	"cd ~/aba && aba -d mirror load"
e2e_run_remote -q "Restore mirror_*.tar" \
	"cd ~/aba && mv mirror/data/.tmp-bak/mirror_*.tar mirror/data/ 2>/dev/null || true; rmdir mirror/data/.tmp-bak 2>/dev/null || true"

test_end

# ============================================================================
# 8. Load images into existing registry
# ============================================================================
test_begin "Load images into existing registry"

e2e_snapshot_file_remote "initial-load" "aba/mirror/data/imageset-config.yaml"
e2e_run_remote -r 3 2 "Load images into registry" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote "Verify aba-transfer.tar kept after load" \
    "cd ~/aba && test -f mirror/data/aba-transfer.tar"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

test_end

# ============================================================================
# 9. Compact: bootstrap and delete (Gap 1: coverage for 3-node combo)
#    Full install takes ~40 min; bootstrap proves images loaded correctly
#    and the cluster can start (control plane comes up). Saves ~30 min.
# ============================================================================
test_begin "Compact: install and delete cluster"

e2e_add_to_cluster_cleanup "$PWD/$COMPACT" remote

e2e_run_remote "Set explicit non-default DNS (exercises dns_servers)" \
    "cd ~/aba && aba --dns $(pool_dns_server) 8.8.4.4"
e2e_run_remote "Set explicit gateway (exercises next_hop_address)" \
    "cd ~/aba && aba --gateway-ip 10.0.0.1"
e2e_run_remote "Create compact cluster.conf with explicit VIPs" \
    "cd ~/aba && aba cluster -n $COMPACT -t compact --starting-ip $(pool_starting_ip compact) \
     --api-vip $(pool_api_vip) --ingress-vip $(pool_apps_vip) --step cluster.conf"
e2e_run_remote "Increase compact resources for reliable bootstrap" \
    "cd ~/aba && sed -i 's/^master_cpu_count=.*/master_cpu_count=14/' $COMPACT/cluster.conf && \
     sed -i 's/^master_mem=.*/master_mem=28/' $COMPACT/cluster.conf"
e2e_run_remote "Verify explicit VIPs in cluster.conf" \
    "cd ~/aba && grep -q 'api_vip=$(pool_api_vip)' $COMPACT/cluster.conf && \
     grep -q 'ingress_vip=$(pool_apps_vip)' $COMPACT/cluster.conf"
e2e_run_remote "Verify explicit dns_servers in cluster.conf" \
    "cd ~/aba && grep -q 'dns_servers=.*8.8.4.4' $COMPACT/cluster.conf"
e2e_diag_remote "Show compact cluster.conf" "grep -E '^\w' ~/aba/$COMPACT/cluster.conf"

e2e_run_remote "Set verify_conf=off (skip all preflight)" \
    "cd ~/aba && aba --verify off"
e2e_run_remote -r 1 1 "Bootstrap compact cluster (verify=off)" \
    "cd ~/aba && aba cluster -n $COMPACT -t compact --starting-ip $(pool_starting_ip compact) --step bootstrap"
e2e_run_remote "Restore verify_conf=all" \
    "cd ~/aba && aba --verify all"
e2e_run_remote "Delete compact cluster" \
    "cd ~/aba && aba --dir $COMPACT delete"
e2e_remove_from_cluster_cleanup "$PWD/$COMPACT" remote
e2e_run_remote -q "Clean compact dir" \
    "cd ~/aba && aba --dir $COMPACT clean"

test_end

# ============================================================================
# 10. Install SNO cluster
# ============================================================================
test_begin "SNO: install cluster"

e2e_add_to_cluster_cleanup "$PWD/$SNO" remote
# ACM/MCH requires significantly more resources than default SNO (old test uses 24 CPU / 40GB)
e2e_run_remote "Generate SNO cluster.conf" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"
e2e_run_remote "Increase SNO resources for ACM" \
    "cd ~/aba && sed -i 's/^master_cpu_count=.*/master_cpu_count=28/' $SNO/cluster.conf && \
     sed -i 's/^master_mem=.*/master_mem=46/' $SNO/cluster.conf"
e2e_diag_remote "Show SNO cluster.conf" "grep -E '^\w' ~/aba/$SNO/cluster.conf"
e2e_run_remote -r 2 10 "Install SNO cluster" \
    "cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run_remote "Show cluster operator status" \
    "cd ~/aba && aba --dir $SNO run"
e2e_wait_cluster_available $SNO remote
e2e_diag_remote "Show cluster operators" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get co'"

e2e_run_remote "Apply day2 config" \
    "cd ~/aba && aba --dir $SNO day2"

e2e_run_remote "Verify CatalogSources present after day2" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get catalogsource -n openshift-marketplace --no-headers' | grep ."

test_end

# ============================================================================
# 11. Incremental: vote-app image load
# ============================================================================
test_begin "Deploy vote-app"

e2e_run "Create fresh imageset config for vote-app only" \
    "tee mirror/data/imageset-config.yaml <<'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: quay.io/sjbylo/flask-vote-app:latest
EOF"
e2e_snapshot_file "voteapp-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save vote-app image to disk" \
    "aba -d mirror save --retry"
e2e_run "Transfer vote-app archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_snapshot_file_remote "voteapp-load" "aba/mirror/data/imageset-config.yaml"
e2e_run_remote -r 3 2 "Load vote-app images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

e2e_run_remote "Verify vote-app image in mirror (skopeo)" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && skopeo inspect --tls-verify=false docker://\$reg_host:\$reg_port\$reg_path/sjbylo/flask-vote-app:latest"

e2e_run_remote "Apply day2 config (vote-app mirror resources)" \
    "cd ~/aba && aba --dir $SNO day2"

e2e_run_remote "Create demo project" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get project demo || oc new-project demo'"
e2e_run_remote -r 3 2 "Launch vote-app from mirror" \
    "cd ~/aba && source <(grep -E '^reg_host=|^reg_port=|^reg_path=' mirror/mirror.conf) && aba --dir $SNO run --cmd \"oc new-app --insecure-registry=true --image \$reg_host:\$reg_port\$reg_path/sjbylo/flask-vote-app --name vote-app -n demo\""
e2e_poll_remote 480 30 "Wait for vote-app rollout" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc rollout status deployment vote-app -n demo'"

test_end

# ============================================================================
# 12. ACM: install operators
# ============================================================================
test_begin "ACM: install operators"

# Save+Load config: ALL operators (old + new) so the archive is self-contained.
# oc-mirror v2 diskToMirror resolves catalog data from the archive; operators
# not in the archive cause oc-mirror to reach upstream (fails on disconnected
# hosts).  No platform section -- oc-mirror v2 errors with "no release images
# found" when platform is present but the delta tar has no release images.
# oc-mirror only saves the delta since the last mirrorToDisk, so including
# already-mirrored operators (kiali-ossm) adds negligible overhead.
e2e_run "Set op_sets=acm" "aba --op-sets acm"

OCP_VER_MAJOR=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}' | cut -d. -f1-2)
e2e_run "Create config with all operators for save+load" \
    "cat > mirror/data/imageset-config.yaml <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OCP_VER_MAJOR}
    packages:
\$(grep -A2 'name: kiali-ossm\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml)
\$(grep -A2 'name: advanced-cluster-management\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml)
\$(grep -A2 'name: multicluster-engine\$' mirror/imageset-config-redhat-operator-catalog-v${OCP_VER_MAJOR}.yaml)
EOF"
e2e_diag "Show save+load config" "cat mirror/data/imageset-config.yaml"

e2e_snapshot_file "acm-save" "mirror/data/imageset-config.yaml"
e2e_run -r 3 2 "Save ACM images" "aba -d mirror save --retry"

e2e_run "Transfer archive to internal bastion" \
    "scp mirror/data/*.tar ${INTERNAL_BASTION}:aba/mirror/data/"
e2e_run -q "Remove transferred archives" "rm -f mirror/data/mirror_*.tar"
e2e_snapshot_file_remote "acm-load" "aba/mirror/data/imageset-config.yaml"
e2e_run_remote -r 3 2 "Load ACM images" \
    "cd ~/aba && aba -d mirror load --retry"
e2e_run_remote -q "Remove loaded archives" "cd ~/aba && rm -f mirror/data/mirror_*.tar"

e2e_run_remote "Apply day2 config (ACM operator resources)" \
    "cd ~/aba && aba --dir $SNO day2"

# Verify previously loaded operators survived the incremental load.
# oc-mirror rebuilds the catalog index during load; a partial config would
# silently drop operators not listed (see ai/OC-MIRROR-INTERNALS.md).
e2e_poll_remote 180 15 "Verify kiali-ossm still in OperatorHub after ACM load" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get packagemanifests' | grep ^kiali-ossm"

test_end

# ============================================================================
# 13. ACM: MultiClusterHub
# ============================================================================
test_begin "ACM: MultiClusterHub"

# Wait for CatalogSource to be indexed and ACM to appear in packagemanifests
e2e_poll_remote 600 30 "Wait for ACM packagemanifest" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get packagemanifests -n openshift-marketplace' | grep advanced-cluster-management"

e2e_run "Copy ACM YAML files to internal bastion" \
    "ssh ${INTERNAL_BASTION} 'mkdir -p ~/aba/test' && scp ~/aba/test/acm-subs.yaml ~/aba/test/acm-mch.yaml ${INTERNAL_BASTION}:aba/test/"

# Set the correct channel from the mirrored catalog index
OCP_VER_MAJOR=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}' | cut -d. -f1-2)
ACM_CHANNEL=$(grep ^advanced-cluster-management .index/redhat-operator-index-v${OCP_VER_MAJOR} | awk '{print $NF}' | tail -1)
[ -n "$ACM_CHANNEL" ] && \
e2e_run_remote "Set ACM channel to $ACM_CHANNEL" \
    "sed -i 's/^#.*channel:.*/  channel: ${ACM_CHANNEL}/' ~/aba/test/acm-subs.yaml"

e2e_run_remote -r 5 1.5 "Install ACM subscription" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc apply -f ~/aba/test/acm-subs.yaml'"
e2e_poll_remote 300 30 "Wait for ACM operator CSV" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get csv -n open-cluster-management | grep advanced-cluster-management.*Succeeded'"
e2e_run_remote -r 5 1.5 "Install MultiClusterHub" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc apply -f ~/aba/test/acm-mch.yaml'"
e2e_poll_remote 1800 60 "Wait for MCH ready" \
    "cd ~/aba && aba --dir $SNO run --cmd 'oc get multiclusterhub -n open-cluster-management -o jsonpath={.items[0].status.phase} | grep Running'"

test_end

# ============================================================================
# 14. NTP: day2 configuration and chronyc verify
# ============================================================================
# Install used IP-only NTP ($NTP_IP).  Now switch to hostname-only
# (ntp.example.com) to force a real MachineConfig change → MCO reboot.
# This exercises the Phase 1 MCP wait in day2-config-ntp.sh.
test_begin "NTP: day2 and chronyc verify"

e2e_run_remote "Change NTP in cluster.conf to hostnames only (forces MachineConfig change)" \
    "cd ~/aba && aba -d $SNO --ntp ntp.example.com ntp.lan"

e2e_run_remote "Apply day2 NTP config" \
    "cd ~/aba && aba --dir $SNO day2-ntp"

e2e_run_remote "Verify chrony.conf contains ntp.example.com" \
    "cd ~/aba && aba --dir $SNO ssh --cmd 'cat /etc/chrony.conf' | grep 'server ntp.example.com iburst'"

e2e_run_remote "Verify chrony.conf contains ntp.lan" \
    "cd ~/aba && aba --dir $SNO ssh --cmd 'cat /etc/chrony.conf' | grep 'server ntp.lan iburst'"

e2e_run_remote "Verify old NTP IP no longer in chrony.conf" \
    "cd ~/aba && aba --dir $SNO ssh --cmd 'cat /etc/chrony.conf' | grep -v '$NTP_IP'"

test_end

# ============================================================================
# 15. Delete cluster
# ============================================================================
test_begin "Delete cluster"

e2e_run_remote "Delete SNO cluster" \
    "cd ~/aba && aba --dir $SNO delete"
e2e_remove_from_cluster_cleanup "$PWD/$SNO" remote
e2e_run_remote "Clean SNO cluster dir" \
    "cd ~/aba && rm -rf $SNO"

test_end

# ============================================================================
# End-of-suite cleanup: deregister pool registry on both conN and disN
# ============================================================================
test_begin "Cleanup: deregister pool registry"

e2e_run "Deregister pool registry on conN" \
    "aba -d mirror unregister"
e2e_run_remote "Deregister pool registry on disN" \
    "cd ~/aba && aba -d mirror unregister"

# Purge extra blobs (ACM, service-mesh, vote-app, etc.) loaded during this suite.
# Without this, ~37GB of stale blobs accumulate and starve disk for the next suite.
e2e_run "Purge extra images from pool registry" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

suite_end; _rc=$?

exit $_rc
