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
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
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
    "Docker mymirror: install and verify" \
    "Firewalld: port persistence" \
    "OC_MIRROR_CACHE: custom cache location" \
    "Save/Load: roundtrip" \
    "SNO: bootstrap after save/load" \
    "Testy user: re-sync with custom mirror conf" \
    "Bare-metal: ISO simulation" \
    "Cleanup: delete clusters and uninstall mirrors"

suite_begin "mirror-sync"

preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"
e2e_run "Install aba (verify idempotent)" "../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

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
e2e_run "Set operator sets" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Basic interactive test" "test/basic-interactive-test.sh"

e2e_run "Re-apply ask=false after interactive test" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets (re-apply)" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

e2e_run "Create mirror.conf for later tests" "aba -d mirror mirror.conf"

test_end

# ============================================================================
# 2. Docker mymirror: install and verify (firewalld stays UP)
# ============================================================================
test_begin "Docker mymirror: install and verify"

# Negative path: sync without pull secret should fail
e2e_run -q "Hide pull secret for must-fail test" \
    "mv ~/.pull-secret.json ~/.pull-secret.json.bak"
e2e_run_must_fail "Sync without pull secret should fail" \
    "aba -d mirror sync --retry -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'"
e2e_run -q "Restore pull secret" \
    "mv ~/.pull-secret.json.bak ~/.pull-secret.json"

# Create mymirror and install Docker registry on disN (port 5000).
# Full image sync is skipped here: rootless podman 4.x on RHEL 8 has a lock
# corruption bug under high concurrent I/O that crashes the container.
# Image sync is already covered by the Quay registry tests (save/load).
e2e_run "Create mymirror dir" "aba mirror --name mymirror"
e2e_add_to_mirror_cleanup "$PWD/mymirror"
e2e_run "Install Docker registry on remote host" \
    "aba -d mymirror install --vendor docker --reg-port 5000 --reg-user e2euser --reg-password e2epass --data-dir '~/mymirror-data' -H $DIS_HOST -k ~/.ssh/id_rsa"
e2e_run "Verify mymirror registry access" "aba -d mymirror verify"

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

e2e_run "Uninstall mymirror registry" "aba --dir mymirror uninstall"
e2e_run_remote "Verify registry removed" \
    "podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0\$"

e2e_run "Run mymirror reset" "aba --dir mymirror reset --force"

# Mirror reset regression: verify reset clears binary and re-extraction works
e2e_run "Run mirror reset" "aba --dir mirror reset --force"
# No need to manually clear ~/.aba/mirror/mirror/ — pre-suite cleanup
# (_cleanup_con_quay) already removed it.
e2e_run "Verify mirror-registry binary removed by reset" \
    "test ! -f mirror/mirror-registry"
e2e_run "Re-extract mirror-registry after reset" "make -C mirror mirror-registry"
e2e_run "Verify mirror-registry exists after re-extract" \
    "test -x mirror/mirror-registry"
# mirror.conf is destroyed by reset; re-create and reconfigure for remote registry
e2e_run "Re-create mirror.conf after reset" "make -C mirror mirror.conf"
e2e_run "Reconfigure remote registry after reset" \
    "aba -d mirror -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'"

# Save/load reinstall regression: verify save+load auto-reinstalls the
# registry when it was uninstalled (ported from old test1 lines 376-380).
e2e_run -r 3 2 "Save and load (should reinstall registry)" "aba --dir mirror save load --retry"

e2e_diag "Check oc-mirror cache (local)" \
    "sudo find ~/ -name '.cache' -path '*/.oc-mirror/*'"

test_end

# ============================================================================
# 6. SNO: bootstrap after save/load (smoke test)
# ============================================================================
test_begin "SNO: bootstrap after save/load"

e2e_run "Clean sno cluster directory" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"

# CIDR variation tests (ported from old test1 lines 353-360)
e2e_run "Test /29 small CIDR (cluster.conf)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '$(pool_small_cidr)' --step cluster.conf"
e2e_run "Verify /29 CIDR in cluster.conf" \
    "grep 'machine_network=.*/' $SNO/cluster.conf"
e2e_run "Test /29 small CIDR (ISO creation)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '$(pool_small_cidr)' --step iso"
e2e_run "Clean for /30 CIDR test" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"

e2e_run "Test /30 CIDR (cluster.conf)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '$(pool_sno_ip)/30' --step cluster.conf"
e2e_run "Verify /30 CIDR in cluster.conf" \
    "grep 'machine_network=.*/30' $SNO/cluster.conf"
e2e_run "Clean for /20 CIDR test" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"

e2e_run "Test /20 large CIDR (cluster.conf + ISO)" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --machine-network '10.0.0.0/20' --step iso"
e2e_run "Verify /20 CIDR in cluster.conf" \
    "grep 'machine_network=10.0.0.0/20' $SNO/cluster.conf"

e2e_run "Clean and recreate with pool CIDR for install" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"
e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Create SNO and generate ISO" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install --machine-network $(pool_machine_network)"
e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Delete SNO cluster" "aba --dir $SNO delete"

test_end

# ============================================================================
# 7. Testy user: re-sync with custom mirror configuration
# ============================================================================
test_begin "Testy user: re-sync with custom mirror conf"

e2e_run "Uninstall registry" "aba --dir mirror uninstall"
e2e_run -r 3 2 "Save and reload images" "aba --dir mirror save load --retry"

# Uninstall before changing mirror.conf: config changes make mirror.conf newer
# than .available, so Make would try to reinstall.  reg_detect_existing() aborts
# if a registry is already installed at this host.  Uninstall first, change
# config, then sync (which triggers a fresh install with the new settings).
e2e_run "Uninstall registry before config change" "aba --dir mirror uninstall"

e2e_run "Set data_dir in mirror.conf" "aba -d mirror --data-dir '~/my-quay-mirror-test1'"
e2e_run "Set empty reg_pw" "aba -d mirror --reg-password"
e2e_run "Set reg_path=my/path" "aba -d mirror --reg-path my/path"
e2e_run "Set reg_user=myuser" "aba -d mirror --reg-user myuser"
e2e_run "Set reg_ssh_user=testy" "aba -d mirror --reg-ssh-user testy"
e2e_run "Set reg_ssh_key" "aba -d mirror --reg-ssh-key '~/.ssh/testy_rsa'"
e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

e2e_run "Clean saved data" "rm -rf mirror/save"
e2e_run -r 3 2 "Sync images with testy user config" "aba --dir mirror sync --retry"

e2e_run "Clean sno cluster dir" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"
e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Install SNO" "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Apply day2 config" "aba --dir $SNO day2"
e2e_run "Delete cluster" "aba --dir $SNO delete"

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

e2e_run "Remove govc to test download-all" "rm -f cli/govc*"
e2e_run "Verify govc tar missing" "! test -f cli/govc*gz"
e2e_run "Run download-all (should re-download govc)" "aba -d cli download-all"
e2e_run "Verify govc tar exists" "test -f cli/govc*gz"

e2e_run "Clean standard cluster dir" "rm -rf $STANDARD"
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

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run_remote "Verify no registry containers on disN" \
    "podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0\$"
e2e_run "Verify registry unreachable on disN" \
    "! curl -sk --connect-timeout 5 https://${DIS_HOST}:8443/v2/"

test_end

# ============================================================================
# End-of-suite cleanup: delete clusters and uninstall mirrors
# ============================================================================
test_begin "Cleanup: delete clusters and uninstall mirrors"

e2e_run "Delete SNO cluster" \
    "if [ -d $SNO ]; then aba --dir $SNO delete; else echo '[cleanup] $SNO already removed'; fi"
e2e_run "Delete standard cluster" \
    "if [ -d $STANDARD ]; then aba --dir $STANDARD delete; else echo '[cleanup] $STANDARD already removed'; fi"
e2e_run "Uninstall mymirror registry" \
    "if [ -d mymirror ]; then aba --dir mymirror uninstall; else echo '[cleanup] mymirror already removed'; fi"
e2e_run "Uninstall mirror registry on disN" \
    "aba --dir mirror uninstall"
e2e_run_remote "Verify no registry containers on disN" \
    "podman ps | grep -v -e quay -e registry -e CONTAINER | wc -l | grep ^0\$"

e2e_run "Verify /home disk usage < 10GB after cleanup" \
    "used_gb=\$(df /home --output=used -BG | tail -1 | tr -d ' G'); echo \"[cleanup] /home used: \${used_gb}GB\"; [ \$used_gb -lt 10 ]"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-mirror-sync.sh"
