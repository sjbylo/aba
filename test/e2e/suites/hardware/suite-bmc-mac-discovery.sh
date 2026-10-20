#!/usr/bin/env bash
# =============================================================================
# Suite: BMC MAC Discovery (Fujitsu iRMC, real-pool E2E)
# =============================================================================
# Purpose: Closes TEST-07 by exercising the Phase 10 MAC auto-discovery flow
# end-to-end against a real Fujitsu iRMC-bound pool node. Verifies the
# preflight + Redfish EthernetInterfaces + sidecar persistence path against
# live hardware, covering populate-discovery, validate-match, and
# validate-mismatch scenarios per D-12.
#
# Test matrix (6 tests; locked at 6 per Plan 10-04 acceptance):
#   1. Setup: install ABA on conN
#   2. Setup: write bmc.conf WITHOUT mac_master0, snapshot pre-existing bmc.conf
#   3. Positive: aba install populates discovered_mac in .bmc-state.master0
#                matching BMC_EXPECTED_MAC_master0
#   4. Positive: bmc.conf with matching mac_master0 passes preflight (no MAC-03)
#   5. Negative: bmc.conf with mismatching mac_master0 aborts at preflight
#                with MAC-03 line
#   6. Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot
#
# D-12 boundary (iRMC-only in v1.1):
#   - Stretch vendors (Dell iDRAC, HPE iLO, Supermicro, Lenovo XCC) are
#     code-complete per Plans 10-01 / 10-03 mocked coverage but are NOT
#     real-hardware-validated in this release. Their formal drop-list and
#     v1.2 backlog entry lives in Plan 10-06's audit roll-up per D-14.
#   - Test 2 fast-fails if BMC_TYPE_master0 != irmc.
#
# Sidecar schema assertions (Phase 10 D-01 keys; written by _bm_state_write_mac):
#   - discovered_mac=<lowercase aa:bb:cc:dd:ee:ff>
#   - discovered_nic_id=<vendor-reported id, e.g. NIC.Integrated.1>
#   - discovered_at=<ISO-8601 UTC, e.g. 2026-05-18T10:30:00Z>
#
# MAC-03 negative assertion (Phase 10 D-08 / D-10 contract):
#   - aba install stdout contains "MAC-03:" with the operator-supplied MAC and
#     the BMC-reported NIC summary; preflight aborts before .bm-bmc-boot-done.
#
# Prerequisite (set in pools.conf for the active pool; see README runbook):
#   - BMC_TYPE_master0=irmc (Fujitsu iRMC S5/S6 with VirtualMedia licensed)
#   - BMC_HOST_master0=<bmc-fqdn>
#   - BMC_USER_master0=<working-user>
#   - BMC_PASSWORD_master0=<working-password>
#   - BMC_INSECURE_master0=true (for self-signed lab certs)
#   - BMC_EXPECTED_MAC_master0=<aa:bb:cc:dd:ee:ff>  (NEW for Phase 10 TEST-08)
#     the MAC the iRMC will report for the LinkUp+Enabled physical NIC.
#     Discover it out-of-band per test/e2e/README.md '#### MAC discovery'.
#
# Real-pool execution is a HUMAN-UAT criterion (mirrors Phase 9 TEST-04
# pattern). This file ships the suite + structural checks; an operator runs
# it against a lab iRMC. See test/e2e/README.md '### Lab provisioning for
# BMC E2E tests' (subsection '#### MAC discovery') for setup instructions.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-lifecycle.sh"
source "$_SUITE_DIR/../lib/setup.sh"
# Phase 9: redfish helpers (provides redfish_powerstate_on and direct-Redfish probes)
source "$_SUITE_DIR/../lib/redfish-helpers.sh"

# --- Configuration ------------------------------------------------------------

CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
CLUSTER="$(pool_cluster_name bmc-mac-discovery)"
CLUSTER_DIR="$HOME/$CLUSTER"

# --- Suite --------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: install ABA on con${POOL_NUM}" \
	"Setup: write bmc.conf WITHOUT mac_master0, snapshot pre-existing bmc.conf" \
	"Positive: aba install populates discovered_mac in .bmc-state.master0 matching BMC_EXPECTED_MAC_master0" \
	"Positive: bmc.conf with matching mac_master0 passes preflight" \
	"Negative: bmc.conf with mismatching mac_master0 aborts at preflight with MAC-03" \
	"Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot"

suite_begin "bmc-mac-discovery"

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
# 2. Setup: write bmc.conf WITHOUT mac_master0, snapshot pre-existing bmc.conf
# ============================================================================
test_begin "Setup: write bmc.conf WITHOUT mac_master0, snapshot pre-existing bmc.conf"

# D-12: abort if pool BMC_TYPE_master0 != irmc (only iRMC is real-HW gated in v1.1)
e2e_run "Assert pool BMC_TYPE_master0 is irmc (D-12 v1.1 requirement)" \
	"[ \"\${BMC_TYPE_master0:-}\" = irmc ] || { echo 'ERROR: pool BMC_TYPE_master0 must be irmc in v1.1 for MAC discovery (D-12); got: '\"\${BMC_TYPE_master0:-unset}\" >&2; exit 1; }"

# Phase 10 TEST-08 pre-req: BMC_EXPECTED_MAC_master0 must be set in pools.conf
e2e_run "Assert pool BMC_EXPECTED_MAC_master0 is set" \
	"[ -n \"\${BMC_EXPECTED_MAC_master0:-}\" ] || { echo 'ERROR: pool BMC_EXPECTED_MAC_master0 must be set in pools.conf (run the Lab provisioning runbook in test/e2e/README.md \"### Lab provisioning for BMC E2E tests\" subsection \"MAC discovery\")' >&2; exit 1; }"

# Register cleanup BEFORE any cluster-mutating action (crash-safe; Phase 4 D-09 rule)
e2e_add_to_cluster_cleanup "$CLUSTER_DIR"

# Initialize cluster directory; aba cluster subcommand creates cluster.conf
e2e_run "Initialize cluster dir" \
	"mkdir -p \$CLUSTER_DIR"

e2e_run "Create cluster.conf (SNO, baremetal platform)" \
	"cd ~/aba && aba cluster -n $CLUSTER -t sno --starting-ip $(pool_node_ip) --step cluster.conf"

# Snapshot pre-existing bmc.conf if any (preserves any pre-suite BMC state)
e2e_run "Snapshot pre-existing bmc.conf if any" \
	"if [ -f \$CLUSTER_DIR/bmc.conf ]; then cp -v \$CLUSTER_DIR/bmc.conf \$CLUSTER_DIR/bmc.conf.preflight-bak; fi"

# Write bmc.conf from pool BMC_* fields WITHOUT mac_master0 - the whole point
# of scenario (a) is that the operator did not set mac_master0, and aba should
# auto-populate discovered_mac from the iRMC's EthernetInterfaces response.
e2e_run "Write bmc.conf from pool BMC_* fields (NO mac_master0; discovery populates it)" \
	"{ printf 'bmc_type_master0=%s\n'     \"\${BMC_TYPE_master0:?}\"; \
	   printf 'bmc_host_master0=%s\n'     \"\${BMC_HOST_master0:?}\"; \
	   printf 'bmc_user_master0=%s\n'     \"\${BMC_USER_master0:?}\"; \
	   printf 'bmc_password_master0=%s\n' \"\${BMC_PASSWORD_master0:?}\"; \
	   printf 'bmc_insecure_master0=%s\n' \"\${BMC_INSECURE_master0:-true}\"; \
	 } > \$CLUSTER_DIR/bmc.conf"

# Mode 0600 per CFG-01 (credentials must never be world-readable)
e2e_run "Set bmc.conf mode 0600 (CFG-01)" \
	"chmod 600 \$CLUSTER_DIR/bmc.conf"

# Snapshot the suite-written bmc.conf for restore in subsequent tests + cleanup
e2e_run "Snapshot suite-written bmc.conf as bmc.conf.mac-discovery-bak" \
	"cp -v \$CLUSTER_DIR/bmc.conf \$CLUSTER_DIR/bmc.conf.mac-discovery-bak"

test_end

# ============================================================================
# 3. Positive scenario (a): discovery populates discovered_mac
# ============================================================================
test_begin "Positive: aba install populates discovered_mac in .bmc-state.master0 matching BMC_EXPECTED_MAC_master0"

# bmc.conf at this point has NO mac_master0; aba install should query the iRMC
# EthernetInterfaces and write discovered_mac into .bmc-state.master0.
e2e_run "aba install (positive case - no mac_master0; discovery populates)" \
	"cd \$CLUSTER_DIR && aba install"

# Phase 6 D-19: stamp confirms preflight + BMC boot loop reached the success exit
e2e_run "Assert .bm-bmc-boot-done stamp exists" \
	"[ -f \$CLUSTER_DIR/.bm-bmc-boot-done ]"

# Phase 10 D-01 keys: sidecar schema 1.2.0 keys must all be populated
e2e_run "Assert .bmc-state.master0 contains discovered_mac=<mac>" \
	"grep -qE '^discovered_mac=[0-9a-fA-F:]{17}\$' \$CLUSTER_DIR/.bmc-state.master0"

e2e_run "Assert .bmc-state.master0 contains discovered_nic_id=<id>" \
	"grep -qE '^discovered_nic_id=' \$CLUSTER_DIR/.bmc-state.master0"

e2e_run "Assert .bmc-state.master0 contains discovered_at=<ISO-8601 UTC>" \
	"grep -qE '^discovered_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$' \$CLUSTER_DIR/.bmc-state.master0"

# Cross-check the discovered MAC against the pools.conf expected value
# (case-insensitive: iRMC may report uppercase hex, normalize via ${,,})
e2e_run "Assert discovered_mac matches BMC_EXPECTED_MAC_master0 (case-insensitive)" \
	"actual=\$(grep '^discovered_mac=' \$CLUSTER_DIR/.bmc-state.master0 | cut -d= -f2); \
	 expected=\"\${BMC_EXPECTED_MAC_master0:?}\"; \
	 [ \"\${actual,,}\" = \"\${expected,,}\" ] || { echo 'ERROR: discovered_mac='\"\$actual\"' does not match expected='\"\$expected\" >&2; exit 1; }"

test_end

# ============================================================================
# 4. Positive scenario (b): matching mac_master0 passes preflight (no MAC-03)
# ============================================================================
test_begin "Positive: bmc.conf with matching mac_master0 passes preflight"

# Clean up the cluster from Test 3 so each scenario starts from a known state.
# aba -y --dir CLUSTER_DIR delete is idempotent (Phase 4 D-09).
e2e_run "Delete cluster from Test 3 before re-running with matching mac_master0" \
	"if [ -d \$CLUSTER_DIR ]; then aba -y --dir \$CLUSTER_DIR delete; fi"

# Re-init cluster dir + cluster.conf for a clean start
e2e_run "Re-init cluster dir for Test 4" \
	"mkdir -p \$CLUSTER_DIR"

e2e_run "Re-create cluster.conf for Test 4" \
	"cd ~/aba && aba cluster -n $CLUSTER -t sno --starting-ip $(pool_node_ip) --step cluster.conf"

# Restore the snapshotted bmc.conf and inject mac_master0 matching the expected MAC
e2e_run "Restore bmc.conf snapshot and inject matching mac_master0" \
	"cp -v \$CLUSTER_DIR/bmc.conf.mac-discovery-bak \$CLUSTER_DIR/bmc.conf && \
	 printf 'mac_master0=%s\n' \"\${BMC_EXPECTED_MAC_master0:?}\" >> \$CLUSTER_DIR/bmc.conf && \
	 chmod 600 \$CLUSTER_DIR/bmc.conf"

# Capture install output so we can assert MAC-03 is absent (D-08 happy path)
e2e_run "aba install (positive case - mac_master0 matches BMC report)" \
	"cd \$CLUSTER_DIR && aba install 2>&1 | tee install-match.log"

# D-08 happy path: no MAC-03 line because operator MAC matches BMC report
e2e_run "Assert install-match.log does NOT contain MAC-03" \
	"! grep -q 'MAC-03:' \$CLUSTER_DIR/install-match.log"

# Sidecar still gets populated with the same discovered_mac (D-08 validate-or-populate)
e2e_run "Assert .bmc-state.master0 discovered_mac matches BMC_EXPECTED_MAC_master0" \
	"actual=\$(grep '^discovered_mac=' \$CLUSTER_DIR/.bmc-state.master0 | cut -d= -f2); \
	 expected=\"\${BMC_EXPECTED_MAC_master0:?}\"; \
	 [ \"\${actual,,}\" = \"\${expected,,}\" ] || { echo 'ERROR: discovered_mac='\"\$actual\"' does not match expected='\"\$expected\" >&2; exit 1; }"

test_end

# ============================================================================
# 5. Negative scenario (c): mismatching mac_master0 aborts with MAC-03
# ============================================================================
test_begin "Negative: bmc.conf with mismatching mac_master0 aborts at preflight with MAC-03"

# Clean up the cluster from Test 4
e2e_run "Delete cluster from Test 4 before re-running with mismatching mac_master0" \
	"if [ -d \$CLUSTER_DIR ]; then aba -y --dir \$CLUSTER_DIR delete; fi"

e2e_run "Re-init cluster dir for Test 5" \
	"mkdir -p \$CLUSTER_DIR"

e2e_run "Re-create cluster.conf for Test 5" \
	"cd ~/aba && aba cluster -n $CLUSTER -t sno --starting-ip $(pool_node_ip) --step cluster.conf"

# Restore bmc.conf and inject a deliberately wrong mac_master0 (D-08 abort path)
e2e_run "Restore bmc.conf snapshot and inject mismatching mac_master0=99:99:99:99:99:99" \
	"cp -v \$CLUSTER_DIR/bmc.conf.mac-discovery-bak \$CLUSTER_DIR/bmc.conf && \
	 printf 'mac_master0=%s\n' '99:99:99:99:99:99' >> \$CLUSTER_DIR/bmc.conf && \
	 chmod 600 \$CLUSTER_DIR/bmc.conf"

# Must fail at preflight; capture stdout+stderr for assertions
e2e_run_must_fail "aba install with mismatching mac aborts at preflight" \
	"cd \$CLUSTER_DIR && aba install 2>&1 | tee install-mac03.log"

# D-10 MAC-03 contract: operator-supplied MAC + BMC NIC summary in the error
e2e_run "Assert install-mac03.log contains MAC-03 error code" \
	"grep -q 'MAC-03:' \$CLUSTER_DIR/install-mac03.log"

e2e_run "Assert install-mac03.log echoes the operator mac_master0=99:99:99:99:99:99" \
	"grep -q 'operator mac_master0=99:99:99:99:99:99' \$CLUSTER_DIR/install-mac03.log"

e2e_run "Assert install-mac03.log includes the BMC-reported NICs summary" \
	"grep -q 'reported NICs:' \$CLUSTER_DIR/install-mac03.log"

# D-09 negative contract: preflight aborts BEFORE BMC writes -> stamp absent
e2e_run "Assert .bm-bmc-boot-done is absent (preflight aborted before BMC writes)" \
	"test ! -f \$CLUSTER_DIR/.bm-bmc-boot-done"

test_end

# ============================================================================
# 6. Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot
# ============================================================================
test_begin "Cleanup: bmc-unmount + delete cluster + restore bmc.conf snapshot"

# Restore the working bmc.conf so bmc-unmount can authenticate
e2e_run "Restore working bmc.conf for unmount" \
	"if [ -f \$CLUSTER_DIR/bmc.conf.mac-discovery-bak ]; then cp -v \$CLUSTER_DIR/bmc.conf.mac-discovery-bak \$CLUSTER_DIR/bmc.conf; fi"

# Best-effort BMC unmount (Phase 6 D-13 idempotent; Phase 7 D-17 positional arg)
e2e_run "BMC unmount master0 (idempotent best-effort)" \
	"cd \$CLUSTER_DIR && ~/aba/scripts/bmc-unmount.sh master0"

# Delete cluster (only if it still exists; aba delete is idempotent on missing cluster)
e2e_run "Delete cluster" \
	"if [ -d \$CLUSTER_DIR ]; then aba -y --dir \$CLUSTER_DIR delete; else echo '[cleanup] \$CLUSTER_DIR already removed'; fi"

# Remove the mac-discovery snapshot (last step in cleanup, matching Phase 9 D-11 pattern)
e2e_run "Remove bmc.conf.mac-discovery-bak snapshot" \
	"rm -f \$CLUSTER_DIR/bmc.conf.mac-discovery-bak"

# Also clean up the preflight-bak if Test 2 created one (pre-existing bmc.conf preservation)
e2e_run "Restore any pre-existing bmc.conf snapshot from Test 2" \
	"if [ -f \$CLUSTER_DIR/bmc.conf.preflight-bak ]; then cp -v \$CLUSTER_DIR/bmc.conf.preflight-bak \$CLUSTER_DIR/bmc.conf && rm -f \$CLUSTER_DIR/bmc.conf.preflight-bak; fi"

test_end

# ============================================================================

suite_end
