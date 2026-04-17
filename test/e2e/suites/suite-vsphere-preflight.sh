#!/usr/bin/env bash
# =============================================================================
# Suite: vSphere Preflight Validation (positive + negative)
# =============================================================================
# Purpose: Prove the vSphere preflight chain works end-to-end:
#   Positive: full install to operator-ready proves preflight does not block
#             the happy path (TEST-03).
#   Negative: a vCenter user missing Resource.AssignVMToPool on the RP scope
#             causes 'aba install' to abort at preflight; no ISO is generated
#             (TEST-04).
#
# Prerequisite (lab):
#   - Standard e2e setup (conN reachable, mirror buildable, vmware.conf
#     populated with working credentials).
#   - Lab-provisioned broken role 'aba-preflight-broken' bound to the user
#     named by pools.conf GOVC_USERNAME_BROKEN / GOVC_PASSWORD_BROKEN, missing
#     exactly Resource.AssignVMToPool on the resource pool scope.
#     See test/e2e/README.md "Lab provisioning for vSphere preflight tests".
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
	"Setup: verify broken role still missing Resource.AssignVMToPool" \
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
	"aba --noask --platform vmw --channel \$TEST_CHANNEL --version \$OCP_VERSION --base-domain \$(pool_domain)"

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

e2e_run "Register pool registry" \
	"aba -d mirror register pull_secret_mirror=/tmp/pool-reg-pull-secret.json ca_cert=\$POOL_REG_DIR/certs/ca.crt"

e2e_run "Verify mirror registry access" "aba -d mirror verify"

test_end

# ============================================================================
# Setup: verify the lab-provisioned broken role is still missing the target priv.
# Uses the same two-step algorithm as scripts/preflight-check-vsphere.sh:
#   (1) govc permissions.ls <scope> -> extract role for our broken user via awk
#   (2) govc role.ls <role>         -> enumerate privileges
#   (3) assert Resource.AssignVMToPool is absent from the role's priv list
#
# Note: govc permissions.ls accepts only -a, -i, PATH; it does NOT support
#       -principal. The principal filter happens client-side in awk.
#
# The tempfile /tmp/aba-preflight-broken-role.txt carries ONLY the role name
# (no "label: value" prefix) so the second step reads it with `cat` verbatim.
# This is intentional: a labeled line would require awk field-extraction, and
# the natural label "Broken-user role on RP:" itself contains a ':'-delimited
# field-2 value of "RP" which would be extracted instead of the role name.
# ============================================================================
test_begin "Setup: verify broken role still missing Resource.AssignVMToPool"

e2e_run "Resolve role for broken user on resource pool scope" \
	"source vmware.conf; \
	out=\$(GOVC_USERNAME=\"\$GOVC_USERNAME_BROKEN\" GOVC_PASSWORD=\"\$GOVC_PASSWORD_BROKEN\" \
		govc permissions.ls \"/\$GOVC_DATACENTER/host/\$GOVC_CLUSTER/Resources\"); \
	role=\$(echo \"\$out\" | awk -F'\\t' 'NR>1 && \$3==u {print \$1; exit}' u=\"\$GOVC_USERNAME_BROKEN\"); \
	if [ -z \"\$role\" ]; then \
		echo 'ERROR: broken user has no role on RP; bind aba-preflight-broken to this scope (see test/e2e/README.md)' >&2; exit 1; \
	fi; \
	echo \"\$role\" > /tmp/aba-preflight-broken-role.txt; \
	echo \"Broken-user role on RP: \$role\""

e2e_run "Assert broken role does NOT contain Resource.AssignVMToPool" \
	"role=\$(cat /tmp/aba-preflight-broken-role.txt); \
	if [ -z \"\$role\" ]; then \
		echo 'ERROR: role tempfile /tmp/aba-preflight-broken-role.txt is empty; previous step failed to resolve role' >&2; exit 1; \
	fi; \
	priv_list=\$(govc role.ls \"\$role\"); \
	if echo \"\$priv_list\" | grep -qxF 'Resource.AssignVMToPool'; then \
		echo 'ERROR: broken role is no longer broken - ask lab admin to re-strip Resource.AssignVMToPool from aba-preflight-broken on the RP scope' >&2; exit 1; \
	fi; \
	echo \"OK: role '\$role' does NOT grant Resource.AssignVMToPool\""

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
	"aba cluster -n $POS -t sno --starting-ip \$(pool_sno_ip) --step cluster.conf"

e2e_run -r 2 30 "Positive install: full install to operator-ready" \
	"aba --dir $POS install"

e2e_poll 600 30 "Wait for all operators fully available" \
	"lines=\$(aba --dir $POS run | tail -n +2 | awk 'NR>1{print \$3,\$4,\$5}'); [ -n \"\$lines\" ] && echo \"\$lines\" | grep -v '^True False False\$' | wc -l | grep ^0\$"

e2e_diag "Show cluster operators" "aba --dir $POS run --cmd 'oc get co'"

test_end

# ============================================================================
# Negative: swap vmware.conf to broken creds and assert preflight aborts install.
# ============================================================================
test_begin "Negative: preflight aborts install ($NEG)"

e2e_run "Swap vmware.conf GOVC_USERNAME to broken creds" \
	"sed -i 's|^GOVC_USERNAME=.*|GOVC_USERNAME='\"\$GOVC_USERNAME_BROKEN\"'|' vmware.conf"

e2e_run "Swap vmware.conf GOVC_PASSWORD to broken creds" \
	"sed -i 's|^GOVC_PASSWORD=.*|GOVC_PASSWORD='\"\$GOVC_PASSWORD_BROKEN\"'|' vmware.conf"

e2e_run "Delete any leftover $NEG cluster" \
	"if [ -d $NEG ]; then aba -y --dir $NEG delete; fi"
e2e_add_to_cluster_cleanup "$PWD/$NEG"

e2e_run -r 2 10 "Create NEG cluster.conf" \
	"aba cluster -n $NEG -t sno --starting-ip \$(pool_sno_ip) --step cluster.conf"

e2e_run_must_fail "Install aborts at preflight (broken role missing Resource.AssignVMToPool)" \
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
	"if [ -d $NEG ]; then \
		if [ -f $NEG/iso-agent-based/agent.\$(uname -m).iso ]; then \
			aba -y --dir $NEG delete && rm -rf $NEG; \
		else \
			# Negative install aborted at preflight - no VMs exist; aba delete would exit 1 (see scripts/vmw-delete.sh). \
			# Narrow exception per CLAUDE.md: the cluster dir is a test concern, not a product concern; rm -rf is correct here. \
			rm -rf $NEG; \
		fi; \
	else echo '[cleanup] $NEG already removed'; fi"

e2e_run "Unregister pool registry" \
	"aba -d mirror unregister"

test_end

suite_end

echo "SUCCESS: suite-vsphere-preflight.sh"
