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
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"

# --- Configuration ----------------------------------------------------------

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
NTP_IP="${NTP_SERVER:-10.0.1.8}"

SNO="$(pool_cluster_name sno)"
COMPACT="$(pool_cluster_name compact)"

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

e2e_run "Install ABA from git" \
	"cd ~ && rm -rf ~/aba && git clone --depth 1 -b \$E2E_GIT_BRANCH \$E2E_GIT_REPO ~/aba && cd ~/aba && ./install"
cd ~/aba
e2e_run "Configure aba.conf (temporary, for version resolution)" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba, configure for VMware
# ============================================================================
test_begin "Setup: install aba, configure for VMware"

e2e_run "Reset aba to clean state" \
    "./install && aba reset -f"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf for VMware" \
    "aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

e2e_run "Set dns_servers via CLI" "aba --dns $(pool_dns_server)"

e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" \
    "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf from home directory" \
    "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Verify vmware.conf has GOVC_URL" "grep ^GOVC_URL vmware.conf"
e2e_run "Verify vmware.conf has VC_FOLDER" "grep ^VC_FOLDER vmware.conf"
e2e_run "Verify vmware.conf has GOVC_DATACENTER" "grep ^GOVC_DATACENTER vmware.conf"

e2e_run "Set NTP servers" "aba --ntp $NTP_IP ntp.example.com"

test_end

# ============================================================================
# 3. Configure mirror to use local pre-populated registry
# ============================================================================
test_begin "Setup: configure mirror for local registry"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Set reg_host to local registry" \
    "sed -i 's/^reg_host=.*/reg_host=${CON_HOST}/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
    "sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
    "sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"

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

e2e_run "Register pool registry" \
    "aba -d mirror register pull_secret_mirror=/tmp/pool-reg-pull-secret.json ca_cert=$POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

test_end

# ============================================================================
# 4. Sync images to registry
# ============================================================================
test_begin "Setup: sync images to registry"

e2e_run -r 3 2 "Sync images to local registry" "aba -d mirror sync --retry"

test_end

# ============================================================================
# 5. Compact: multi-node VM creation, network check, and bootstrap
# ============================================================================
# Validates that 3 master VMs are created with correct resources and network.
# SSHes into every node to verify network, then waits for bootstrap-complete.
# Does NOT wait for full install -- proves multi-node VMware provisioning works.
test_begin "Compact: multi-node VM creation and agent bootstrap"

e2e_run "Delete leftover $COMPACT VMs (if any)" \
    "if [ -d $COMPACT ]; then aba --dir $COMPACT delete || true; fi"
e2e_run "Clean up previous $COMPACT cluster dir" "rm -rf $COMPACT"
e2e_add_to_cluster_cleanup "$PWD/$COMPACT"

e2e_run "Create compact cluster.conf" \
    "aba cluster -n $COMPACT -t compact --starting-ip $(pool_starting_ip compact) --step cluster.conf"
e2e_run "Set mac_prefix for $COMPACT (VMware range, randomized)" \
    "sed -i 's#mac_prefix=.*#mac_prefix=00:50:56:1x:xx:#g' $COMPACT/cluster.conf"

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
    e2e_poll 300 15 "SSH into compact master $_node_idx (verify network)" \
        "cd $COMPACT && source cluster.conf && eval \$(scripts/cluster-config.sh) && _ips=(\$CP_IP_ADDRESSES) && ssh -F ~/.aba/ssh.conf -i \$ssh_key_file -o ConnectTimeout=10 core@\${_ips[$_node_idx]} 'hostname && ip -4 addr show | grep inet'"
done

e2e_poll 1800 30 "Wait for compact bootstrap-complete" \
    "cd $COMPACT && openshift-install agent wait-for bootstrap-complete --dir iso-agent-based 2>&1 | tail -1"
e2e_diag "Compact cluster VMs after bootstrap" "aba --dir $COMPACT ls"

e2e_run "Delete compact cluster VMs" "aba --dir $COMPACT delete"
e2e_run "Clean compact cluster dir" "rm -rf $COMPACT"

test_end

# ============================================================================
# 6. SNO: install cluster on VMware
# ============================================================================
test_begin "SNO: install cluster on VMware"

e2e_run "Delete leftover $SNO VMs (if any)" \
    "if [ -d $SNO ]; then aba --dir $SNO delete || true; fi"
e2e_run "Clean up previous $SNO cluster dir" "rm -rf $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"

e2e_run -r 2 10 "Create VMs and start install" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step refresh"

e2e_run -r 2 30 "Wait for install to complete" "aba --dir $SNO mon"

e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"

e2e_run "Apply day2 configuration (IDMS/ITMS for mirror)" "aba --dir $SNO day2"

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
e2e_poll 600 30 "Wait for cluster operators healthy after kill" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
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
e2e_poll 600 30 "Wait for all cluster operators available after startup" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators after shutdown/startup" \
    "aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 13. Cleanup: delete clusters and unregister mirror
# ============================================================================
test_begin "Cleanup: delete clusters and unregister mirror"

e2e_run "Delete SNO cluster (removes VMware VMs)" \
    "aba --dir $SNO delete && rm -rf $SNO"
e2e_run "Delete compact cluster if leftover" \
    "aba --dir $COMPACT delete && rm -rf $COMPACT"

e2e_run "Unregister pool registry" \
    "aba -d mirror unregister"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-vmw-lifecycle.sh"
