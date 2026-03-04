#!/usr/bin/env bash
# =============================================================================
# Suite: Negative / Error Path Tests
# =============================================================================
# Purpose: Verify that invalid inputs, bad state, and error conditions are
#          caught and reported cleanly.  All tests use e2e_run_must_fail.
#          No VMs are created -- suite should complete in under 5 minutes.
#
# What it tests:
#   - aba.conf validation (bad version, channel, domain, dns, ntp, prefix)
#   - aba clean / mirror clean (state removal)
#   - Version mismatch detection
#   - Bundle errors (invalid operator, op-set, permissions)
#   - Registry errors (load without save, sync to unknown host)
#   - Cluster errors (non-existent dir, bad config values)
#
# Prerequisites:
#   - aba must be installed (./install)
#   - aba.conf must exist
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"

DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
INTERNAL_BASTION="$(pool_internal_bastion)"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: install and configure" \
	"aba.conf validation" \
	"Clean commands" \
	"Version mismatch" \
	"Bundle errors" \
	"Registry errors" \
	"Cluster config errors"

suite_begin "negative-paths"

# ============================================================================
# 1. Setup: install and configure
# ============================================================================
test_begin "Setup: install and configure"

e2e_run "Install aba" "./install"
e2e_run "Configure aba.conf" \
	"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers" \
	"sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"
e2e_run "Backup good aba.conf" "cp aba.conf aba.conf.good"

test_end 0

# ============================================================================
# 2. aba.conf validation
# ============================================================================
test_begin "aba.conf validation"

e2e_run "Set bad ocp_version" "sed -i 's/^ocp_version=.*/ocp_version=NOTAVERSION/' aba.conf"
e2e_run_must_fail "Bad ocp_version rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad ocp_channel" "sed -i 's/^ocp_channel=.*/ocp_channel=boguschannel/' aba.conf"
e2e_run_must_fail "Bad ocp_channel rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad domain" "sed -i 's/^domain=.*/domain=!!!invalid!!!/' aba.conf"
e2e_run_must_fail "Bad domain rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad dns_servers" "sed -i 's/^dns_servers=.*/dns_servers=not.an.ip.addr/' aba.conf"
e2e_run_must_fail "Bad dns_servers rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad ntp_servers" "sed -i 's/^ntp_servers=.*/ntp_servers=@@@invalid/' aba.conf"
e2e_run_must_fail "Bad ntp_servers rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad prefix_length" "sed -i 's/^prefix_length=.*/prefix_length=99/' aba.conf"
e2e_run_must_fail "Bad prefix_length rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad platform" "sed -i 's/^platform=.*/platform=bogus/' aba.conf"
e2e_run_must_fail "Bad platform rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set empty ocp_version" "sed -i 's/^ocp_version=.*/ocp_version=/' aba.conf"
e2e_run_must_fail "Empty ocp_version rejected" "aba -d mirror save"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

test_end 0

# ============================================================================
# 3. Clean commands
# ============================================================================
test_begin "Clean commands"

e2e_run "Ensure mirror dir exists" "mkdir -p mirror"
e2e_run "Run aba -d mirror clean" "aba -d mirror clean"
e2e_run "Verify init marker removed" "test ! -f mirror/.init"
e2e_run "Verify imageset configs removed" "! ls mirror/imageset-config-*.yaml 2>/dev/null"

e2e_run "Run aba clean (top-level)" "aba clean"
e2e_run "Verify aba.conf.seen cleaned" "test ! -f .aba.conf.seen"

e2e_run "Re-install after clean" "./install"
e2e_run "Reconfigure after clean" \
	"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers" \
	"sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

test_end 0

# ============================================================================
# 4. Version mismatch detection
# ============================================================================
test_begin "Version mismatch"

e2e_run "Ensure CLIs are installed" "aba -d cli install"
e2e_run "Save current version" "grep '^ocp_version=' aba.conf > /tmp/e2e-saved-version"
e2e_run "Set mismatched version" "sed -i 's/^ocp_version=.*/ocp_version=4.14.0/' aba.conf"
e2e_run_must_fail "Version mismatch detected" "aba -d mirror save"
e2e_run "Restore version" "source /tmp/e2e-saved-version && sed -i \"s/^ocp_version=.*/ocp_version=\$ocp_version/\" aba.conf"

test_end 0

# ============================================================================
# 5. Bundle errors
# ============================================================================
test_begin "Bundle errors"

e2e_run "Backup aba.conf for bundle tests" "cp aba.conf aba.conf.good"

e2e_run_must_fail "Invalid op-set name" \
	"aba bundle --op-sets nonexistent-set-xyz"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run_must_fail "Bundle to read-only path" \
	"aba bundle --out /root/e2e-noperm-test"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

test_end 0

# ============================================================================
# 6. Registry errors
# ============================================================================
test_begin "Registry errors"

e2e_run_must_fail "Mirror command on non-existent dir" \
	"aba --dir /tmp/e2e-nonexistent-mirror-dir save"

e2e_run_must_fail "Mirror with bad vendor" \
	"aba mirror --vendor bogusvendor"

e2e_run_must_fail_remote "Load without save dir on internal bastion" \
	"cd ~/aba && rm -rf mirror/save && aba -d mirror load"

test_end 0

# ============================================================================
# 7. Cluster config errors
# ============================================================================
test_begin "Cluster config errors"

e2e_run_must_fail "Delete non-existent cluster" \
	"aba --dir nonexistent-cluster-xyz delete"

e2e_run_must_fail "Run on non-existent cluster" \
	"aba --dir nonexistent-cluster-xyz run"

e2e_run "Backup aba.conf for cluster tests" "cp aba.conf aba.conf.good"

e2e_run_must_fail "Cluster with bad --api-vip" \
	"aba cluster --api-vip 999.999.999.999"

e2e_run_must_fail "Cluster with bad --dns" \
	"aba cluster --dns not-an-ip"

e2e_run_must_fail "Cluster with bad ingress-vip" \
	"aba cluster --ingress-vip 999.999.999.999"

e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-negative-paths.sh"
