#!/usr/bin/env bash
# =============================================================================
# Suite: KVM Lifecycle
# =============================================================================
# Purpose: End-to-end test of KVM platform support.  Installs an SNO cluster
#          on a remote KVM/libvirt host, then exercises every VM lifecycle
#          command ABA exposes: ls, stop, start, kill, delete, refresh, upload,
#          plus the cluster-level graceful shutdown/startup.
#
# Prerequisite:
#   - Internet-connected bastion (conN) with aba installed.
#   - Pre-populated Quay on conN (via setup-pool-registry.sh).
#   - ~/.kvm.conf on conN with a working LIBVIRT_URI, KVM_STORAGE_POOL,
#     KVM_NETWORK, and passwordless SSH to the KVM host.
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
STANDARD="$(pool_cluster_name standard)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
    "Setup: ensure pre-populated registry" \
    "Setup: install aba, configure for KVM" \
    "Setup: configure mirror for local registry" \
    "Setup: sync images to registry" \
    "SNO: install cluster on KVM" \
    "VM lifecycle: ls" \
    "VM lifecycle: stop (graceful)" \
    "VM lifecycle: start" \
    "VM lifecycle: kill (force poweroff)" \
    "VM lifecycle: start + cluster health after kill" \
    "Cluster-level: graceful shutdown and startup" \
    "Compact: multi-node VM creation and agent bootstrap" \
    "Standard: multi-node VM creation and agent bootstrap" \
    "Cleanup: delete clusters and unregister mirror"

suite_begin "kvm-lifecycle"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_run "Install aba (needed for version resolution)" "./install"
e2e_run "Configure aba.conf (temporary, for version resolution)" \
    "aba --noask --platform kvm --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
    "test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# 2. Setup: install aba, configure for KVM
# ============================================================================
test_begin "Setup: install aba, configure for KVM"

e2e_run "Reset aba to clean state" \
    "cd ~/aba && ./install && aba reset -f"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf for KVM" \
    "aba --noask --platform kvm --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

e2e_run "Set dns_servers via CLI" "aba --dns $(pool_dns_server)"

e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
e2e_run "Verify aba.conf: platform=kvm" "grep ^platform=kvm aba.conf"
e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
e2e_run "Verify aba.conf: version format" \
    "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy kvm.conf from home directory" \
    "cp -v ${KVM_CONF:-~/.kvm.conf} kvm.conf"
e2e_run "Verify kvm.conf has LIBVIRT_URI" "grep ^LIBVIRT_URI kvm.conf"
e2e_run "Verify kvm.conf has KVM_STORAGE_POOL" "grep ^KVM_STORAGE_POOL kvm.conf"
e2e_run "Verify kvm.conf has KVM_NETWORK" "grep ^KVM_NETWORK kvm.conf"

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
# 5. SNO: install cluster on KVM
# ============================================================================
test_begin "SNO: install cluster on KVM"

e2e_run "Clean up previous $SNO cluster dir" "rm -rf $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"

e2e_run -r 2 10 "Create VMs and start install" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --ports enp1s0 --step refresh"

# KVM/QEMU default on_reboot=destroy causes VMs to shut off after image write.
# Wait for that to happen, then restart.
e2e_poll 1200 30 "Wait for VM to shut off after image write" \
    "aba --dir $SNO ls | grep -qi 'shut-off'"

e2e_run "Restart VM after image write" "aba --dir $SNO start"
e2e_run "Verify VM is running" "aba --dir $SNO ls | grep -i running"

e2e_run -r 2 30 "Wait for install to complete" "aba --dir $SNO mon"

e2e_run "Show cluster operator status" "aba --dir $SNO run"
e2e_poll 600 30 "Wait for all operators fully available" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators" "aba --dir $SNO run --cmd 'oc get co'"

e2e_run "Apply day2 configuration (IDMS/ITMS for mirror)" "aba --dir $SNO day2"

test_end

# ============================================================================
# 6. VM lifecycle: ls
# ============================================================================
test_begin "VM lifecycle: ls"

e2e_run "List KVM VMs" "aba --dir $SNO ls"
e2e_run "Verify ls output shows running VM" \
    "aba --dir $SNO ls | grep -i running"

test_end

# ============================================================================
# 7. VM lifecycle: stop (graceful)
# ============================================================================
test_begin "VM lifecycle: stop (graceful)"

e2e_run "Graceful stop of VMs" "aba --dir $SNO stop --wait"
e2e_run "Verify VMs are shut off after stop" \
    "aba --dir $SNO ls | grep -i 'shut-off'"

test_end

# ============================================================================
# 8. VM lifecycle: start
# ============================================================================
test_begin "VM lifecycle: start"

e2e_run "Start VMs" "aba --dir $SNO start"
e2e_run "Verify VMs are running after start" \
    "aba --dir $SNO ls | grep -i running"
e2e_poll 300 15 "Wait for SSH to become available" \
    "aba --dir $SNO ssh --cmd 'hostname'"

test_end

# ============================================================================
# 9. VM lifecycle: kill (force poweroff)
# ============================================================================
test_begin "VM lifecycle: kill (force poweroff)"

e2e_run "Force power off VMs" "aba --dir $SNO kill"
e2e_run "Verify VMs are shut off after kill" \
    "aba --dir $SNO ls | grep -i 'shut-off'"

test_end

# ============================================================================
# 10. VM lifecycle: start + cluster health after kill
# ============================================================================
test_begin "VM lifecycle: start + cluster health after kill"

e2e_run "Start VMs after hard power cycle" "aba --dir $SNO start"
e2e_run "Verify VMs are running" \
    "aba --dir $SNO ls | grep -i running"
e2e_poll 300 15 "Wait for SSH after hard power cycle" \
    "aba --dir $SNO ssh --cmd 'hostname'"
e2e_poll 600 30 "Wait for cluster operators healthy after kill" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators after kill recovery" \
    "aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 11. Cluster-level: graceful shutdown and startup
# ============================================================================
test_begin "Cluster-level: graceful shutdown and startup"

e2e_poll 300 15 "Wait for cluster API to become reachable" \
    "aba --dir $SNO run --cmd 'oc get nodes' 2>&1 | grep -q Ready"

e2e_run "OpenShift graceful shutdown with --wait" "aba --dir $SNO shutdown -y --wait"
e2e_run "Verify VMs are shut off after OCP shutdown" \
    "aba --dir $SNO ls | grep -i 'shut-off'"

e2e_run "OpenShift cluster startup" "aba --dir $SNO startup"
e2e_run "Verify VMs are running after startup" \
    "aba --dir $SNO ls | grep -i running"
e2e_poll 600 30 "Wait for cluster operators healthy after shutdown/startup" \
    "lines=\$(aba --dir $SNO run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False$' | wc -l | grep ^0\$"
e2e_diag "Show cluster operators after shutdown/startup" \
    "aba --dir $SNO run --cmd 'oc get co'"

test_end

# ============================================================================
# 12. Compact: multi-node VM creation, network check, and bootstrap
# ============================================================================
# Validates that 3 master VMs are created with correct resources and network.
# SSHes into every node to verify network, then waits for bootstrap-complete.
# Does NOT wait for full install -- proves multi-node KVM provisioning works.
test_begin "Compact: multi-node VM creation and agent bootstrap"

e2e_run "Clean up previous $COMPACT cluster dir" "rm -rf $COMPACT"
e2e_add_to_cluster_cleanup "$PWD/$COMPACT"

e2e_run "Create compact cluster.conf" \
    "aba cluster -n $COMPACT -t compact --starting-ip $(pool_starting_ip compact) --step cluster.conf"
e2e_run "Set ports=enp1s0 for KVM (virtio NIC)" \
    "sed -i 's#^ports=.*#ports=enp1s0#g' $COMPACT/cluster.conf"
e2e_run "Fix mac_prefix for $COMPACT" \
    "sed -i 's#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g' $COMPACT/cluster.conf"

e2e_run "Generate ISO for compact cluster" "aba --dir $COMPACT iso"
e2e_run "Upload ISO to KVM host" "aba --dir $COMPACT upload"
e2e_run "Create and start compact VMs" "aba --dir $COMPACT create --start"

e2e_run "List compact VMs" "aba --dir $COMPACT ls"
e2e_run "Verify 3 VMs created for compact" \
    "[ \$(aba --dir $COMPACT ls | grep -c -i running) -eq 3 ]"

e2e_poll 300 15 "Wait for agent API on compact rendezvous node" \
    "curl -sk --connect-timeout 5 --max-time 5 -o /dev/null -w '%{http_code}' http://\$(cat $COMPACT/iso-agent-based/rendezvousIP):8090/ | grep -qE '^4'"

# Extract all node IPs from agent-config.yaml and SSH into each one
e2e_run "Extract compact node IPs" \
    "cd $COMPACT && eval \$(scripts/cluster-config.sh) && echo \"CP_IPS=\$CP_IP_ADDRESSES\""
for _node_idx in 0 1 2; do
    e2e_poll 300 15 "SSH into compact master $_node_idx (verify network)" \
        "cd $COMPACT && eval \$(scripts/cluster-config.sh) && _ips=(\$CP_IP_ADDRESSES) && ssh -F ~/.aba/ssh.conf -i \$ssh_key_file -o ConnectTimeout=10 core@\${_ips[$_node_idx]} 'hostname && ip -4 addr show | grep inet'"
done

e2e_poll 1800 30 "Wait for compact bootstrap-complete" \
    "cd $COMPACT && openshift-install agent wait-for bootstrap-complete --dir iso-agent-based 2>&1 | tail -1"
e2e_diag "Compact cluster VMs after bootstrap" "aba --dir $COMPACT ls"

e2e_run "Delete compact cluster VMs" "aba --dir $COMPACT delete"
e2e_run "Clean compact cluster dir" "rm -rf $COMPACT"

test_end

# ============================================================================
# 13. Standard: multi-node VM creation, network check, and bootstrap
# ============================================================================
# Validates that 3 masters + 2 workers (5 VMs) are created with correct
# resources and network.  SSHes into every node, then waits for bootstrap.
test_begin "Standard: multi-node VM creation and agent bootstrap"

e2e_run "Clean up previous $STANDARD cluster dir" "rm -rf $STANDARD"
e2e_add_to_cluster_cleanup "$PWD/$STANDARD"

e2e_run "Create standard cluster.conf" \
    "aba cluster -n $STANDARD -t standard --starting-ip $(pool_starting_ip standard) -W 2 --step cluster.conf"
e2e_run "Set ports=enp1s0 for KVM (virtio NIC)" \
    "sed -i 's#^ports=.*#ports=enp1s0#g' $STANDARD/cluster.conf"
e2e_run "Fix mac_prefix for $STANDARD" \
    "sed -i 's#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g' $STANDARD/cluster.conf"

e2e_run "Generate ISO for standard cluster" "aba --dir $STANDARD iso"
e2e_run "Upload ISO to KVM host" "aba --dir $STANDARD upload"
e2e_run "Create and start standard VMs" "aba --dir $STANDARD create --start"

e2e_run "List standard VMs" "aba --dir $STANDARD ls"
e2e_run "Verify 5 VMs created for standard (3 masters + 2 workers)" \
    "[ \$(aba --dir $STANDARD ls | grep -c -i running) -eq 5 ]"

e2e_poll 300 15 "Wait for agent API on standard rendezvous node" \
    "curl -sk --connect-timeout 5 --max-time 5 -o /dev/null -w '%{http_code}' http://\$(cat $STANDARD/iso-agent-based/rendezvousIP):8090/ | grep -qE '^4'"

# SSH into every master node
e2e_run "Extract standard node IPs" \
    "cd $STANDARD && eval \$(scripts/cluster-config.sh) && echo \"CP_IPS=\$CP_IP_ADDRESSES WKR_IPS=\$WKR_IP_ADDR\""
for _node_idx in 0 1 2; do
    e2e_poll 300 15 "SSH into standard master $_node_idx (verify network)" \
        "cd $STANDARD && eval \$(scripts/cluster-config.sh) && _ips=(\$CP_IP_ADDRESSES) && ssh -F ~/.aba/ssh.conf -i \$ssh_key_file -o ConnectTimeout=10 core@\${_ips[$_node_idx]} 'hostname && ip -4 addr show | grep inet'"
done

# SSH into every worker node
for _node_idx in 0 1; do
    e2e_poll 300 15 "SSH into standard worker $_node_idx (verify network)" \
        "cd $STANDARD && eval \$(scripts/cluster-config.sh) && _ips=(\$WKR_IP_ADDR) && ssh -F ~/.aba/ssh.conf -i \$ssh_key_file -o ConnectTimeout=10 core@\${_ips[$_node_idx]} 'hostname && ip -4 addr show | grep inet'"
done

e2e_poll 1800 30 "Wait for standard bootstrap-complete" \
    "cd $STANDARD && openshift-install agent wait-for bootstrap-complete --dir iso-agent-based 2>&1 | tail -1"
e2e_diag "Standard cluster VMs after bootstrap" "aba --dir $STANDARD ls"

e2e_run "Delete standard cluster VMs" "aba --dir $STANDARD delete"
e2e_run "Clean standard cluster dir" "rm -rf $STANDARD"

test_end

# ============================================================================
# 14. Cleanup: delete clusters and unregister mirror
# ============================================================================
test_begin "Cleanup: delete clusters and unregister mirror"

e2e_run "Delete SNO cluster (removes KVM VMs + storage)" \
    "if [ -d $SNO ]; then aba --dir $SNO delete; else echo '[cleanup] $SNO already removed'; fi"
e2e_run "Delete compact cluster if leftover" \
    "if [ -d $COMPACT ]; then aba --dir $COMPACT delete; else echo '[cleanup] $COMPACT already removed'; fi"
e2e_run "Delete standard cluster if leftover" \
    "if [ -d $STANDARD ]; then aba --dir $STANDARD delete; else echo '[cleanup] $STANDARD already removed'; fi"

e2e_run "Unregister pool registry" \
    "aba -d mirror unregister"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-kvm-lifecycle.sh"
