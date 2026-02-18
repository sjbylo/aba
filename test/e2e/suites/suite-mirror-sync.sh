#!/bin/bash
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
    "Firewalld: bring down and sync" \
    "Firewalld: bring up and verify port" \
    "OC_MIRROR_CACHE: custom cache location" \
    "Save/Load: roundtrip" \
    "SNO: bootstrap after save/load" \
    "Testy user: re-sync with custom mirror conf" \
    "Bare-metal: ISO simulation"

suite_begin "mirror-sync"

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
# 3. Firewalld: bring down, sync, bring up, verify port
# ============================================================================
test_begin "Firewalld: bring down and sync"

e2e_diag "Show firewalld status" \
    "ssh ${INTERNAL_BASTION} 'sudo firewall-offline-cmd --list-all; sudo systemctl status firewalld'"
e2e_run "Bring down firewalld" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl disable firewalld; sudo systemctl stop firewalld'"
e2e_diag "Show firewalld status (should be down)" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl status firewalld'"

e2e_run -r 3 2 "Sync images to remote registry" \
    "aba -d mirror sync --retry -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'"

e2e_diag "Check oc-mirror cache location (local)" \
    "find ~/ -name '.cache' -path '*/.oc-mirror/*'"
e2e_diag_remote "Check oc-mirror cache location (remote)" \
    "find ~/ -name .cache -path '*/.oc-mirror/*'"

test_end

test_begin "Firewalld: bring up and verify port"

e2e_run "Bring up firewalld" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl enable firewalld; sudo systemctl start firewalld'"
e2e_run "Show firewalld status (should be up)" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl status firewalld'"
e2e_run "Verify port 8443 is open" \
    "ssh ${INTERNAL_BASTION} 'sudo firewall-cmd --list-all | grep \"ports: .*8443/tcp\"'"

test_end

# ============================================================================
# 4. OC_MIRROR_CACHE: verify custom cache directory
# ============================================================================
test_begin "OC_MIRROR_CACHE: custom cache location"

e2e_run "Create custom cache dir" "mkdir -pv \$HOME/.custom_oc_mirror_cache"
e2e_run -q "Clean custom cache dir" "rm -rfv \$HOME/.custom_oc_mirror_cache/*"

e2e_run "Verify OC_MIRROR_CACHE env var is respected" \
    "export OC_MIRROR_CACHE=\$HOME/.custom_oc_mirror_cache && aba -d mirror save --retry && test -d \$HOME/.custom_oc_mirror_cache/.oc-mirror"

e2e_run -q "Clean up custom cache dir" "rm -rfv \$HOME/.custom_oc_mirror_cache"

test_end

# ============================================================================
# 5. Save/Load roundtrip
# ============================================================================
test_begin "Save/Load: roundtrip"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run_remote "Verify registry removed" \
    "podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0\$"

e2e_run -r 3 2 "Save and load images" "aba --dir mirror save load"

e2e_diag "Check oc-mirror cache (local)" \
    "sudo find ~/ -name '.cache' -path '*/.oc-mirror/*'"

test_end

# ============================================================================
# 6. SNO: bootstrap after save/load (smoke test)
# ============================================================================
test_begin "SNO: bootstrap after save/load"

e2e_run "Clean sno directory" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"
e2e_run "Test small CIDR (pool-local /30)" \
    "aba cluster -n $SNO -t sno --starting-ip ${POOL_SUBNET:-10.0.2}.201 --machine-network '${POOL_SUBNET:-10.0.2}.200/30' --step iso"
e2e_run "Clean and recreate with normal CIDR" "rm -rfv $SNO"
e2e_run "Create and bootstrap SNO" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step bootstrap --machine-network $(pool_machine_network)"

test_end

# ============================================================================
# 7. Testy user: re-sync with custom mirror configuration
# ============================================================================
test_begin "Testy user: re-sync with custom mirror conf"

e2e_run "Uninstall registry" "aba --dir mirror uninstall"
e2e_run -r 3 2 "Save and reload images" "aba --dir mirror save load"

e2e_run "Set data_dir in mirror.conf" "aba -d mirror --data-dir '~/my-quay-mirror-test1'"
e2e_run "Set empty reg_pw" "aba -d mirror --reg-password"
e2e_run "Set reg_path=my/path" "aba -d mirror --reg-path my/path"
e2e_run "Set reg_user=myuser" "aba -d mirror --reg-user myuser"
e2e_run "Set reg_ssh_user=testy" "aba -d mirror --reg-ssh-user testy"
e2e_run "Set reg_ssh_key" "aba -d mirror --reg-ssh-key '~/.ssh/testy_rsa'"
e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

e2e_run "Clean saved data" "rm -rfv mirror/save"
e2e_run -r 3 2 "Sync images with testy user config" "aba --dir mirror sync --retry"

e2e_run "Clean sno" "aba --dir $SNO clean; rm -f $SNO/cluster.conf"
e2e_run "Install SNO" "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Verify operators" "aba --dir $SNO run"
e2e_run -r 30 10 "Wait for all operators fully available" \
    "aba --dir $SNO run | tail -n +2 | awk '{print \$3,\$4,\$5}' | tail -n +2 | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"
e2e_run "Shutdown cluster" "yes | aba --dir $SNO shutdown --wait"

test_end

# ============================================================================
# 8. Bare-metal: ISO simulation
# ============================================================================
test_begin "Bare-metal: ISO simulation"

e2e_run "Set platform=bm" "aba --platform bm"

e2e_run "Remove govc to test download-all" "rm -f cli/govc*"
e2e_run "Verify govc tar missing" "! test -f cli/govc*gz"
e2e_run "Run download-all (should re-download govc)" "aba -d cli download-all"
e2e_run "Verify govc tar exists" "test -f cli/govc*gz"

e2e_run "Clean standard dir" "rm -rfv $STANDARD"
e2e_run "Create agent configs (bare-metal)" \
    "aba cluster -n $STANDARD -t standard -i $(pool_standard_api_vip) -s agentconf"
e2e_run "Verify cluster.conf" "ls -l $STANDARD/cluster.conf"
e2e_run "Verify agent configs" "ls -l $STANDARD/install-config.yaml $STANDARD/agent-config.yaml"
e2e_run "Verify ISO not yet created" "! ls $STANDARD/iso-agent-based/agent.*.iso"
e2e_run "Create ISO (bare-metal)" "aba --dir $STANDARD install"
e2e_run "Verify ISO created" "ls -l $STANDARD/iso-agent-based/agent.*.iso"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run_remote "Verify registry removed" \
    "podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0\$"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-mirror-sync.sh"
