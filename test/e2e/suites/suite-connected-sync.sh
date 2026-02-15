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

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------
# L commands run on conN (this host). R commands SSH to disN.

DIS_HOST="dis${POOL_NUM:-1}.${VM_BASE_DOMAIN:-example.com}"
INTERNAL_BASTION="$(pool_internal_bastion)"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: install aba and configure" \
    "Setup: reset internal bastion" \
    "Firewalld: bring down and sync" \
    "Firewalld: bring up and verify port" \
    "OC_MIRROR_CACHE: custom cache location" \
    "ABI config: sno/compact/standard" \
    "ABI config: diff against known-good examples" \
    "SNO: install cluster" \
    "Save/Load: roundtrip" \
    "SNO: re-install after save/load" \
    "Testy user: re-sync with custom mirror conf" \
    "Bare-metal: ISO simulation"

suite_begin "connected-sync"

# Pre-flight: abort immediately if the internal bastion (disN) is unreachable
preflight_ssh

# ============================================================================
# 1. Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

setup_aba_from_scratch

e2e_run "Install aba" "./install"
e2e_run "Install aba (verify idempotent)" "../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

e2e_run "Configure aba.conf" "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l} --base-domain $(pool_domain)"
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

# basic-interactive-test.sh runs "aba reset -f" which wipes aba.conf back to
# defaults (ask=true, editor=vi).  Re-apply our non-interactive settings so
# subsequent tests don't hang waiting for an editor or confirmation prompt.
e2e_run "Re-apply ask=false after interactive test" \
    "aba -A --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${VER_OVERRIDE:-l} --base-domain $(pool_domain)"
e2e_run "Copy vmware.conf (re-apply)" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER (re-apply)" \
    "sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g' vmware.conf"
e2e_run "Set NTP servers (re-apply)" "aba --ntp $NTP_IP ntp.example.com"
e2e_run "Set operator sets (re-apply)" "echo kiali-ossm > templates/operator-set-abatest && aba --op-sets abatest"

test_end

# ============================================================================
# 2. Setup: reset internal bastion (reuse clone-check's disN)
# ============================================================================
test_begin "Setup: reset internal bastion"

reset_internal_bastion

test_end

# ============================================================================
# 3. Firewalld: bring down, sync, bring up, verify port
# ============================================================================
test_begin "Firewalld: bring down and sync"

# -i: systemctl status returns non-zero when service is stopped -- that's info, not failure
e2e_run -i "Show firewalld status" \
    "ssh ${INTERNAL_BASTION} 'sudo firewall-offline-cmd --list-all; sudo systemctl status firewalld'"
e2e_run "Bring down firewalld" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl disable firewalld; sudo systemctl stop firewalld'"
# -i: systemctl status returns non-zero for stopped service (expected here)
e2e_run -i "Show firewalld status (should be down)" \
    "ssh ${INTERNAL_BASTION} 'sudo systemctl status firewalld'"

e2e_run -r 3 2 "Sync images to remote registry" \
    "aba -d mirror sync --retry -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'"

# -i: diagnostic -- cache may not exist in all configurations
e2e_run -i "Check oc-mirror cache location (local)" \
    "find ~/ -name '.cache' -path '*/.oc-mirror/*'"
e2e_run_remote -i "Check oc-mirror cache location (remote)" \
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
# 4. OC_MIRROR_CACHE: verify custom cache directory (Gap 5)
#    Test2 set OC_MIRROR_CACHE to a custom dir and verified files appeared there.
# ============================================================================
test_begin "OC_MIRROR_CACHE: custom cache location"

# The sync above used OC_MIRROR_CACHE default. Now verify the cache exists
# in the expected default location, then verify a custom path works.
e2e_run "Create custom cache dir" "mkdir -p \$HOME/.custom_oc_mirror_cache"

# Clean the custom dir to start fresh
e2e_run -q "Clean custom cache dir" "rm -rf \$HOME/.custom_oc_mirror_cache/*"

# Run a small aba mirror operation with custom OC_MIRROR_CACHE.
# The save operation will populate the cache dir.
e2e_run "Verify OC_MIRROR_CACHE env var is respected" \
    "export OC_MIRROR_CACHE=\$HOME/.custom_oc_mirror_cache && aba -d mirror save --retry && test -d \$HOME/.custom_oc_mirror_cache/.oc-mirror"

# Clean up the custom cache dir
e2e_run -q "Clean up custom cache dir" "rm -rf \$HOME/.custom_oc_mirror_cache"

test_end

# ============================================================================
# 5. ABI config: generate and verify agent configs for sno/compact/standard
# ============================================================================
test_begin "ABI config: sno/compact/standard"

for cname in sno compact standard; do
    local_starting_ip=""
    [ "$cname" = "sno" ] && local_starting_ip=$(pool_sno_ip)
    [ "$cname" = "compact" ] && local_starting_ip=$(pool_compact_api_vip)
    [ "$cname" = "standard" ] && local_starting_ip=$(pool_standard_api_vip)

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

test_end

# ============================================================================
# 6. ABI config: diff against known-good examples (Gap 2)
#    Catches template regressions by comparing generated configs against
#    committed example files in test/{sno,compact,standard}/*.example
# ============================================================================
test_begin "ABI config: diff against known-good examples"

for cname in sno compact standard; do
    # Scrub volatile/secret fields from install-config.yaml before comparing
    # (same yq/sed pipeline as old test1)
    e2e_run "Scrub $cname install-config.yaml for diff" \
        "cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.pullSecret,.platform.vsphere.vcenters[].password,.platform.vsphere.failureDomains[0].name,.platform.vsphere.failureDomains[0].region,.platform.vsphere.failureDomains[0].zone,.platform.vsphere.failureDomains[0].topology.datastore)' | sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]*$//' > test/$cname/install-config.yaml"

    # Scrub agent-config.yaml (remove trailing whitespace and blank lines)
    e2e_run -q "Scrub $cname agent-config.yaml for diff" \
        "cat $cname/agent-config.yaml | sed '/^[[:space:]]*$/d' | sed 's/[[:space:]]*$//' > test/$cname/agent-config.yaml"

    # Diff against committed example files
    e2e_run "Diff $cname install-config.yaml against example" \
        "diff test/$cname/install-config.yaml test/$cname/install-config.yaml.example"
    e2e_run "Diff $cname agent-config.yaml against example" \
        "diff test/$cname/agent-config.yaml test/$cname/agent-config.yaml.example"
done

test_end

# ============================================================================
# 7. SNO: install cluster from synced mirror
# ============================================================================
test_begin "SNO: install cluster"

e2e_run "Clean up previous sno" "rm -rf sno"
e2e_run "Create and install SNO cluster" \
    "aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Verify cluster operators" "aba --dir sno run"
# -i: cluster may not be fully up if install failed; delete is best-effort cleanup
e2e_run -i "Delete SNO cluster" "aba --dir sno delete"

test_end

# ============================================================================
# 8. Save/Load roundtrip
# ============================================================================
test_begin "Save/Load: roundtrip"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run "Verify registry removed" \
    "ssh ${INTERNAL_BASTION} 'podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$'"

e2e_run -r 3 2 "Save and load images" "aba --dir mirror save load"

# -i: diagnostic -- cache may not exist in all configurations
e2e_run -i "Check oc-mirror cache (local)" \
    "sudo find ~/ -name '.cache' -path '*/.oc-mirror/*'"

test_end

# ============================================================================
# 9. SNO: re-install after save/load
# ============================================================================
test_begin "SNO: re-install after save/load"

e2e_run "Clean sno directory" "aba --dir sno clean; rm -f sno/cluster.conf"
e2e_run "Test small CIDR 10.0.1.200/30" \
    "aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --machine-network '10.0.1.200/30' --step iso"
e2e_run "Clean and recreate with normal CIDR" "rm -rf sno"
# Bootstrap only (saves ~30 min) -- proves save/load roundtrip produced
# valid images that a cluster can boot from.  Full install was already
# done in the previous "SNO: install cluster" test.
e2e_run "Create and bootstrap SNO" \
    "aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --step bootstrap --machine-network $(pool_machine_network)"

test_end

# ============================================================================
# 8. Testy user: re-sync with custom mirror configuration
# ============================================================================
test_begin "Testy user: re-sync with custom mirror conf"

e2e_run "Uninstall registry" "aba --dir mirror uninstall"
e2e_run -r 3 2 "Save and reload images" "aba --dir mirror save load"

# Configure for testy user
e2e_run "Set data_dir in mirror.conf" "aba -d mirror --data-dir '~/my-quay-mirror-test1'"
e2e_run "Set empty reg_pw" "aba -d mirror --reg-password"
e2e_run "Set reg_path=my/path" "aba -d mirror --reg-path my/path"
e2e_run "Set reg_user=myuser" "aba -d mirror --reg-user myuser"
e2e_run "Set reg_ssh_user=testy" "aba -d mirror --reg-ssh-user testy"
e2e_run "Set reg_ssh_key" "aba -d mirror --reg-ssh-key '~/.ssh/testy_rsa'"
e2e_run "Show mirror.conf" "cat mirror/mirror.conf | cut -d'#' -f1 | sed '/^[[:space:]]*$/d'"

e2e_run "Clean saved data" "rm -rf mirror/save"
e2e_run -r 3 2 "Sync images with testy user config" "aba --dir mirror sync --retry"

# Re-install SNO with testy config
e2e_run "Clean sno" "aba --dir sno clean; rm -f sno/cluster.conf"
e2e_run "Install SNO" "aba cluster -n sno -t sno --starting-ip $(pool_sno_ip) --step install"
e2e_run "Verify operators" "aba --dir sno run"
# -i: cluster may already be stopped or partially torn down
e2e_run -i "Shutdown cluster" "yes | aba --dir sno shutdown --wait"

test_end

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
    "aba cluster -n standard -t standard -i $(pool_standard_api_vip) -s install"
e2e_run "Verify cluster.conf" "ls -l standard/cluster.conf"
e2e_run "Verify agent configs" "ls -l standard/install-config.yaml standard/agent-config.yaml"
e2e_run "Verify ISO not yet created" "! ls standard/iso-agent-based/agent.*.iso"
e2e_run "Create ISO (bare-metal)" "aba --dir standard install"
e2e_run "Verify ISO created" "ls -l standard/iso-agent-based/agent.*.iso"

e2e_run "Uninstall remote registry" "aba --dir mirror uninstall"
e2e_run "Verify registry removed" \
    "ssh ${INTERNAL_BASTION} 'podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$'"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-connected-sync.sh"
