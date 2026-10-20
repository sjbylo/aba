#!/usr/bin/env bash
# =============================================================================
# Suite: BMC Preflight (Fujitsu iRMC, real-pool E2E)
# =============================================================================
# Purpose: Closes TEST-04 by exercising the BMC automation feature against a real
# Fujitsu iRMC-bound pool node. Stops at .bm-bmc-boot-done stamp + last_step=session-logout
# state + PowerState=On (D-08 boundary). Stretch vendor pools (Dell, HPE, Supermicro,
# Lenovo) land in v1.2.
#
# Test matrix (5 tests per D-06):
#   1. Setup: install ABA on conN
#   2. Setup: write bmc.conf from pools.conf BMC_* fields, snapshot pre-existing bmc.conf
#   3. Positive: aba install boots node from BMC-mounted ISO (D-08 triple assertions)
#   4. Negative: wrong-password binding aborts at preflight (D-09 triple assertions)
#   5. Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot
#
# D-08 boundary (positive stop condition):
#   - .bm-bmc-boot-done stamp exists
#   - .bmc-state.master0 shows last_step=session-logout
#   - /redfish/v1/Systems/0 PowerState=On (via redfish_powerstate_on)
#
# D-09 boundary (negative stop condition):
#   - non-zero exit from aba install
#   - iso-agent-based/agent.ARCH.iso NOT generated (preflight aborted before ISO gen)
#   - .bm-bmc-boot-done NOT present (preflight aborted before BMC writes)
#
# D-11 snapshot/restore contract:
#   - bmc.conf.preflight-bak created at suite_begin (backup of suite-written bmc.conf)
#   - restored in cleanup BEFORE bmc-unmount.sh so unmount uses working creds
#   - snapshot removed last in cleanup
#
# Prerequisite (set in pools.conf for the active pool):
#   - BMC_TYPE_master0=irmc (Fujitsu iRMC S5/S6 with VirtualMedia licensed)
#   - BMC_HOST_master0=<bmc-fqdn>
#   - BMC_USER_master0=<working-user>
#   - BMC_PASSWORD_master0=<working-password>
#   - BMC_INSECURE_master0=true (for self-signed lab certs)
#   - BMC_USER_BROKEN=<any-user> (wrong creds for negative test; password only need be wrong)
#   - BMC_PASSWORD_BROKEN=<deliberately-wrong-password>
#
# Real-pool execution is a HUMAN-UAT criterion; syntax + structural checks only here.
# See test/e2e/README.md '### Lab provisioning for BMC E2E tests' for setup instructions.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"
# Phase 9: redfish helpers (provides redfish_powerstate_on)
source "$_SUITE_DIR/../lib/redfish-helpers.sh"

# --- Configuration ------------------------------------------------------------

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
CLUSTER="$(pool_cluster_name bmc-preflight)"

# --- Suite --------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: install ABA on con${POOL_NUM}" \
	"Setup: write bmc.conf from pools.conf BMC_* fields, snapshot pre-existing bmc.conf" \
	"Positive: aba install boots node from BMC-mounted ISO" \
	"Negative: wrong-password binding aborts at preflight" \
	"Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot"

suite_begin "bmc-preflight"

# ============================================================================
# 1. Setup: install ABA on conN
# ============================================================================
test_begin "Setup: install ABA on con${POOL_NUM}"

e2e_run "Install ABA from git" \
	"cd ~ && rm -rf ~/aba && git clone --depth 1 -b \$E2E_GIT_BRANCH \$E2E_GIT_REPO ~/aba && cd ~/aba && ./install"

e2e_run "Configure aba.conf (baremetal platform, pool base domain)" \
	"cd ~/aba && aba --noask --platform bm --base-domain $(pool_domain)"

test_end

# ============================================================================
# 2. Setup: write bmc.conf from pools.conf BMC_* fields, snapshot pre-existing bmc.conf
# ============================================================================
test_begin "Setup: write bmc.conf from pools.conf BMC_* fields, snapshot pre-existing bmc.conf"

# D-07: abort if pool BMC_TYPE_master0 != irmc (only iRMC is certified in v1.1)
e2e_run "Assert pool BMC_TYPE_master0 is irmc (v1.1 requirement)" \
	"[ \"\${BMC_TYPE_master0:-}\" = irmc ] || { echo 'ERROR: pool BMC_TYPE_master0 must be irmc in v1.1; got: \${BMC_TYPE_master0:-unset}' >&2; exit 1; }"

# CLUSTER_DIR is the working dir for this cluster; aba subcommands are run from here
CLUSTER_DIR="$HOME/$CLUSTER"

# Register cleanup BEFORE any cluster-mutating action (crash-safe; Phase 4 D-09 rule)
e2e_add_to_cluster_cleanup "$CLUSTER_DIR"

# Initialize cluster directory via mkdir; aba cluster subcommand creates cluster.conf
e2e_run "Initialize cluster dir" \
	"mkdir -p \$CLUSTER_DIR"

e2e_run "Create cluster.conf (SNO, baremetal platform)" \
	"cd ~/aba && aba cluster -n $CLUSTER -t sno --starting-ip $(pool_node_ip) --step cluster.conf"

# Snapshot pre-existing bmc.conf if any (preserves any pre-suite BMC state)
e2e_run "Snapshot pre-existing bmc.conf if any" \
	"if [ -f \$CLUSTER_DIR/bmc.conf ]; then cp -v \$CLUSTER_DIR/bmc.conf \$CLUSTER_DIR/bmc.conf.preflight-bak; fi"

# Write bmc.conf from pool BMC_* fields; one line per key/value (KEY=VALUE, no spaces in values)
e2e_run "Write bmc.conf from pool BMC_* fields" \
	"{ printf 'bmc_type_master0=%s\n'     \"\${BMC_TYPE_master0:?}\"; \
	   printf 'bmc_host_master0=%s\n'     \"\${BMC_HOST_master0:?}\"; \
	   printf 'bmc_user_master0=%s\n'     \"\${BMC_USER_master0:?}\"; \
	   printf 'bmc_password_master0=%s\n' \"\${BMC_PASSWORD_master0:?}\"; \
	   printf 'bmc_insecure_master0=%s\n' \"\${BMC_INSECURE_master0:-true}\"; \
	 } > \$CLUSTER_DIR/bmc.conf"

# Mode 0600 per CFG-01 (credentials must never be world-readable)
e2e_run "Set bmc.conf mode 0600 (CFG-01)" \
	"chmod 600 \$CLUSTER_DIR/bmc.conf"

# Snapshot the suite-written bmc.conf for sed-restore in cleanup (D-11)
e2e_run "Snapshot suite-written bmc.conf for cleanup restore (D-11)" \
	"cp -v \$CLUSTER_DIR/bmc.conf \$CLUSTER_DIR/bmc.conf.preflight-bak"

test_end

# ============================================================================
# 3. Positive: aba install boots node from BMC-mounted ISO
# ============================================================================
test_begin "Positive: aba install boots node from BMC-mounted ISO"

# Run from cluster dir; aba reads bmc.conf from CWD per INT-03 gate
e2e_run "aba install (positive case - working creds)" \
	"cd \$CLUSTER_DIR && aba install"

# D-08 assertion 1: .bm-bmc-boot-done stamp exists (Phase 6 D-19)
e2e_run "Assert .bm-bmc-boot-done stamp exists" \
	"[ -f \$CLUSTER_DIR/.bm-bmc-boot-done ]"

# D-08 assertion 2: per-node state file shows session-logout (Phase 7 D-07/D-12)
e2e_run "Assert last_step=session-logout in .bmc-state.master0" \
	"grep -qE '^last_step=session-logout\$' \$CLUSTER_DIR/.bmc-state.master0"

# D-08 assertion 3: redfish_powerstate_on reports On
# Source the shipped scripts lazily here for _bm_build_auth (avoid side effects at outer source time)
e2e_run "Source scripts/preflight-check-bm.sh for _bm_build_auth" \
	"cd \$CLUSTER_DIR && source ~/aba/scripts/include_all.sh && source ~/aba/scripts/preflight-check-bm.sh && declare -F _bm_build_auth >/dev/null"

e2e_run "Assert PowerState=On for master0 via direct Redfish GET" \
	"cd \$CLUSTER_DIR && source ~/aba/scripts/include_all.sh && source ~/aba/scripts/preflight-check-bm.sh && source ~/aba/test/e2e/lib/redfish-helpers.sh && redfish_powerstate_on master0"

test_end

# ============================================================================
# 4. Negative: wrong-password binding aborts at preflight
# ============================================================================
test_begin "Negative: wrong-password binding aborts at preflight"

# Sed-swap to broken creds (D-11 pattern; BMC_USER_BROKEN/BMC_PASSWORD_BROKEN are pool-level env vars)
e2e_run "Swap bmc.conf to broken user (BMC_USER_BROKEN)" \
	"sed -i \"s|^bmc_user_master0=.*|bmc_user_master0=\${BMC_USER_BROKEN:?}|\" \$CLUSTER_DIR/bmc.conf"

e2e_run "Swap bmc.conf to broken password (BMC_PASSWORD_BROKEN)" \
	"sed -i \"s|^bmc_password_master0=.*|bmc_password_master0=\${BMC_PASSWORD_BROKEN:?}|\" \$CLUSTER_DIR/bmc.conf"

# Run aba install; must fail at preflight L2 (wrong password -> 401 Unauthorized)
e2e_run_must_fail "aba install with wrong creds aborts at preflight" \
	"cd \$CLUSTER_DIR && aba install"

# D-09 assertions: ISO absent (preflight aborted before ISO generation)
e2e_run "Assert ISO was NOT generated (preflight aborted before ISO generation)" \
	"test ! -f \$CLUSTER_DIR/iso-agent-based/agent.\$(uname -m).iso"

# D-09 assertions: BMC stamp absent (preflight aborted before BMC writes)
e2e_run "Assert .bm-bmc-boot-done stamp is absent (preflight aborted before BMC writes)" \
	"test ! -f \$CLUSTER_DIR/.bm-bmc-boot-done"

test_end

# ============================================================================
# 5. Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot
# ============================================================================
test_begin "Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot"

# Restore working creds FIRST so bmc-unmount can authenticate (cleanup ordering per
# CONTEXT.md Claude's Discretion: restore -> unmount -> delete -> rm snapshot)
e2e_run "Restore working bmc.conf for unmount" \
	"if [ -f \$CLUSTER_DIR/bmc.conf.preflight-bak ]; then cp -v \$CLUSTER_DIR/bmc.conf.preflight-bak \$CLUSTER_DIR/bmc.conf; fi"

# Best-effort BMC unmount (Phase 6 D-13 idempotent; Phase 7 D-17 optional positional arg)
# bmc-unmount.sh always exits 0 per D-13 best-effort contract (no explicit guard needed)
e2e_run "BMC unmount master0 (idempotent best-effort)" \
	"cd \$CLUSTER_DIR && ~/aba/scripts/bmc-unmount.sh master0"

# Delete cluster (only if it still exists; aba delete is idempotent on missing cluster)
e2e_run "Delete cluster" \
	"if [ -d \$CLUSTER_DIR ]; then aba -y --dir \$CLUSTER_DIR delete; else echo '[cleanup] \$CLUSTER_DIR already removed'; fi"

# Remove bmc.conf snapshot (last step in cleanup per D-11)
e2e_run "Remove bmc.conf snapshot" \
	"rm -f \$CLUSTER_DIR/bmc.conf.preflight-bak"

test_end

# ============================================================================

suite_end
