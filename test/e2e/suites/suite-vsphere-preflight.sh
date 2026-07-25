#!/usr/bin/env bash
# =============================================================================
# Suite: vSphere Preflight Validation (positive + negative)
# =============================================================================
# Purpose: Prove the vSphere preflight chain works end-to-end:
#   Positive: full install to operator-ready proves preflight does not block
#             the happy path (TEST-03).
#   Negative: a vmware.conf with bogus vCenter credentials causes 'aba install'
#             to abort at preflight (Layer 1 auth gate); no ISO is generated
#             (TEST-04).
#
# Rationale for Layer 1 (auth) over Layer 4 (surgical privilege gap):
#   Fine-grained privilege scenarios (missing Resource.AssignVMToPool, etc.)
#   are covered exhaustively by test/func/test-preflight-check-vsphere.sh
#   (Paths N/O/P/Q/R/S/T/U/V/W/X/Y/Z, 44 assertions, mocked govc). The E2E
#   suite's unique value is "aba install actually invokes preflight and
#   preflight actually gates the make chain" - any preflight failure proves
#   that. Using bogus creds keeps the negative path lab-ops-free: no custom
#   role, no per-user provisioning, no binding across 7 scopes.
#
# Prerequisite (lab):
#   - Standard e2e setup (conN reachable, mirror buildable, vmware.conf
#     populated with working credentials).
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

POS="$(pool_cluster_name vmw-preflight-pos)"
NEG="$(pool_cluster_name vmw-preflight-neg)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: ensure pre-populated registry" \
	"Setup: install aba, configure for VMware" \
	"Setup: configure mirror for local registry" \
	"Positive: install proceeds past preflight ($POS)" \
	"Negative: preflight aborts install ($NEG)" \
	"Cleanup: restore vmware.conf and delete clusters"

suite_begin "vsphere-preflight"

# ============================================================================
# Setup: pre-populated registry (assumes the pool's con bastion is alive and
# reachable - runner.sh verifies this before dispatching suites).
# ============================================================================
test_begin "Setup: ensure pre-populated registry"

e2e_run "Verify con bastion is reachable" \
	"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${CON_HOST} 'echo OK: bastion reachable'"

e2e_install_aba
e2e_run "Configure aba.conf (temporary, for version resolution)" \
	"aba --noask --platform vmw --channel \$TEST_CHANNEL --version \$OCP_VERSION --base-domain \$(pool_domain) --machine-network \$(pool_machine_network) --gateway \$(pool_gateway)"
e2e_run "Verify aba.conf: version resolved" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

e2e_run "Ensure pre-populated registry (OCP ${_ocp_channel} ${_ocp_version})" \
	"test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${CON_HOST}"

test_end

# ============================================================================
# Setup: install aba on conN and configure for VMware.
# Mirrors suite-vmw-lifecycle.sh:59-107 (the canonical ABA-install block).
# ============================================================================
test_begin "Setup: install aba, configure for VMware"

e2e_run "Reset aba to clean state" \
	"./install && aba reset -f"

e2e_run "Install aba" "./install"

e2e_run "Configure aba.conf for VMware" \
	"aba --noask --platform vmw --channel \$TEST_CHANNEL --version \$OCP_VERSION --base-domain \$(pool_domain) --machine-network \$(pool_machine_network) --gateway \$(pool_gateway)"
e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"

e2e_run "Copy vmware.conf from home directory" \
	"cp -v \${VMWARE_CONF:-~/.vmware.conf} vmware.conf"

test_end

# ============================================================================
# Setup: configure and register the pool-local mirror.
# Register cleanup BEFORE the action, per CLAUDE.md E2E discipline.
# ============================================================================
test_begin "Setup: configure mirror for local registry"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"

e2e_run "Set reg_host to local registry" \
	"sed -i 's|^reg_host=.*|reg_host=${CON_HOST}|g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_key (local registry)" \
	"sed -i 's|^reg_ssh_key=.*|reg_ssh_key=|g' mirror/mirror.conf"
e2e_run "Clear reg_ssh_user (local registry)" \
	"sed -i 's|^reg_ssh_user=.*|reg_ssh_user=|g' mirror/mirror.conf"

e2e_add_to_mirror_cleanup "$PWD/mirror"

e2e_run "Generate pool-registry pull secret via aba" \
	"printf 'init\np4ssw0rd\n' | aba -d mirror password && cp ~/.aba/mirror/mirror/pull-secret-mirror.json /tmp/pool-reg-pull-secret.json"

e2e_run "Register pool registry" \
	"aba -d mirror register --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert \$POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

test_end

# ============================================================================
# Positive: install with working credentials; verify preflight passes and
# the cluster reaches operator-ready (TEST-03).
# ============================================================================
test_begin "Positive: install proceeds past preflight ($POS)"

e2e_run "Snapshot vmware.conf before any credential swaps" \
	"cp -v vmware.conf vmware.conf.preflight-bak"

e2e_run "Delete any leftover $POS cluster" \
	"if [ -d $POS ]; then aba -y --dir $POS delete; fi"
e2e_add_to_cluster_cleanup "$PWD/$POS"

e2e_run -r 2 10 "Create POS cluster.conf" \
	"aba cluster -n $POS -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run -r 2 30 "Positive install: full install to operator-ready" \
	"aba --dir $POS install"

e2e_poll 600 30 "Wait for all operators fully available" \
	"lines=\$(aba --dir $POS run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False\$' | wc -l | grep ^0\$"

e2e_diag "Show cluster operators" "aba --dir $POS run --cmd 'oc get co'"

test_end

# ============================================================================
# Negative: swap vmware.conf to bogus credentials and assert preflight aborts.
# GOVC_USERNAME_BROKEN / GOVC_PASSWORD_BROKEN defaults in pools.conf are
# deliberately bogus strings (no lab provisioning required); preflight fails
# at Layer 1 (auth) before reaching the privilege check.
# ============================================================================
test_begin "Negative: preflight aborts install ($NEG)"

e2e_run "Swap vmware.conf GOVC_USERNAME to bogus value" \
	"sed -i 's|^GOVC_USERNAME=.*|GOVC_USERNAME='\"\$GOVC_USERNAME_BROKEN\"'|' vmware.conf"

e2e_run "Swap vmware.conf GOVC_PASSWORD to bogus value" \
	"sed -i 's|^GOVC_PASSWORD=.*|GOVC_PASSWORD='\"\$GOVC_PASSWORD_BROKEN\"'|' vmware.conf"

e2e_run "Delete any leftover $NEG cluster" \
	"if [ -d $NEG ]; then aba -y --dir $NEG delete; fi"
e2e_add_to_cluster_cleanup "$PWD/$NEG"

e2e_run -r 2 10 "Create NEG cluster.conf" \
	"aba cluster -n $NEG -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run_must_fail "Install aborts at preflight (bogus vCenter credentials)" \
	"aba --dir $NEG install"

e2e_run "ISO was NOT generated (preflight blocked the make chain)" \
	"test ! -f $NEG/iso-agent-based/agent.\$(uname -m).iso"

test_end

# ============================================================================
# Cleanup: restore vmware.conf, delete clusters, unregister mirror.
# Order: restore creds FIRST (so aba delete for $NEG can authenticate against
# vCenter if it finds an ISO), then delete clusters, then unregister mirror.
# ============================================================================
test_begin "Cleanup: restore vmware.conf and delete clusters"

e2e_run "Restore vmware.conf from preflight backup" \
	"if [ -f vmware.conf.preflight-bak ]; then cp -v vmware.conf.preflight-bak vmware.conf; rm -f vmware.conf.preflight-bak; else echo '[cleanup] no vmware.conf backup found'; fi"

e2e_run "Delete positive cluster (removes VMs)" \
	"if [ -d $POS ]; then aba -y --dir $POS delete && rm -rf $POS; else echo '[cleanup] $POS already removed'; fi"

e2e_run "Delete negative cluster (guarded: no ISO = preflight aborted, no VMs to delete)" \
	"if [ -d $NEG ]; then
		if [ -f $NEG/iso-agent-based/agent.\$(uname -m).iso ]; then
			aba -y --dir $NEG delete && rm -rf $NEG
		else
			rm -rf $NEG
		fi
	else echo '[cleanup] $NEG already removed'; fi"

e2e_run "Unregister pool registry" \
	"aba -d mirror unregister"

test_end

suite_end; _rc=$?

exit $_rc
