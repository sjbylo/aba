#!/usr/bin/env bash
# =============================================================================
# Suite: VMware Lifecycle
# =============================================================================
# Purpose: End-to-end test of VMware platform support.  Exercises multi-node
#          VM provisioning (compact, standard) first for fast feedback, then
#          installs an SNO cluster and tests every VM lifecycle command ABA
#          exposes: ls, stop, start, kill, delete, refresh, upload, plus
#          the cluster-level graceful shutdown/startup.
#
# Prerequisite:
#   - Internet-connected bastion (conN) with aba installed.
#   - Pre-populated Quay on conN (via setup-pool-registry.sh).
#   - ~/.vmware.conf on conN with a working GOVC_URL, GOVC_DATACENTER,
#     GOVC_CLUSTER, GOVC_DATASTORE, GOVC_NETWORK, VC_FOLDER, and credentials.
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

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"
NAMED_MIRROR="e2e-vmw-mirror"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba, configure for VMware" \
    "Setup: configure mirror for local registry" \
    "Setup: sync images to registry" \
    "Compact: multi-node VM creation and agent bootstrap" \
    "SNO: install cluster on VMware" \
    "VM lifecycle: ls" \
    "VM lifecycle: stop (graceful)" \
    "VM lifecycle: start" \
    "VM lifecycle: kill (force poweroff)" \
    "VM lifecycle: start + cluster health after kill" \
    "Cluster-level: graceful shutdown and startup" \
    "Cleanup: delete clusters and unregister mirror"

suite_begin "vmw-lifecycle"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_install_aba
e2e_run "Configure aba.conf (temporary, for version resolution)" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Verify aba.conf: version resolved" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba, configure for VMware
# ============================================================================
test_begin "Setup: install aba, configure for VMware"

e2e_run "Install aba" "./install"

suite_configure_aba
e2e_run "Override channel to candidate (exercises non-default channel)" \
    "aba --channel candidate"

e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel=candidate" "grep ^ocp_channel=candidate aba.conf"
e2e_run "Verify aba.conf: version format" \
    "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf from home directory" \
    "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Verify vmware.conf has GOVC_URL" "grep ^GOVC_URL vmware.conf"
e2e_run "Verify vmware.conf (VC_FOLDER or ESXi)" \
    "grep -q ^VC_FOLDER= vmware.conf || grep -q ^GOVC_URL= vmware.conf"

suite_setup_ntp
e2e_run "Verify aba.conf: ntp_servers" "grep '^ntp_servers=.*$NTP_IP' aba.conf"

test_end

# ============================================================================
# 3. Configure named mirror to use local pre-populated registry
# ============================================================================
test_begin "Setup: configure mirror for local registry"

e2e_run "Create named mirror (exercises mirror_name through full pipeline)" \
    "aba mirror --name $NAMED_MIRROR"
e2e_run "Assert named mirror directory exists" \
    "test -d $NAMED_MIRROR && test -f $NAMED_MIRROR/mirror.conf"
e2e_add_to_mirror_cleanup "$PWD/$NAMED_MIRROR"

e2e_run "Set reg_host before generating pull secret (exercises --reg-host)" \
    "aba -d $NAMED_MIRROR --reg-host ${CON_HOST} --reg-port 8443"
e2e_run "Generate pool-registry pull secret via aba (keyed to CON_HOST)" \
    "printf 'init\np4ssw0rd\n' | aba -d $NAMED_MIRROR password && cp ~/.aba/mirror/$NAMED_MIRROR/pull-secret-mirror.json /tmp/pool-reg-pull-secret.json"

e2e_run "Register pool registry to named mirror (--reg-host matches pull secret)" \
    "aba -d $NAMED_MIRROR register --reg-host ${CON_HOST} --reg-port 8443 \
     --pull-secret-mirror /tmp/pool-reg-pull-secret.json \
     --ca-cert $POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify named mirror registry access" "aba -d $NAMED_MIRROR verify"
e2e_diag "Show named mirror.conf" "grep -E '^\w' $NAMED_MIRROR/mirror.conf"

test_end

# ============================================================================
# 4. Sync images to registry
# ============================================================================
test_begin "Setup: sync images to registry"

e2e_run -r 3 2 "Sync images to named mirror" "aba -d $NAMED_MIRROR sync --retry"

test_end

# ============================================================================
# 5. Compact: multi-node VM creation, network check, and bootstrap
# ============================================================================
# Validates that 3 master VMs are created with correct resources and network.
# SSHes into every node to verify network, then waits for bootstrap-complete.
# Does NOT wait for full install -- proves multi-node VMware provisioning works.
test_begin "Compact: multi-node VM creation and agent bootstrap"

e2e_run "Delete any leftover $COMPACT cluster" \
    "_e2e_delete_leftover_cluster $COMPACT"
e2e_add_to_cluster_cleanup "$PWD/$COMPACT"

e2e_run "Create compact cluster.conf (data_disk, prefixes, named mirror)" \
    "aba cluster -n $COMPACT -t compact \
     --data-disk 300 --host-prefix 20 --master-prefix xxx --worker-prefix yyy \
     --mirror-name $NAMED_MIRROR --step cluster.conf"
e2e_run "Set mac_prefix for $COMPACT (VMware range, randomized)" \
    "sed -i 's#mac_prefix=.*#mac_prefix=00:50:56:1x:xx:#g' $COMPACT/cluster.conf"
e2e_run "Verify mac_prefix set" "grep '^mac_prefix=00:50:56:1x:xx:' $COMPACT/cluster.conf"
e2e_diag "Show compact cluster.conf" "grep -E '^\w' $COMPACT/cluster.conf"

e2e_run "Generate ISO for compact cluster" "aba --dir $COMPACT iso"
e2e_run "Upload ISO to VMware datastore" "aba --dir $COMPACT upload"
e2e_run "Create and start compact VMs" "aba --dir $COMPACT create --start"

e2e_run "List compact VMs" "aba --dir $COMPACT ls"
e2e_run "Verify 3 VMs created for compact" \
    "[ \$(aba --dir $COMPACT ls | grep -c -i poweredOn) -eq 3 ]"

e2e_poll 300 15 "Wait for agent API on compact rendezvous node" \
    "curl -sk --connect-timeout 5 --max-time 5 -o /dev/null -w '%{http_code}' http://\$(cat $COMPACT/iso-agent-based/rendezvousIP):8090/ | grep -qE '^4'"

# Extract all node IPs from agent-config.yaml and SSH into each one
e2e_run "Extract compact node IPs" \
    "cd $COMPACT && eval \$(scripts/cluster-config.sh) && echo \"CP_IPS=\$CP_IP_ADDRESSES\""
for _node_idx in 0 1 2; do
    e2e_poll 300 15 "SSH into compact master $_node_idx (verify expected IP)" \
        "cd $COMPACT && source cluster.conf && eval \$(scripts/cluster-config.sh) && _ips=(\$CP_IP_ADDRESSES) && ssh -F ~/.aba/ssh.conf -i \$ssh_key_file -o ConnectTimeout=10 core@\${_ips[$_node_idx]} 'hostname && ip -4 addr show' | grep \"\${_ips[$_node_idx]}\""
done

e2e_poll 1800 30 "Wait for compact bootstrap-complete" \
    "cd $COMPACT && openshift-install agent wait-for bootstrap-complete --dir iso-agent-based 2>&1 | tail -1"
e2e_diag "Compact cluster VMs after bootstrap" "aba --dir $COMPACT ls"

e2e_run "Delete compact cluster" "aba -y --dir $COMPACT delete"
e2e_remove_from_cluster_cleanup "$PWD/$COMPACT"

test_end

# ============================================================================
# 6. SNO: install cluster on VMware
# ============================================================================
test_begin "SNO: install cluster on VMware"

e2e_run "Delete any leftover $SNO cluster" \
    "_e2e_delete_leftover_cluster $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"

e2e_run "Copy SSH key to alternate name (exercises ssh_key_file)" \
    "cp -f ~/.ssh/id_rsa ~/.ssh/e2e_alt_key && cp -f ~/.ssh/id_rsa.pub ~/.ssh/e2e_alt_key.pub"
e2e_run "Create SNO cluster.conf with alt SSH key and named mirror" \
    "aba cluster -n $SNO -t sno \
     --ssh-key ~/.ssh/e2e_alt_key --mirror-name $NAMED_MIRROR --step cluster.conf"
e2e_run "Verify ssh_key_file set" "grep 'ssh_key_file=.*e2e_alt_key' $SNO/cluster.conf"
e2e_run "Verify mirror_name set" "grep 'mirror_name=$NAMED_MIRROR' $SNO/cluster.conf"
e2e_run -r 2 10 "Install SNO (alt SSH key + named mirror)" \
    "aba cluster -n $SNO -t sno --step refresh"

# Wait for bootstrap only (not full install-complete)
e2e_poll 1800 30 "Wait for SNO bootstrap-complete" \
    "cd $SNO && openshift-install agent wait-for bootstrap-complete --dir iso-agent-based 2>&1 | tail -1"

# Wait for initial cluster install to complete (VMware SNO typically 25-40 min after bootstrap)
e2e_wait_cluster_ready $SNO local 3000

# EARLY day2: .install-complete does NOT exist yet.
# day2.sh gate should detect cluster_is_ready(), auto-create .install-complete,
# externalize state via monitor-install.sh, and proceed with day2 config.
e2e_run "Verify .install-complete does NOT exist yet" \
    "[ ! -f $SNO/.install-complete ] || { echo 'ERROR: .install-complete already exists'; false; }"
e2e_run "Apply day2 EARLY (tests cluster_is_ready gate)" "aba --dir $SNO day2"

# Verify the gate created .install-complete and externalized state
e2e_run "Verify .install-complete was auto-created by day2 gate" \
    "[ -f $SNO/.install-complete ] || { echo 'ERROR: day2 did not create .install-complete'; false; }"
e2e_run "Verify clusterstate symlink exists (state externalized)" \
    "[ -L $SNO/clusterstate ] || { echo 'ERROR: clusterstate not created'; false; }"

# Finalize: aba mon should complete quickly (cluster already up)
e2e_run -r 2 30 "Finalize install (aba mon)" "aba --dir $SNO mon"

e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_wait_cluster_ready $SNO
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 7. VM lifecycle: ls
# ============================================================================
test_begin "VM lifecycle: ls"

e2e_run "List VMware VMs" "aba --dir $SNO ls"
e2e_run "Verify ls output shows running VM" \
    "aba --dir $SNO ls | grep -i poweredOn"

test_end

# ============================================================================
# 8. VM lifecycle: stop (graceful)
# ============================================================================
test_begin "VM lifecycle: stop (graceful)"

e2e_run "Graceful stop of VMs" "aba --dir $SNO stop --wait"
e2e_run "Verify VMs are powered off after stop" \
    "aba --dir $SNO ls | grep -i poweredOff"

test_end

# ============================================================================
# 9. VM lifecycle: start
# ============================================================================
test_begin "VM lifecycle: start"

e2e_run "Start VMs" "aba --dir $SNO start"
e2e_run "Verify VMs are running after start" \
    "aba --dir $SNO ls | grep -i poweredOn"
e2e_poll 300 15 "Wait for SSH to become available" \
    "aba --dir $SNO ssh --cmd 'hostname'"

test_end

# ============================================================================
# 10. VM lifecycle: kill (force poweroff)
# ============================================================================
test_begin "VM lifecycle: kill (force poweroff)"

e2e_run "Force power off VMs" "aba --dir $SNO kill"
e2e_run "Verify VMs are powered off after kill" \
    "aba --dir $SNO ls | grep -i poweredOff"

test_end

# ============================================================================
# 11. VM lifecycle: start + cluster health after kill
# ============================================================================
test_begin "VM lifecycle: start + cluster health after kill"

e2e_run "Start VMs after hard power cycle" "aba --dir $SNO start"
e2e_run "Verify VMs are running" \
    "aba --dir $SNO ls | grep -i poweredOn"
e2e_poll 300 15 "Wait for SSH after hard power cycle" \
    "aba --dir $SNO ssh --cmd 'hostname'"
e2e_wait_cluster_ready $SNO
e2e_diag "Show cluster operators after kill recovery" \
    "aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 12. Cluster-level: graceful shutdown and startup
# ============================================================================
test_begin "Cluster-level: graceful shutdown and startup"

e2e_poll 300 15 "Wait for cluster API to become reachable" \
    "aba --dir $SNO run --cmd 'oc get nodes' 2>&1 | grep -qw Ready"

e2e_run "OpenShift graceful shutdown with --wait" "aba --dir $SNO shutdown -y --wait"
e2e_poll 120 10 "Verify VMs are powered off after OCP shutdown" \
    "aba --dir $SNO ls | grep -i poweredOff"

e2e_run "OpenShift cluster startup" "aba --dir $SNO startup"
e2e_run "Verify VMs are running after startup" \
    "aba --dir $SNO ls | grep -i poweredOn"
e2e_poll 300 15 "Wait for cluster API to become reachable after startup" \
    "aba --dir $SNO run --cmd 'oc get nodes' 2>&1 | grep -qw Ready"
e2e_poll 300 15 "Wait for all nodes Ready after startup" \
    "aba --dir $SNO run --cmd 'oc get nodes --no-headers' | grep -qw Ready && ! aba --dir $SNO run --cmd 'oc get nodes --no-headers' | grep -qw NotReady"
e2e_diag "Show nodes after startup" "aba --dir $SNO run --cmd 'oc get nodes'"
e2e_wait_cluster_ready $SNO
e2e_diag "Show cluster operators after shutdown/startup" \
    "aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 13. Cleanup: delete clusters and unregister mirror
# ============================================================================
test_begin "Cleanup: delete clusters and unregister mirror"

e2e_run "Delete SNO cluster (removes VMware VMs)" \
    "_e2e_delete_leftover_cluster $SNO"
e2e_remove_from_cluster_cleanup "$PWD/$SNO"
e2e_run "Delete compact cluster if leftover" \
    "_e2e_delete_leftover_cluster $COMPACT"
e2e_remove_from_cluster_cleanup "$PWD/$COMPACT"

e2e_run "Unregister named mirror" \
    "aba -d $NAMED_MIRROR unregister"
e2e_remove_from_mirror_cleanup "$PWD/$NAMED_MIRROR"
e2e_run "Remove named mirror directory" "rm -rf $NAMED_MIRROR"

test_end

# ============================================================================

suite_end; _rc=$?

exit $_rc
