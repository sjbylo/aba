#!/usr/bin/env bash
# =============================================================================
# Suite: Mirror Sync
# =============================================================================
# Purpose: Tests mirroring operations: sync to remote registry with firewalld
#          integration, save/load roundtrip, custom OC_MIRROR_CACHE, testy user
#          re-sync with custom mirror config, and bare-metal ISO simulation.
#
# Prerequisite: Internet-connected host with aba installed.
#               Internal bastion VM available for registry install.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-ops.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"
STANDARD="$(pool_cluster_name standard)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Docker e2e-mirror-docker1: install and verify" \
    "Firewalld: port persistence" \
    "OC_MIRROR_CACHE: custom cache location" \
    "Save/Load: roundtrip" \
    "SNO: bootstrap after save/load" \
    "Testy user: re-sync with custom mirror conf" \
    "Bare-metal: ISO simulation" \
    "Bare-metal: full OOB SNO install" \
    "Cleanup: delete clusters and uninstall mirrors"

suite_begin "mirror-sync"

preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_install_aba

e2e_run "Remove oc-mirror caches" \
    "sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror | xargs sudo rm -rf"

e2e_run "Install aba (verify idempotent)" "../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

e2e_run "Configure aba.conf" "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER in vmware.conf" "sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Verify vmware.conf" "grep ^GOVC_URL= vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Verify aba.conf: ntp_servers" "grep '^ntp_servers=.*$NTP_IP' aba.conf"
e2e_run "Set operator sets" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"
e2e_run "Verify aba.conf: op_sets" "grep '^op_sets=abatest' aba.conf"

e2e_run "Basic interactive test" "test/basic-interactive-test.sh"

e2e_run "Re-apply ask=false after interactive test" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets (re-apply)" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Create mirror.conf for later tests" "aba -d mirror mirror.conf"
e2e_diag "Show aba.conf" "grep -E '^\w' aba.conf"
e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"

test_end

# ============================================================================
# 2. Docker e2e-mirror-docker1: install and verify (firewalld stays UP)
# ============================================================================
test_begin "Docker e2e-mirror-docker1: install and verify"

# Negative path: sync without pull secret should fail
e2e_run -q "Hide pull secret for must-fail test" \
    "mv ~/.pull-secret.json ~/.pull-secret.json.bak"
e2e_run_must_fail "Sync without pull secret should fail" \
    "aba -d mirror sync --retry -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/e2e-test-neg-datadir'"
e2e_run -q "Clean up data-dir side effect from must-fail test" \
    "rm -rf ~/e2e-test-neg-datadir"
e2e_run -q "Restore pull secret" \
    "mv ~/.pull-secret.json.bak ~/.pull-secret.json"

# Create e2e-mirror-docker1 and install Docker registry on disN (port 5000).
# Full image sync is skipped here: rootless podman 4.x on RHEL 8 has a lock
# corruption bug under high concurrent I/O that crashes the container.
# Image sync is already covered by the Quay registry tests (save/load).
e2e_run "Create e2e-mirror-docker1 dir" "aba mirror --name e2e-mirror-docker1"
e2e_add_to_mirror_cleanup "$PWD/e2e-mirror-docker1"
e2e_run "Install Docker registry on remote host" \
    "aba -d e2e-mirror-docker1 install --vendor docker --reg-port 5000 --reg-user e2euser --reg-password e2epass --data-dir '~/e2e-mirror-datadir2' -H $DIS_HOST -k ~/.ssh/id_rsa"
e2e_run "Verify e2e-mirror-docker1 registry access" "aba -d e2e-mirror-docker1 verify"

# Idempotent install: re-running install on a healthy registry must succeed
e2e_run "Idempotent install (registry already running)" \
    "aba -d e2e-mirror-docker1 install"
e2e_run "Edit mirror.conf while registry is running" \
    "aba -d e2e-mirror-docker1 --reg-path my/new/path"
e2e_run "Install after mirror.conf edit must succeed" \
    "aba -d e2e-mirror-docker1 install"
e2e_run "Verify registry still accessible after idempotent install" \
    "aba -d e2e-mirror-docker1 verify"

test_end

# ============================================================================
# 3. Firewalld: verify port rule persists across firewalld restart
# ============================================================================
test_begin "Firewalld: port persistence"

e2e_diag_remote "Show firewalld status before cycle" \
    "sudo systemctl status firewalld; sudo firewall-cmd --list-all"
e2e_run_remote "Stop firewalld" \
    "sudo systemctl stop firewalld"
e2e_run_remote "Start firewalld" \
    "sudo systemctl enable firewalld; sudo systemctl start firewalld"
e2e_run_remote "Verify port 5000 persisted across restart" \
    "sudo firewall-cmd --list-all | grep 'ports: .*5000/tcp'"

test_end

# ============================================================================
# 4. OC_MIRROR_CACHE: verify custom cache directory
# ============================================================================
test_begin "OC_MIRROR_CACHE: custom cache location"

e2e_run "Create custom cache dir" "mkdir -pv \$HOME/.custom_oc_mirror_cache"
e2e_run -q "Clean custom cache dir" "rm -rf \$HOME/.custom_oc_mirror_cache/*"

e2e_run -r 3 2 "Verify OC_MIRROR_CACHE env var is respected" \
    "export OC_MIRROR_CACHE=\$HOME/.custom_oc_mirror_cache && aba -d mirror save --retry && test -d \$HOME/.custom_oc_mirror_cache/.oc-mirror"

e2e_run -q "Clean up custom cache dir" "rm -rf \$HOME/.custom_oc_mirror_cache"

test_end

# ============================================================================
# 5. Save/Load roundtrip
# ============================================================================
test_begin "Save/Load: roundtrip"

e2e_run "Uninstall e2e-mirror-docker1 registry" "aba --dir e2e-mirror-docker1 uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"

e2e_run "Run e2e-mirror-docker1 reset" "aba --dir e2e-mirror-docker1 reset --force"

# Mirror reset regression: verify reset clears binary and re-extraction works
e2e_run "Run mirror reset" "aba --dir mirror reset --force"
# No need to manually clear ~/.aba/mirror/mirror/ — pre-suite cleanup
# (_cleanup_con_registry) already removed it.
e2e_run "Verify mirror-registry binary removed by reset" \
    "test ! -f mirror/mirror-registry"
e2e_run "Re-extract mirror-registry after reset" "make -C mirror mirror-registry"
e2e_run "Verify mirror-registry exists after re-extract" \
    "test -x mirror/mirror-registry"
# mirror.conf is destroyed by reset; re-create and reconfigure for remote registry
e2e_run "Re-create mirror.conf after reset" "make -C mirror mirror.conf"
e2e_run "Reconfigure remote registry after reset" \
    "aba -d mirror -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/e2e-mirror-datadir1'"
e2e_diag "Show mirror.conf after reset+reconfigure" "grep -E '^\w' mirror/mirror.conf"

# Registries.d sigstore config test: verify the config file is deployed
# and that oc-mirror works without --remove-signatures (relying on
# the per-registry sigstore rules in aba-sigstore.yaml).
e2e_run "Verify aba-sigstore.yaml deployed" \
    "test -f \$HOME/.config/containers/registries.d/aba-sigstore.yaml"

# Ensure OC_MIRROR_FLAGS is not set (registries.d handles sigstore now)
e2e_run -q "Ensure OC_MIRROR_FLAGS is unset in ~/.aba/config" \
    "if grep -q '^OC_MIRROR_FLAGS=' \$HOME/.aba/config; then
         sed -i 's/^OC_MIRROR_FLAGS=/#OC_MIRROR_FLAGS=/' \$HOME/.aba/config
     fi"

# Save/load reinstall regression: verify save+load auto-reinstalls the
# registry when it was uninstalled (ported from old test1 lines 376-380).
e2e_add_to_mirror_cleanup "$PWD/mirror"
e2e_run -r 3 2 "Save and load (should reinstall registry)" "aba --dir mirror save load --retry"

# Verify --remove-signatures is NOT active in OC_MIRROR_FLAGS
e2e_run "Verify no active --remove-signatures in config" \
    "! grep -q '^OC_MIRROR_FLAGS=.*--remove-signatures' \$HOME/.aba/config"

e2e_diag "Check oc-mirror cache (local)" \
    "sudo find /root/ /home/ -maxdepth 4 -name '.cache' -path '*/.oc-mirror/*'"

test_end

# ============================================================================
# 6. SNO: bootstrap after save/load (smoke test)
# ============================================================================
test_begin "SNO: bootstrap after save/load"

e2e_run "Clean sno cluster directory" "if [ -d $SNO ]; then aba --dir $SNO reset --force; fi"

# CIDR variation tests (ported from old test1 lines 353-360)
e2e_run "Test /29 small CIDR (cluster.conf)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '$(pool_small_cidr)' --step cluster.conf"
e2e_run "Verify /29 CIDR in cluster.conf" \
    "grep 'machine_network=.*/' $SNO/cluster.conf"
e2e_run "Test /29 small CIDR (ISO creation)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '$(pool_small_cidr)' --step iso"
e2e_run "Clean for /30 CIDR test" "if [ -d $SNO ]; then aba --dir $SNO reset --force; fi"

e2e_run "Test /30 CIDR (cluster.conf)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '$(pool_sno_ip)/30' --step cluster.conf"
e2e_run "Verify /30 CIDR in cluster.conf" \
    "grep 'machine_network=.*/30' $SNO/cluster.conf"
e2e_run "Clean for /20 CIDR test" "if [ -d $SNO ]; then aba --dir $SNO reset --force; fi"

e2e_run "Test /20 large CIDR (cluster.conf + ISO)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '10.0.0.0/20' --step iso"
e2e_run "Verify /20 CIDR in cluster.conf" \
    "grep 'machine_network=10.0.0.0/20' $SNO/cluster.conf"

e2e_run "Clean and recreate with pool CIDR for install" "if [ -d $SNO ]; then aba --dir $SNO reset --force; fi"
e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Create SNO and generate ISO" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install --machine-network $(pool_machine_network)"
e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_wait_cluster_ready $SNO
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Delete SNO cluster" "aba --dir $SNO delete"
e2e_remove_from_cluster_cleanup "$PWD/$SNO"

test_end

# ============================================================================
# 7. Testy user: re-sync with custom mirror configuration
# ============================================================================
test_begin "Testy user: re-sync with custom mirror conf"

_marker_snap() { echo "--- mirror/ markers ---"; ls -la mirror/.available mirror/.unavailable 2>&1; echo "--- state.sh ---"; cat ~/.aba/mirror/mirror/state.sh || echo "(absent)"; }

e2e_diag "Markers: before uninstall-1" "_marker_snap"
e2e_run "Uninstall registry" "aba --dir mirror uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"
e2e_diag "Markers: after uninstall-1" "_marker_snap"

e2e_run -r 3 2 "Save and reload images (should install mirror)" "aba --dir mirror save load --retry"
e2e_diag "Markers: after save-load" "_marker_snap"

# Uninstall before changing mirror.conf: this test intentionally wants a
# fresh install with completely different settings (data_dir, ssh_user,
# ssh_key, reg_user).  Since reg_detect_existing() now skips install
# when the registry is healthy, we must explicitly uninstall to get a
# fresh install with the new configuration.
e2e_diag "Markers: before uninstall-2" "_marker_snap"
e2e_run "Uninstall registry before config change" "aba --dir mirror uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"
e2e_diag "Markers: after uninstall-2" "_marker_snap"

e2e_run "Set data_dir in mirror.conf" "aba -d mirror --data-dir '~/e2e-mirror-datadir1'"
e2e_run "Set empty reg_pw" "aba -d mirror --reg-password"
e2e_run "Set reg_path=my/path" "aba -d mirror --reg-path my/path"
e2e_run "Set reg_user=myuser" "aba -d mirror --reg-user myuser"
e2e_run "Set reg_ssh_user=testy" "aba -d mirror --reg-ssh-user testy"
e2e_run "Set reg_ssh_key" "aba -d mirror --reg-ssh-key '~/.ssh/testy_rsa'"
e2e_run "Override ops in mirror.conf (exercises mirror.conf ops override)" \
    "sed -i '/^#ops=/c\\ops=web-terminal' mirror/mirror.conf"
e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

e2e_run "Clean mirror working state" "aba -d mirror clean"
e2e_diag "Markers: before sync" "_marker_snap"
e2e_add_to_mirror_cleanup "$PWD/mirror"
e2e_run -r 3 2 "Sync images with testy user config (should install mirror)" "aba --dir mirror sync --retry"

# Connected mode: ~/.docker/config.json must have BOTH mirror AND Red Hat credentials
e2e_run "Pull secret: mirror registry present in config.json" \
    "jq -e '.auths[\"${DIS_HOST}:8443\"]' ~/.docker/config.json"
e2e_run "Pull secret: registry.redhat.io present (connected mode)" \
    "jq -e '.auths[\"registry.redhat.io\"]' ~/.docker/config.json"
e2e_run "Pull secret: quay.io present (connected mode)" \
    "jq -e '.auths[\"quay.io\"]' ~/.docker/config.json"

e2e_run "Clean sno cluster dir" "if [ -d $SNO ]; then aba --dir $SNO reset --force; fi"
e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Install SNO" "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_wait_cluster_ready $SNO
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Apply day2 config" "aba --dir $SNO day2"
e2e_run "Verify CatalogSources present after day2" \
    "aba --dir $SNO run --cmd 'oc get catalogsource -n openshift-marketplace --no-headers' | grep ."
e2e_run "Delete cluster" "aba --dir $SNO delete"
e2e_remove_from_cluster_cleanup "$PWD/$SNO"

test_end

# ============================================================================
# 8. Bare-metal: ISO simulation (two-step install)
#
#    Tests the BM two-step install flow from the SYNC perspective:
#      - govc download-all behavior with platform=bm
#      - Two-step bare-metal install (agent configs -> ISO)
#
#    Runs on con (connected bastion) because `aba mirror sync` was done from
#    here, so the registry on dis IS reachable (DNS + network route exist).
#
#    The companion BM test in suite-create-bundle-to-disk.sh covers the same
#    two-step flow from the BUNDLE-LOAD perspective (runs on internal bastion
#    because the registry was loaded there and is not reachable from con).
#    Both tests are kept for defense-in-depth.
#
#    BM two-step flow (controlled by .bm-message / .bm-nextstep gate files):
#      1st `aba install` -> creates agent configs, prints "Check & edit"
#      2nd `aba install` -> creates ISO, prints "Boot your servers"
#      (3rd would monitor cluster -- not tested since no real BM servers)
# ============================================================================
test_begin "Bare-metal: ISO simulation"

e2e_run "Set platform=bm" "aba --platform bm"
e2e_run "Verify aba.conf: platform=bm" "grep ^platform=bm aba.conf"

e2e_run "Remove govc to test download-all" "rm -f cli/govc*"
e2e_run "Verify govc tar missing" "! test -f cli/govc*gz"
e2e_run "Run download-all (should re-download govc)" "aba -d cli download-all"
e2e_run "Verify govc tar exists" "test -f cli/govc*gz"

# $STANDARD is only ever created under platform=bm (no VMs) -- rm -rf is correct
e2e_run "Clean any leftover $STANDARD cluster dir" "rm -rf $STANDARD"
e2e_add_to_cluster_cleanup "$PWD/$STANDARD"
e2e_run "Create agent configs (bare-metal)" \
    "aba cluster -n $STANDARD -t standard -i $(pool_starting_ip standard) --num-workers 2 -s agentconf"
e2e_run "Verify cluster.conf" "ls -l $STANDARD/cluster.conf"
e2e_run "Verify agent configs" "ls -l $STANDARD/install-config.yaml $STANDARD/agent-config.yaml"
e2e_run "Verify ISO not yet created" "! ls $STANDARD/iso-agent-based/agent.*.iso"

# Phase 1: "aba install" stops after agent configs, shows MAC review instructions
e2e_run "First aba install (generates configs, stops for MAC review)" \
    "aba --dir $STANDARD install 2>&1 | tee /tmp/bm-phase1.out && grep 'Check & edit' /tmp/bm-phase1.out"
e2e_run "Verify .bm-message exists" "test -f $STANDARD/.bm-message"
e2e_run "Verify ISO not yet created (still)" "! ls $STANDARD/iso-agent-based/agent.*.iso"

# Phase 2: "aba install" creates ISO, shows boot instructions
e2e_run "Second aba install (creates ISO, stops for server boot)" \
    "aba --dir $STANDARD install 2>&1 | tee /tmp/bm-phase2.out && grep 'Boot your servers' /tmp/bm-phase2.out"
e2e_run "Verify .bm-nextstep exists" "test -f $STANDARD/.bm-nextstep"
e2e_run "Verify ISO created" "ls -l $STANDARD/iso-agent-based/agent.*.iso"
e2e_run "Clean standard cluster dir (2-step done)" "rm -rf $STANDARD"
e2e_remove_from_cluster_cleanup "$PWD/$STANDARD"

test_end

# ============================================================================
# 9. Bare-metal: full 3-step OOB SNO install
#
#    Full BM install using an out-of-band VMware VM to simulate real hardware.
#    Uses the extracted vmp_* helpers from scripts/vm-vmw.sh for VM lifecycle.
#
#    3-step flow:
#      1st `aba install` -> agent configs + .bm-message
#      2nd `aba install` -> ISO          + .bm-nextstep
#      Upload ISO + create OOB VM + boot
#      3rd `aba install` -> wait-agent-up + monitor-install
# ============================================================================
test_begin "Bare-metal: full OOB SNO install"

SNO_BM="${SNO}"
_BM_MAC="00:50:56:BE:E0:01"

e2e_run "Ensure platform=bm" "aba --platform bm"
e2e_run "Verify aba.conf: platform=bm" "grep ^platform=bm aba.conf"
e2e_run "Clean any leftover $SNO_BM cluster dir" "rm -rf $SNO_BM"
e2e_add_to_cluster_cleanup "$PWD/$SNO_BM"

e2e_run "Create SNO-BM cluster.conf (reuses SNO DNS records)" \
    "aba cluster -n $SNO_BM -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"
e2e_run "Write BM MAC to macs.conf" \
    "echo '$_BM_MAC' > $SNO_BM/macs.conf"

# Phase 1: agent configs
e2e_run "BM Phase 1: generate agent configs" \
    "aba --dir $SNO_BM install 2>&1 | tee /tmp/bm3-phase1.out && grep 'Check & edit' /tmp/bm3-phase1.out"
e2e_run "Verify .bm-message exists" "test -f $SNO_BM/.bm-message"

# Phase 2: ISO
e2e_run "BM Phase 2: generate ISO" \
    "aba --dir $SNO_BM install 2>&1 | tee /tmp/bm3-phase2.out && grep 'Boot your servers' /tmp/bm3-phase2.out"
e2e_run "Verify ISO created" "ls -l $SNO_BM/iso-agent-based/agent.*.iso"

# OOB VM creation using extracted helpers.
# e2e_run evals in $HOME/aba (the aba workdir), so scripts/ is directly accessible.
# Each e2e_run command runs in a subshell; source the helpers inside each one.
_bm_iso_remote="images/agent-${SNO_BM}.iso"
_bm_vm_name="${SNO_BM}-master-0"

e2e_run "Destroy leftover OOB VM (if any)" \
    "set -a; source ~/.vmware.conf; set +a; \
     govc vm.power -off -force '$_bm_vm_name' || true; \
     govc vm.destroy '$_bm_vm_name' || true"

e2e_run "Upload BM ISO to datastore" \
    "source scripts/include_all.sh && source scripts/vm-vmw.sh && source <(normalize-vmware-conf) && \
     vmp_upload_iso $SNO_BM/iso-agent-based/agent.*.iso \$GOVC_DATASTORE '$_bm_iso_remote'"

e2e_run "Create OOB VM for BM SNO" \
    "source scripts/include_all.sh && source scripts/vm-vmw.sh && source <(normalize-vmware-conf) && \
     _folder=\${VC_FOLDER:-}; [ -n \"\${VC:-}\" ] && _folder=\"\$VC_FOLDER/$SNO_BM\"; \
     [ -n \"\${VC:-}\" ] && scripts/vmw-create-folder.sh \"\$_folder\"; \
     vmp_create_vm '$_bm_vm_name' 16 32 '$_BM_MAC' \$GOVC_DATASTORE \"\$GOVC_NETWORK\" \"\$_folder\" false"

e2e_run "Attach ISO to OOB VM" \
    "source scripts/include_all.sh && source scripts/vm-vmw.sh && source <(normalize-vmware-conf) && \
     vmp_attach_iso '$_bm_vm_name' \$GOVC_DATASTORE '$_bm_iso_remote'"

e2e_run "Power on OOB VM" \
    "source scripts/include_all.sh && source <(normalize-vmware-conf) && govc vm.power -on '$_bm_vm_name'"

# Phase 3: monitor install
e2e_run -r 2 30 "BM Phase 3: monitor cluster install" \
    "aba --dir $SNO_BM install"
e2e_run "Show cluster operator status" "aba --dir $SNO_BM run"
e2e_wait_cluster_ready "$SNO_BM"
e2e_diag "Show cluster operators" "aba --dir $SNO_BM run --cmd 'oc get co'"

# Cleanup OOB VM
e2e_run "Destroy OOB VM" \
    "source scripts/include_all.sh && source scripts/vm-vmw.sh && source <(normalize-vmware-conf) && \
     vmp_destroy '$_bm_vm_name'"
e2e_run "Remove vCenter folder for BM OOB (if vCenter)" \
    "source scripts/include_all.sh && source <(normalize-vmware-conf) && \
     [ -n \"\${VC:-}\" ] && govc object.destroy \"\$VC_FOLDER/$SNO_BM\" || true"
e2e_run "Delete BM cluster (state + dir)" "aba -y --dir $SNO_BM delete --force"
e2e_remove_from_cluster_cleanup "$PWD/$SNO_BM"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run "Assert: registry fully removed on disN" "e2e_assert_registry_removed"
e2e_run "Verify registry unreachable on disN" \
    "! curl -sk --connect-timeout 5 https://${DIS_HOST}:8443/v2/"

e2e_run "Restore platform=vmw" "aba --platform vmw"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"

test_end

# ============================================================================
# End-of-suite cleanup: delete clusters and uninstall mirrors
# ============================================================================
test_begin "Cleanup: delete clusters and uninstall mirrors"

e2e_run "Delete SNO cluster" \
    "_e2e_delete_leftover_cluster $SNO"
# $STANDARD was created under platform=bm (no VMs) -- rm -rf is correct
e2e_run "Delete standard cluster dir" "rm -rf $STANDARD"
e2e_run "Uninstall e2e-mirror-docker1 registry" \
    "if [ -d e2e-mirror-docker1 ]; then aba --dir e2e-mirror-docker1 uninstall; else echo '[cleanup] e2e-mirror-docker1 already removed'; fi"
e2e_run "Assert: registry fully removed on disN (docker1)" "e2e_assert_registry_removed"
e2e_run_remote "Remove e2e-mirror-datadir2 on disN" \
    "sudo rm -rf ~/e2e-mirror-datadir2"
e2e_run "Uninstall mirror registry on disN" \
    "aba --dir mirror uninstall"
e2e_run "Assert: registry fully removed on disN (mirror)" "e2e_assert_registry_removed"
e2e_run_remote "Remove e2e-mirror-datadir1 on disN" \
    "sudo rm -rf ~/e2e-mirror-datadir1"
e2e_run "Remove e2e-mirror-datadir1 on conN" \
    "sudo rm -rf ~/e2e-mirror-datadir1"
e2e_run_remote "Verify no leftover mirror data dirs on disN" \
    "test ! -d ~/e2e-mirror-datadir2 && test ! -d ~/e2e-mirror-datadir1"
e2e_run "Verify no leftover mirror data dirs on conN" \
    "test ! -d ~/e2e-mirror-datadir2 && test ! -d ~/e2e-mirror-datadir1"

test_end

# ============================================================================

suite_end; _rc=$?

exit $_rc
