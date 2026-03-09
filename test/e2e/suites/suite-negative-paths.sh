#!/usr/bin/env bash
# =============================================================================
# Suite: Negative / Error Path Tests
# =============================================================================
# Purpose: Verify that invalid inputs, bad state, and error conditions are
#          caught and reported cleanly.  All tests use e2e_run_must_fail.
#          No VMs are created -- suite should complete in under 5 minutes.
#
# What it tests:
#   - aba.conf validation (bad version, channel, domain, dns, ntp, machine_network)
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

e2e_run "Reset aba to clean state" \
	"cd ~/aba && aba reset --force"

e2e_run "Remove oc-mirror caches" \
	"sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rf"

e2e_run "Verify /home disk usage < 10GB after reset" \
	"used_gb=\$(df /home --output=used -BG | tail -1 | tr -d ' G'); echo \"[setup] /home used: \${used_gb}GB\"; [ \$used_gb -lt 10 ]"

e2e_run "Install aba" "./install"
e2e_run "Configure aba.conf" \
	"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers" \
	"sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"
e2e_run "Backup good aba.conf" "cp aba.conf aba.conf.good"
e2e_run "Ensure mirror dir initialised" "make -sC mirror init"

test_end 0

# ============================================================================
# 2. aba.conf validation
# ============================================================================
test_begin "aba.conf validation"

_ABA_VERIFY="cd mirror && bash -c 'source scripts/include_all.sh && source <(normalize-aba-conf) && verify-aba-conf'"

e2e_run "Set bad ocp_version" "sed -i 's/^ocp_version=.*/ocp_version=NOTAVERSION/' aba.conf"
e2e_run_must_fail "Bad ocp_version rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad ocp_channel" "sed -i 's/^ocp_channel=.*/ocp_channel=boguschannel/' aba.conf"
e2e_run_must_fail "Bad ocp_channel rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad domain" "sed -i 's/^domain=.*/domain=!!!invalid!!!/' aba.conf"
e2e_run_must_fail "Bad domain rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad dns_servers" "sed -i 's/^dns_servers=.*/dns_servers=not.an.ip.addr/' aba.conf"
e2e_run_must_fail "Bad dns_servers rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad ntp_servers" "sed -i 's/^ntp_servers=.*/ntp_servers=@@@invalid/' aba.conf"
e2e_run_must_fail "Bad ntp_servers rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad machine_network CIDR" "sed -i 's/^machine_network=.*/machine_network=NOTACIDR/' aba.conf"
e2e_run_must_fail "Bad machine_network rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set bad platform" "sed -i 's/^platform=.*/platform=bogus/' aba.conf"
e2e_run_must_fail "Bad platform rejected" "$_ABA_VERIFY"
e2e_run "Restore aba.conf" "cp aba.conf.good aba.conf"

e2e_run "Set empty ocp_version" "sed -i 's/^ocp_version=.*/ocp_version=/' aba.conf"
e2e_run_must_fail "Empty ocp_version rejected" "$_ABA_VERIFY"
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
e2e_run "Re-init mirror dir" "make -sC mirror init"

test_end 0

# ============================================================================
# 4. Version mismatch detection
# ============================================================================
test_begin "Version mismatch"

e2e_run "Ensure CLIs are installed" "aba -d cli install"
e2e_run "Create dummy imageset-config for mismatch check" \
	"mkdir -p mirror/save && touch mirror/save/.created && sleep 1 && cat > mirror/save/imageset-config-save.yaml <<'ENDYAML'
mirror:
  platform:
    channels:
    - name: stable-4.20
      minVersion: 4.20.0
      maxVersion: 4.20.14
ENDYAML"
e2e_run "Save current version" "grep '^ocp_version=' aba.conf > /tmp/e2e-saved-version"
e2e_run "Set mismatched version" "sed -i 's/^ocp_version=.*/ocp_version=4.14.0/' aba.conf"
e2e_run_must_fail "Version mismatch detected" "make -sC mirror checkversion"
e2e_run "Restore version" "source /tmp/e2e-saved-version && sed -i \"s/^ocp_version=.*/ocp_version=\$ocp_version/\" aba.conf"
e2e_run "Remove dummy imageset-config" "rm -f mirror/save/imageset-config-save.yaml"

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

# Registry install negative tests (ported from old test2 lines 176-179)
# These verify reg_detect_existing() and reg_check_fqdn() catch bad installs.
e2e_run_must_fail "Install to unknown host must fail" \
	"aba -d mirror install -H unknown.example.com"
e2e_run "Restore reg_host after unknown-host test" \
	"sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf"

e2e_run_must_fail "Install to localhost with remote key must fail" \
	"aba -d mirror install -k ~/.ssh/id_rsa -H \$(hostname -f)"
e2e_run "Restore mirror.conf after localhost test" \
	"sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf && sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/' mirror/mirror.conf"

# Reinstall detection: reg_detect_existing() must abort when state.sh shows
# ABA already installed a registry at this host.
e2e_run "Set reg_host for reinstall test" \
	"aba -d mirror -H \$(hostname -f)"
e2e_run "Create fake state.sh for reinstall test" \
	"mkdir -p ~/.aba/mirror/mirror && echo REG_HOST=\$(hostname -f) > ~/.aba/mirror/mirror/state.sh"
e2e_run "Remove .available to trigger install path" \
	"rm -f mirror/.available"
e2e_run_must_fail "Reinstall of existing registry must abort" \
	"cd mirror && bash -c 'source scripts/reg-common.sh && reg_load_config && reg_check_fqdn && reg_detect_existing'"
e2e_run "Cleanup reinstall test state" \
	"rm -f ~/.aba/mirror/mirror/state.sh && sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf"

# Verify without credentials: must fail with user-friendly message
e2e_run "Set reg_host for verify test" \
	"aba -d mirror -H \$(hostname -f)"
e2e_run "Ensure no credentials exist" \
	"rm -f ~/.aba/mirror/mirror/pull-secret-mirror.json ~/.aba/mirror/mirror/rootCA.pem"
e2e_run_must_fail "Verify without credentials must fail" \
	"aba -d mirror verify"
e2e_run "Restore mirror.conf after verify test" \
	"sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf"

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
