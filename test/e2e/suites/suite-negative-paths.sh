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
	"Docker registry install and recovery" \
	"Cluster config errors"

suite_begin "negative-paths"

# ============================================================================
# 1. Setup: install and configure
# ============================================================================
test_begin "Setup: install and configure"

e2e_run "Reset aba to clean state" \
	"cd ~/aba && ./install && aba reset -f"

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

# "Load without save dir" moved to suite-airgapped-existing-reg (where a
# registry is already registered on disN, avoiding accidental Quay install).

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

# Idempotent install: reg_detect_existing() must skip install (exit 0) when
# state.sh shows ABA already installed a healthy registry at this host.
e2e_run "Set reg_host for idempotent install test" \
	"aba -d mirror -H \$(hostname -f)"
e2e_run "Create fake state.sh for idempotent install test" \
	"mkdir -p ~/.aba/mirror/mirror && echo REG_HOST=\$(hostname -f) > ~/.aba/mirror/mirror/state.sh"
e2e_run "Remove .available to trigger install path" \
	"rm -f mirror/.available"
e2e_run "Idempotent install on healthy registry must succeed" \
	"cd mirror && bash -c 'source scripts/reg-common.sh && reg_load_config && reg_detect_existing && reg_check_fqdn'"
e2e_run "Cleanup idempotent install test state" \
	"rm -f ~/.aba/mirror/mirror/state.sh && sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf"

# Stale state detection: reg_detect_existing() must clear state.sh and proceed
# when the saved registry host is unreachable (e.g. VM reverted, registry wiped).
e2e_run "Create stale state.sh for gone registry" \
	"mkdir -p ~/.aba/mirror/mirror && echo REG_HOST=gone-registry.example.com > ~/.aba/mirror/mirror/state.sh"
e2e_run "Set reg_host to match stale state" \
	"aba -d mirror -H gone-registry.example.com"
e2e_run "Remove .available to trigger install path" \
	"rm -f mirror/.available"
e2e_run "Stale state must be detected and cleared" \
	"cd mirror && bash -c 'source scripts/reg-common.sh && reg_load_config && reg_detect_existing' 2>&1 | grep 'unreachable'"
e2e_run "Verify state.sh was removed" \
	"test ! -f ~/.aba/mirror/mirror/state.sh"
e2e_run "Cleanup stale state test" \
	"sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf"

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
# 7. Docker registry install and recovery
# ============================================================================
test_begin "Docker registry install and recovery"

_DOCKER_MIRROR="e2e-docker-test"
_DOCKER_PORT=5005
_DOCKER_NEG_MIRROR="e2e-docker-neg"
_DOCKER_NEG_PORT=5002
_DOCKER_FQDN="$DIS_HOST"

# --- Test A: Docker install/verify/uninstall with --network host -----------

e2e_run "Create $_DOCKER_MIRROR dir" "aba mirror --name $_DOCKER_MIRROR"
e2e_add_to_mirror_cleanup "\$PWD/$_DOCKER_MIRROR"

e2e_run "Install Docker registry on port $_DOCKER_PORT" \
	"aba -d $_DOCKER_MIRROR install --vendor docker --reg-port $_DOCKER_PORT -H $_DOCKER_FQDN -k ~/.ssh/id_rsa"

e2e_run "Credentials saved: state.sh exists" \
	"test -s ~/.aba/mirror/$_DOCKER_MIRROR/state.sh"

e2e_run "state.sh has REG_VENDOR=docker" \
	"grep 'REG_VENDOR=docker' ~/.aba/mirror/$_DOCKER_MIRROR/state.sh"

e2e_run "state.sh has correct port" \
	"grep 'REG_PORT=$_DOCKER_PORT' ~/.aba/mirror/$_DOCKER_MIRROR/state.sh"

e2e_run "Verify Docker registry accessible" \
	"aba -d $_DOCKER_MIRROR verify"

e2e_run "Registry container is running on disN" \
	"_essh $DIS_HOST 'podman ps --format {{.Names}} | grep registry'"

e2e_run "Registry responds on FQDN" \
	"curl -k -sf -u init:p4ssw0rd https://$_DOCKER_FQDN:$_DOCKER_PORT/v2/"

# --- Test C: Uninstall with missing state (fallback detection) -------------
# (done before Test B so we can reuse the running container from Test A)

e2e_run "Delete all credentials to simulate lost state" \
	"rm -rf ~/.aba/mirror/$_DOCKER_MIRROR"

e2e_run "Verify state.sh is gone" \
	"test ! -f ~/.aba/mirror/$_DOCKER_MIRROR/state.sh"

e2e_run "Uninstall with missing state (fallback path)" \
	"aba -y -d $_DOCKER_MIRROR uninstall"

e2e_run "Registry container gone after stateless uninstall" \
	"! _essh $DIS_HOST \"podman ps -a --format '{{.Names}}'\" | grep '^registry\$'"

e2e_run "Data directory removed" \
	"_essh $DIS_HOST 'test ! -d ~/docker-reg'"

# --- Test B: Credentials saved despite connectivity failure ----------------

e2e_run "Create $_DOCKER_NEG_MIRROR dir" "aba mirror --name $_DOCKER_NEG_MIRROR"
e2e_add_to_mirror_cleanup "\$PWD/$_DOCKER_NEG_MIRROR"

e2e_run "Block port $_DOCKER_NEG_PORT with iptables on disN" \
	"_essh $DIS_HOST 'sudo iptables -I INPUT 1 -p tcp --dport $_DOCKER_NEG_PORT -j REJECT'"

e2e_run_must_fail "Docker install fails on blocked port" \
	"aba -d $_DOCKER_NEG_MIRROR install --vendor docker --reg-port $_DOCKER_NEG_PORT -H $_DOCKER_FQDN -k ~/.ssh/id_rsa"

e2e_run "Credentials saved despite failure: pull-secret exists" \
	"test -s ~/.aba/mirror/$_DOCKER_NEG_MIRROR/pull-secret-mirror.json"

e2e_run "Credentials saved despite failure: rootCA.pem exists" \
	"test -s ~/.aba/mirror/$_DOCKER_NEG_MIRROR/rootCA.pem"

e2e_run "Credentials saved despite failure: state.sh exists" \
	"test -s ~/.aba/mirror/$_DOCKER_NEG_MIRROR/state.sh"

e2e_run "state.sh has REG_VENDOR=docker" \
	"grep 'REG_VENDOR=docker' ~/.aba/mirror/$_DOCKER_NEG_MIRROR/state.sh"

e2e_run "Unblock port $_DOCKER_NEG_PORT on disN" \
	"_essh $DIS_HOST 'sudo iptables -D INPUT -p tcp --dport $_DOCKER_NEG_PORT -j REJECT'"

e2e_run "Verify now succeeds after unblocking" \
	"aba -d $_DOCKER_NEG_MIRROR verify"

e2e_run "Uninstall neg-test registry" \
	"aba -y -d $_DOCKER_NEG_MIRROR uninstall"

# --- Cleanup ---------------------------------------------------------------

e2e_run "Remove test mirror dirs" \
	"rm -rf $_DOCKER_MIRROR $_DOCKER_NEG_MIRROR"

e2e_run "Remove leftover data dirs on disN" \
	"_essh $DIS_HOST 'rm -rf ~/docker-reg'"

e2e_run "Remove iptables rule on disN if still present" \
	"_essh $DIS_HOST 'sudo iptables -D INPUT -p tcp --dport $_DOCKER_NEG_PORT -j REJECT 2>/dev/null; true'"

test_end 0

# ============================================================================
# 8. Cluster config errors
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
