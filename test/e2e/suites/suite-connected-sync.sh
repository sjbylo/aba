#!/bin/bash
# =============================================================================
# Suite: Connected Sync (rewrite of test1)
# =============================================================================
# Purpose: Connected bastion installs registry remotely and syncs images,
#          then save/load roundtrip. Tests firewalld integration, testy user
#          re-install, and bare-metal ISO simulation.
#
# Prerequisite: Internet-connected host with aba installed.
#               Internal bastion VM available for registry install.
# =============================================================================

set -euo pipefail

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

INT_BASTION="${INT_BASTION_HOST:-registry.example.com}"
INT_BASTION_VM="${INT_BASTION_VM:-bastion-internal-${INTERNAL_BASTION_RHEL_VER:-rhel9}}"
INTERNAL_BASTION="${TEST_USER:-steve}@${INT_BASTION}"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Setup: init internal bastion VM" \
    "Firewalld: bring down and sync" \
    "Firewalld: bring up and verify port" \
    "ABI config: sno/compact/standard" \
    "SNO: install cluster" \
    "Save/Load: roundtrip" \
    "SNO: re-install after save/load" \
    "Testy user: re-sync with custom mirror conf" \
    "Bare-metal: ISO simulation"

suite_begin "connected-sync"

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch --platform vmw --op-sets abatest

e2e_run "Install aba" "./install"
e2e_run "Install aba (verify idempotent)" "../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

e2e_run "Configure aba.conf" "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l}"
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

test_end 0

# ============================================================================
# 2. Setup: init internal bastion VM
# ============================================================================
test_begin "Setup: init internal bastion VM"

export subdir=\~/subdir
setup_bastion "$INT_BASTION" "$INT_BASTION_VM"

test_end 0

# ============================================================================
# 3. Firewalld: bring down, sync, bring up, verify port
# ============================================================================
test_begin "Firewalld: bring down and sync"

e2e_run "Show firewalld status" \
    "ssh ${INTERNAL_BASTION} 'sudo firewall-offline-cmd --list-all; sudo systemctl status firewalld || true'"
e2e_run "Bring down firewalld" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl disable firewalld; sudo systemctl stop firewalld'"
e2e_run "Show firewalld status (should be down)" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl status firewalld || true'"

e2e_run -r 15 3 "Sync images to remote registry" \
    "aba -d mirror sync --retry -H $INT_BASTION -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'"

e2e_run "Check oc-mirror cache location (local)" \
    "sudo find ~/ -name '.cache' -path '*/.oc-mirror/*' 2>/dev/null || true"
e2e_run "Check oc-mirror cache location (remote)" \
    "ssh ${INTERNAL_BASTION} 'sudo find ~/ -name .cache -path \"*/.oc-mirror/*\" 2>/dev/null || true'"

test_end 0

test_begin "Firewalld: bring up and verify port"

e2e_run "Bring up firewalld" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl enable firewalld; sudo systemctl start firewalld'"
e2e_run "Show firewalld status (should be up)" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl status firewalld || true'"
e2e_run "Verify port 8443 is open" \
    "ssh ${INTERNAL_BASTION} 'sudo firewall-cmd --list-all | grep \"ports: .*8443/tcp\"'"

test_end 0

# ============================================================================
# 4. ABI config: generate and verify agent configs for sno/compact/standard
# ============================================================================
test_begin "ABI config: sno/compact/standard"

for cname in sno compact standard; do
    local_starting_ip=""
    [ "$cname" = "sno" ] && local_starting_ip=10.0.1.201
    [ "$cname" = "compact" ] && local_starting_ip=10.0.1.71
    [ "$cname" = "standard" ] && local_starting_ip=10.0.1.81

    e2e_run "Create cluster.conf for $cname" \
        "rm -rf $cname && aba cluster -n $cname -t $cname -i $local_starting_ip --step cluster.conf"
    e2e_run "Fix mac_prefix for $cname" \
        "sed -i 's#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g' $cname/cluster.conf"
    e2e_run "Generate install-config.yaml for $cname" \
        "aba --dir $cname install-config.yaml"
    e2e_run "Generate agent-config.yaml for $cname" \
        "aba --dir $cname agent-config.yaml"
    e2e_run "Generate ISO for $cname" \
        "aba --dir $cname iso"
done

test_end 0

# ============================================================================
# 5. SNO: install cluster from synced mirror
# ============================================================================
test_begin "SNO: install cluster"

e2e_run "Clean up previous sno" "rm -rf sno"
e2e_run "Create and install SNO cluster" \
    "aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step install"
e2e_run "Verify cluster operators" "aba --dir sno run"
e2e_run -i "Delete SNO cluster" "aba --dir sno delete"

test_end 0

# ============================================================================
# 6. Save/Load roundtrip
# ============================================================================
test_begin "Save/Load: roundtrip"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run "Verify registry removed" \
    "ssh ${INTERNAL_BASTION} 'podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$'"

e2e_run -r 15 3 "Save and load images" "aba --dir mirror save load"

e2e_run "Check oc-mirror cache (local)" \
    "sudo find ~/ -name '.cache' -path '*/.oc-mirror/*' 2>/dev/null || true"

test_end 0

# ============================================================================
# 7. SNO: re-install after save/load
# ============================================================================
test_begin "SNO: re-install after save/load"

e2e_run "Clean sno directory" "aba --dir sno clean; rm -f sno/cluster.conf"
e2e_run "Test small CIDR 10.0.1.200/30" \
    "aba cluster -n sno -t sno --starting-ip 10.0.1.201 --machine-network '10.0.1.200/30' --step iso"
e2e_run "Clean and recreate with normal CIDR" "rm -rf sno"
e2e_run "Create and install SNO" \
    "aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step install --machine-network 10.0.0.0/20"
e2e_run "Verify cluster operators" "aba --dir sno run"

test_end 0

# ============================================================================
# 8. Testy user: re-sync with custom mirror configuration
# ============================================================================
test_begin "Testy user: re-sync with custom mirror conf"

e2e_run "Uninstall registry" "aba --dir mirror uninstall"
e2e_run -r 15 3 "Save and reload images" "aba --dir mirror save load"

# Configure for testy user
e2e_run "Set data_dir in mirror.conf" "aba -d mirror --data-dir '~/my-quay-mirror-test1'"
e2e_run "Set empty reg_pw" "aba -d mirror --reg-password"
e2e_run "Set reg_path=my/path" "aba -d mirror --reg-path my/path"
e2e_run "Set reg_user=myuser" "aba -d mirror --reg-user myuser"
e2e_run "Set reg_ssh_user=testy" "aba -d mirror --reg-ssh-user testy"
e2e_run "Set reg_ssh_key" "aba -d mirror --reg-ssh-key '~/.ssh/testy_rsa'"
e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

e2e_run "Clean saved data" "rm -rf mirror/save"
e2e_run -r 15 3 "Sync images with testy user config" "aba --dir mirror sync --retry"

# Re-install SNO with testy config
e2e_run "Clean sno" "aba --dir sno clean; rm -f sno/cluster.conf"
e2e_run "Install SNO" "aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step install"
e2e_run "Verify operators" "aba --dir sno run"
e2e_run -i "Shutdown cluster" "yes | aba --dir sno shutdown --wait"

test_end 0

# ============================================================================
# 9. Bare-metal: ISO simulation
# ============================================================================
test_begin "Bare-metal: ISO simulation"

e2e_run "Set platform=bm" "aba --platform bm"

e2e_run "Remove govc to test download-all" "rm -f cli/govc*"
e2e_run "Verify govc tar missing" "! test -f cli/govc*gz"
e2e_run "Run download-all (should re-download govc)" "aba -d cli download-all"
e2e_run "Verify govc tar exists" "test -f cli/govc*gz"

e2e_run "Clean standard dir" "rm -rf standard"
e2e_run "Create agent configs (bare-metal)" \
    "aba cluster -n standard -t standard -i 10.0.1.81 -s install"
e2e_run "Verify cluster.conf" "ls -l standard/cluster.conf"
e2e_run "Verify agent configs" "ls -l standard/install-config.yaml standard/agent-config.yaml"
e2e_run "Verify ISO not yet created" "! ls -l standard/iso-agent-based/agent.*.iso 2>/dev/null"
e2e_run "Create ISO (bare-metal)" "aba --dir standard install"
e2e_run "Verify ISO created" "ls -l standard/iso-agent-based/agent.*.iso"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run "Verify registry removed" \
    "ssh ${INTERNAL_BASTION} 'podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$'"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-connected-sync.sh"
