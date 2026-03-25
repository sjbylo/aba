#!/usr/bin/env bash
# =============================================================================
# Suite: KVM Lifecycle
# =============================================================================
# Purpose: End-to-end test of KVM platform support.  Installs an SNO cluster
#          and tests every VM lifecycle command ABA exposes: ls, stop, start,
#          kill, delete, refresh, upload, plus the cluster-level graceful
#          shutdown/startup.
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
    "Cleanup: delete clusters and unregister mirror"

suite_begin "kvm-lifecycle"

# ============================================================================
# 1. Ensure pre-populated registry on conN
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_run "Install ABA from git" \
	"cd ~ && rm -rf ~/aba && git clone --depth 1 -b \$E2E_GIT_BRANCH \$E2E_GIT_REPO ~/aba && cd ~/aba && ./install"
cd ~/aba
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
    "./install && aba reset -f"

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

e2e_run "Delete leftover $SNO VMs (if any)" \
    "if [ -d $SNO ]; then aba --dir $SNO delete || true; fi"
e2e_run "Clean up previous $SNO cluster dir" "rm -rf $SNO"
e2e_add_to_cluster_cleanup "$PWD/$SNO"

e2e_run -r 2 10 "Create VMs and start install" \
    "aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --ports enp1s0 --step refresh"

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

e2e_run "List KVM VMs" "aba --dir $SNO ls"
e2e_run "Verify ls output shows running VM" \
    "aba --dir $SNO ls | grep -i running"

test_end

# ============================================================================
# 8. VM lifecycle: stop (graceful)
# ============================================================================
test_begin "VM lifecycle: stop (graceful)"

e2e_run "Graceful stop of VMs" "aba --dir $SNO stop --wait"
e2e_run "Verify VMs are shut off after stop" \
    "aba --dir $SNO ls | grep -i 'shut-off'"

test_end

# ============================================================================
# 9. VM lifecycle: start
# ============================================================================
test_begin "VM lifecycle: start"

e2e_run "Start VMs" "aba --dir $SNO start"
e2e_run "Verify VMs are running after start" \
    "aba --dir $SNO ls | grep -i running"
e2e_poll 300 15 "Wait for SSH to become available" \
    "aba --dir $SNO ssh --cmd 'hostname'"

test_end

# ============================================================================
# 10. VM lifecycle: kill (force poweroff)
# ============================================================================
test_begin "VM lifecycle: kill (force poweroff)"

e2e_run "Force power off VMs" "aba --dir $SNO kill"
e2e_run "Verify VMs are shut off after kill" \
    "aba --dir $SNO ls | grep -i 'shut-off'"

test_end

# ============================================================================
# 11. VM lifecycle: start + cluster health after kill
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
# 12. Cluster-level: graceful shutdown and startup
# ============================================================================
test_begin "Cluster-level: graceful shutdown and startup"

e2e_poll 300 15 "Wait for cluster API to become reachable" \
    "aba --dir $SNO run --cmd 'oc get nodes' 2>&1 | grep -qw Ready"

e2e_run "OpenShift graceful shutdown with --wait" "aba --dir $SNO shutdown -y --wait"
e2e_poll 120 10 "Verify VMs are shut off after OCP shutdown" \
    "aba --dir $SNO ls | grep -i 'shut-off'"

e2e_run "OpenShift cluster startup" "aba --dir $SNO startup"
e2e_run "Verify VMs are running after startup" \
    "aba --dir $SNO ls | grep -i running"
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

e2e_run "Delete SNO cluster (removes KVM VMs + storage)" \
    "if [ -d $SNO ]; then aba --dir $SNO delete; else echo '[cleanup] $SNO already removed'; fi"

e2e_run "Unregister pool registry" \
    "aba -d mirror unregister"

test_end

# ============================================================================

suite_end

echo "SUCCESS: suite-kvm-lifecycle.sh"
