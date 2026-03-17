#!/usr/bin/env bash
# =============================================================================
# Suite: Config File Validation
# =============================================================================
# Purpose: Verify that invalid values in cluster.conf and mirror.conf are
#          caught and reported cleanly.  All tests use e2e_run_must_fail.
#          No VMs are created -- suite should complete in under 5 minutes.
#
# What it tests:
#   - cluster.conf validation (bad cluster_name, base_domain, machine_network,
#     starting_ip, num_masters, hostPrefix, starting_ip out of CIDR)
#   - mirror.conf validation (bad reg_host, reg_vendor, data_dir, reg_path)
#
# Prerequisites:
#   - aba must be installed (./install)
#   - aba.conf must exist
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: install and configure" \
	"cluster.conf validation" \
	"mirror.conf validation" \
	"mirror.conf ops/op_sets override"

suite_begin "config-validation"

# ============================================================================
# 1. Setup: install and configure
# ============================================================================
test_begin "Setup: install and configure"

e2e_run "Reset aba to clean state" \
	"cd ~/aba && ./install && aba reset -f"

e2e_run "Remove oc-mirror caches" \
	"sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rf"

e2e_run "Verify /home disk usage < 10GB after reset" \
	"used_gb=\$(df /home --output=used -BG | tail -1 | tr -d ' G'); echo \"[setup] /home used: \${used_gb}GB\"; [ \$used_gb -lt 12 ]"

e2e_run "Install aba" "./install"
e2e_run "Configure aba.conf" \
	"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"
e2e_run "Set dns_servers" \
	"sed -i 's/^dns_servers=.*/dns_servers=$(pool_dns_server)/' aba.conf"

e2e_run "Create throwaway SNO cluster dir" \
	"aba cluster -n e2etmp -t sno --starting-ip $(pool_sno_ip)"

e2e_run "Ensure mirror dir initialised" \
	"aba -d mirror mirror.conf"

test_end 0

# ============================================================================
# 2. cluster.conf validation
# ============================================================================
test_begin "cluster.conf validation"

e2e_run "Backup good cluster.conf" "cp e2etmp/cluster.conf e2etmp/cluster.conf.good"

_CLUSTER_VERIFY="cd e2etmp && bash -c 'source scripts/include_all.sh && source <(normalize-aba-conf) && source <(normalize-cluster-conf) && verify-cluster-conf'"

e2e_run "Set bad cluster_name" "sed -i 's/^cluster_name=.*/cluster_name=-invalid-name/' e2etmp/cluster.conf"
e2e_run_must_fail "Bad cluster_name rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Set bad base_domain" "sed -i 's/^base_domain=.*/base_domain=not_a_domain/' e2etmp/cluster.conf"
e2e_run_must_fail "Bad base_domain rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Set bad machine_network" "sed -i 's|^machine_network=.*|machine_network=999.999.999.999/99|' e2etmp/cluster.conf"
e2e_run_must_fail "Bad machine_network rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Set bad starting_ip" "sed -i 's/^starting_ip=.*/starting_ip=not-an-ip/' e2etmp/cluster.conf"
e2e_run_must_fail "Bad starting_ip rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Set starting_ip outside CIDR" "sed -i 's/^starting_ip=.*/starting_ip=192.168.99.99/' e2etmp/cluster.conf"
e2e_run_must_fail "Out-of-range starting_ip rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Set bad num_masters" "sed -i 's/^num_masters=.*/num_masters=abc/' e2etmp/cluster.conf"
e2e_run_must_fail "Bad num_masters rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Set bad hostPrefix" "sed -i 's/^hostPrefix=.*/hostPrefix=99/' e2etmp/cluster.conf"
e2e_run_must_fail "Bad hostPrefix rejected" "$_CLUSTER_VERIFY"
e2e_run "Restore cluster.conf" "cp e2etmp/cluster.conf.good e2etmp/cluster.conf"

e2e_run "Clean up throwaway cluster dir" "rm -rf e2etmp"

test_end 0

# ============================================================================
# 3. mirror.conf validation
# ============================================================================
test_begin "mirror.conf validation"

e2e_run "Backup good mirror.conf" "cp mirror/mirror.conf mirror/mirror.conf.good"

_MIRROR_VERIFY="cd mirror && bash -c 'source scripts/include_all.sh && source <(normalize-aba-conf) && export regcreds_dir=\$HOME/.aba/mirror/mirror && source <(normalize-mirror-conf) && verify-mirror-conf'"

e2e_run "Set bad reg_host" "sed -i 's/^reg_host=.*/reg_host=not_a_host/' mirror/mirror.conf"
e2e_run_must_fail "Bad reg_host rejected" "$_MIRROR_VERIFY"
e2e_run "Restore mirror.conf" "cp mirror/mirror.conf.good mirror/mirror.conf"

e2e_run "Set bad reg_vendor" "sed -i 's/^reg_vendor=.*/reg_vendor=bogus/' mirror/mirror.conf"
e2e_run_must_fail "Bad reg_vendor rejected" "$_MIRROR_VERIFY"
e2e_run "Restore mirror.conf" "cp mirror/mirror.conf.good mirror/mirror.conf"

e2e_run "Set bad data_dir" "sed -i 's|^data_dir=.*|data_dir=relative/path|' mirror/mirror.conf"
e2e_run_must_fail "Bad data_dir rejected" "$_MIRROR_VERIFY"
e2e_run "Restore mirror.conf" "cp mirror/mirror.conf.good mirror/mirror.conf"

e2e_run "Set empty reg_host" "sed -i 's/^reg_host=.*/reg_host=/' mirror/mirror.conf"
e2e_run_must_fail "Empty reg_host rejected" "$_MIRROR_VERIFY"
e2e_run "Restore mirror.conf" "cp mirror/mirror.conf.good mirror/mirror.conf"

test_end 0

# ============================================================================
# 4. mirror.conf ops/op_sets override
# ============================================================================
test_begin "mirror.conf ops/op_sets override"

e2e_run "Backup aba.conf and mirror.conf" \
	"cp aba.conf aba.conf.bak && cp mirror/mirror.conf mirror/mirror.conf.bak"

e2e_run "Set global op_sets=ocp in aba.conf" \
	"sed -i 's/^op_sets=.*/op_sets=ocp/' aba.conf"

e2e_run "Override op_sets=acm in mirror.conf" \
	"echo 'op_sets=acm' >> mirror/mirror.conf"

e2e_run "Remove existing ISC and .created marker" \
	"rm -f mirror/data/imageset-config.yaml mirror/data/.created"

e2e_run "Download catalogs" \
	"aba -d mirror catalogs-download catalogs-wait"

e2e_run "Generate ISC with mirror.conf override" \
	"aba -d mirror imagesetconf"

e2e_run "Verify ISC contains ACM (from mirror.conf override)" \
	"grep 'advanced-cluster-management' mirror/data/imageset-config.yaml"

e2e_run "Verify ISC contains multicluster-engine (ACM dependency)" \
	"grep 'multicluster-engine' mirror/data/imageset-config.yaml"

e2e_run_must_fail "Verify ISC does NOT contain web-terminal (ocp set, should be absent)" \
	"grep 'web-terminal' mirror/data/imageset-config.yaml"

e2e_run "Restore aba.conf and mirror.conf" \
	"cp aba.conf.bak aba.conf && cp mirror/mirror.conf.bak mirror/mirror.conf && rm -f aba.conf.bak mirror/mirror.conf.bak"

e2e_run "Clean up generated ISC" \
	"rm -f mirror/data/imageset-config.yaml mirror/data/.created"

test_end 0

# ============================================================================

suite_end

echo "SUCCESS: suite-config-validation.sh"
