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
	"Auto-detect network values" \
	"cluster.conf validation" \
	"mirror.conf validation" \
	"mirror.conf ops/op_sets override" \
	"cluster.conf CLI flag override" \
	"Pre-release version support (RC/EC)" \
	"ESXi: stale GOVC_DATACENTER/GOVC_CLUSTER cleared (Bug #618)"

suite_begin "config-validation"

# ============================================================================
# 1. Setup: install and configure
# ============================================================================
test_begin "Setup: install and configure"

e2e_install_aba --curl

e2e_run "Configure aba.conf" \
	"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain)"

e2e_run "Create throwaway SNO cluster dir" \
	"aba cluster -n e2etmp -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run "Ensure mirror dir initialised" \
	"aba -d mirror mirror.conf"

test_end 0

# ============================================================================
# 2. Auto-detect network values
# ============================================================================
test_begin "Auto-detect network values"

e2e_run "Backup aba.conf" "cp aba.conf aba.conf.autodetect-bak"

e2e_run "Remove stale auto-detect cluster dirs" "rm -rf e2eauto e2eauto2"

e2e_run "Clear auto-detectable fields" \
	"sed -i 's/^domain=.*/domain=/' aba.conf && \
	 sed -i 's/^machine_network=.*/machine_network=/' aba.conf && \
	 sed -i 's/^dns_servers=.*/dns_servers=/' aba.conf && \
	 sed -i 's/^next_hop_address=.*/next_hop_address=/' aba.conf && \
	 sed -i 's/^ntp_servers=.*/ntp_servers=/' aba.conf"

e2e_run "Verify fields are empty" \
	"grep '^domain=$' aba.conf && \
	 grep '^machine_network=$' aba.conf && \
	 grep '^dns_servers=$' aba.conf && \
	 grep '^next_hop_address=$' aba.conf && \
	 grep '^ntp_servers=$' aba.conf"

# With ask=false (noask), auto-detect should succeed without aborting
e2e_run "Clean stale e2eauto dir if present" "rm -rf e2eauto"
e2e_run "Non-interactive: auto-detect succeeds (ask=false)" \
	"aba cluster -n e2eauto -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run "Verify domain was auto-detected" \
	"grep -E '^domain=.+' aba.conf"
e2e_run "Verify machine_network was auto-detected" \
	"grep -E '^machine_network=.+' aba.conf"
e2e_run "Verify dns_servers was auto-detected" \
	"grep -E '^dns_servers=.+' aba.conf"
e2e_run "Verify next_hop_address was auto-detected" \
	"grep -E '^next_hop_address=.+' aba.conf"
e2e_run "Verify ntp_servers was auto-detected" \
	"grep -E '^ntp_servers=.+' aba.conf"

e2e_run "Clean up auto-detect cluster dir" "rm -rf e2eauto"

# With ask=true (interactive mode), auto-detect should abort after writing values
e2e_run "Re-clear auto-detectable fields for ask=true test" \
	"sed -i 's/^domain=.*/domain=/' aba.conf && \
	 sed -i 's/^machine_network=.*/machine_network=/' aba.conf && \
	 sed -i 's/^dns_servers=.*/dns_servers=/' aba.conf && \
	 sed -i 's/^next_hop_address=.*/next_hop_address=/' aba.conf && \
	 sed -i 's/^ntp_servers=.*/ntp_servers=/' aba.conf && \
	 sed -i 's/^ask=.*/ask=true/' aba.conf"

e2e_run_must_fail "Interactive: auto-detect aborts (ask=true)" \
	"aba cluster -n e2eauto2 -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run "Clean up ask=true test artifacts" "rm -rf e2eauto2"
e2e_run "Restore aba.conf" "cp aba.conf.autodetect-bak aba.conf && rm -f aba.conf.autodetect-bak"

test_end 0

# ============================================================================
# 2b. Existing cluster.conf: fill empty network fields
# ============================================================================
test_begin "Existing cluster.conf: fill empty network fields"

e2e_run "Create a cluster.conf with populated values" \
	"aba cluster -n e2eexist -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"

e2e_run "Verify initial machine_network is set" \
	"grep -E '^machine_network=.+' e2eexist/cluster.conf"

e2e_run "Blank out network fields in cluster.conf" \
	"sed -i 's/^machine_network=.*/machine_network=/' e2eexist/cluster.conf && \
	 sed -i 's/^dns_servers=.*/dns_servers=/' e2eexist/cluster.conf && \
	 sed -i 's/^next_hop_address=.*/next_hop_address=/' e2eexist/cluster.conf && \
	 sed -i 's/^ntp_servers=.*/ntp_servers=/' e2eexist/cluster.conf"

e2e_run "Verify fields are now empty" \
	"grep '^machine_network=$' e2eexist/cluster.conf && \
	 grep '^dns_servers=$' e2eexist/cluster.conf && \
	 grep '^next_hop_address=$' e2eexist/cluster.conf"

e2e_run "Re-run --step cluster.conf fills empty fields from aba.conf" \
	"aba cluster -n e2eexist -t sno --step cluster.conf --yes"

e2e_run "Verify machine_network re-populated" \
	"grep -E '^machine_network=.+' e2eexist/cluster.conf"
e2e_run "Verify dns_servers re-populated" \
	"grep -E '^dns_servers=.+' e2eexist/cluster.conf"
e2e_run "Verify next_hop_address re-populated" \
	"grep -E '^next_hop_address=.+' e2eexist/cluster.conf"

e2e_run "Clean up e2eexist" "rm -rf e2eexist"

test_end 0

# ============================================================================
# 2c. NTP fallback for int_connection=direct only
# ============================================================================
test_begin "NTP fallback for int_connection=direct only"

e2e_run "Backup aba.conf" "cp aba.conf aba.conf.ntp-bak"

e2e_run "Clear ntp_servers in aba.conf" \
	"sed -i 's/^ntp_servers=.*/ntp_servers=/' aba.conf"

# With -I direct: if get_ntp_servers() returns empty, pool.ntp.org is used as fallback.
# On hosts with chrony, get_ntp_servers() finds local NTP, so we also verify it has SOME value.
e2e_run "Create cluster with -I direct" \
	"aba cluster -n e2entp -t sno --starting-ip $(pool_sno_ip) -I direct --step cluster.conf"
e2e_run "Verify ntp_servers has a value in cluster.conf" \
	"grep -E '^ntp_servers=.+' e2entp/cluster.conf"

e2e_run "Clean up e2entp" "rm -rf e2entp"

# Without -I (mirror mode): pool.ntp.org fallback must NOT appear.
# If chrony-detected NTP appears, that's fine -- just not the public fallback.
e2e_run "Create cluster without -I flag (mirror mode)" \
	"aba cluster -n e2entp2 -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"
e2e_run "Verify ntp_servers is NOT exactly pool.ntp.org (the direct-only fallback)" \
	"! grep '^ntp_servers=pool\\.ntp\\.org' e2entp2/cluster.conf"

e2e_run "Clean up e2entp2" "rm -rf e2entp2"
e2e_run "Restore aba.conf" "cp aba.conf.ntp-bak aba.conf && rm -f aba.conf.ntp-bak"

test_end 0

# ============================================================================
# 3. cluster.conf validation
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
# 4. mirror.conf validation
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
# 5. mirror.conf ops/op_sets override
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
# 6. cluster.conf CLI flag override (re-run aba cluster -n with different flags)
# ============================================================================
test_begin "cluster.conf CLI flag override"

_OVERRIDE_DIR="e2e-override-test"

e2e_run "Create cluster with initial flags" \
	"rm -rf $_OVERRIDE_DIR && aba cluster -n $_OVERRIDE_DIR -t sno --starting-ip $(pool_sno_ip) -I proxy --step cluster.conf"

e2e_run "Verify initial int_connection=proxy" \
	"grep '^int_connection=proxy' $_OVERRIDE_DIR/cluster.conf"

e2e_run "Override int_connection to direct" \
	"aba cluster -n $_OVERRIDE_DIR -I direct --step cluster.conf"

e2e_run "Verify overridden int_connection=direct" \
	"grep '^int_connection=direct' $_OVERRIDE_DIR/cluster.conf"

e2e_run "Verify num_masters unchanged (still 1 = SNO)" \
	"grep '^num_masters=1' $_OVERRIDE_DIR/cluster.conf"

e2e_run "Verify starting_ip unchanged" \
	"grep '^starting_ip=$(pool_sno_ip)' $_OVERRIDE_DIR/cluster.conf"

e2e_run "Clean up override test dir" "rm -rf $_OVERRIDE_DIR"

test_end 0

# ============================================================================
# 7. Pre-release version support (RC/EC)
# ============================================================================
test_begin "Pre-release version support (RC/EC)"

e2e_run "Backup aba.conf and mirror.conf" \
	"cp aba.conf aba.conf.prerel-bak && cp mirror/mirror.conf mirror/mirror.conf.prerel-bak"

# --- CLI acceptance ---

e2e_run "RC version accepted by --version" \
	"aba --noask --channel candidate --version 4.22.0-rc.1 2>&1 | tee /tmp/rc-out.txt && grep -q 'ocp_version=4.22.0-rc.1' aba.conf"

e2e_run "RC version triggers pre-release warning" \
	"grep -q 'Pre-release version' /tmp/rc-out.txt"

e2e_run "EC version accepted by --version" \
	"aba --noask --channel candidate --version 5.0.0-ec.2 2>&1 | tee /tmp/ec-out.txt && grep -q 'ocp_version=5.0.0-ec.2' aba.conf"

e2e_run "EC version triggers pre-release warning" \
	"grep -q 'Pre-release version' /tmp/ec-out.txt"

e2e_run "GA version accepted without warning" \
	"aba --noask --channel $TEST_CHANNEL --version $OCP_VERSION 2>&1 | tee /tmp/ga-out.txt && grep '^ocp_version=' aba.conf | awk -F= '{print \$2}' | awk '{print \$1}' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\$'"

e2e_run_must_fail "GA version does NOT trigger pre-release warning" \
	"grep 'Pre-release version' /tmp/ga-out.txt"

# --- Invalid pre-release formats rejected ---

e2e_run_must_fail "Uppercase RC rejected" \
	"aba --noask --channel candidate --version 4.22.0-RC.1"

e2e_run_must_fail "Missing suffix number rejected" \
	"aba --noask --channel candidate --version 4.22.0-rc"

e2e_run_must_fail "Dangling dash rejected" \
	"aba --noask --channel candidate --version 4.22.0-"

# --- ISC generation with RC version ---

e2e_run "Set RC version for ISC test" \
	"aba --noask --channel candidate --version 4.22.0-rc.1"

e2e_run "Remove existing ISC" \
	"rm -f mirror/data/imageset-config.yaml mirror/data/.created"

e2e_run "Ensure no ocp_version_target" \
	"sed -i 's/^ocp_version_target=.*/#ocp_version_target=/' mirror/mirror.conf"

e2e_run "Generate ISC with RC version" \
	"aba -d mirror imagesetconf"

e2e_run "ISC channel is candidate-4.22 (not candidate-4.22.0-rc)" \
	"grep 'name: candidate-4.22$' mirror/data/imageset-config.yaml"

e2e_run "ISC minVersion is 4.22.0-rc.1 (verbatim)" \
	"grep 'minVersion: 4.22.0-rc.1' mirror/data/imageset-config.yaml"

e2e_run "ISC maxVersion is 4.22.0-rc.1 (verbatim)" \
	"grep 'maxVersion: 4.22.0-rc.1' mirror/data/imageset-config.yaml"

# --- Version guard: target < source ---

e2e_run "Set versions for guard test" \
	"aba --noask --channel candidate --version 4.22.0-rc.1 && sed -i 's/^.*ocp_version_target=.*/ocp_version_target=4.21.18/' mirror/mirror.conf"

e2e_run "Remove ISC for guard test" \
	"rm -f mirror/data/imageset-config.yaml mirror/data/.created"

e2e_run "ISC generation warns and ignores when target < source" \
	"aba -d mirror imagesetconf"

# --- Version guard: valid upgrade allowed ---

e2e_run "Set valid upgrade path" \
	"aba --noask --channel $TEST_CHANNEL --version $OCP_VERSION && _resolved=\$(grep '^ocp_version=' aba.conf | awk -F= '{print \$2}' | awk '{print \$1}') && sed -i \"s/^.*ocp_version_target=.*/ocp_version_target=\$_resolved/\" mirror/mirror.conf"

e2e_run "Remove ISC for upgrade test" \
	"rm -f mirror/data/imageset-config.yaml mirror/data/.created"

e2e_run "ISC generation succeeds with valid upgrade" \
	"aba -d mirror imagesetconf"

# --- Cleanup ---

e2e_run "Restore aba.conf and mirror.conf" \
	"cp aba.conf.prerel-bak aba.conf && cp mirror/mirror.conf.prerel-bak mirror/mirror.conf && rm -f aba.conf.prerel-bak mirror/mirror.conf.prerel-bak"

e2e_run "Clean up generated ISC and temp files" \
	"rm -f mirror/data/imageset-config.yaml mirror/data/.created /tmp/rc-out.txt /tmp/ec-out.txt /tmp/ga-out.txt"

test_end 0

# ============================================================================
# 8. ESXi: stale GOVC_DATACENTER/GOVC_CLUSTER cleared (Bug #618)
# ============================================================================
test_begin "ESXi: stale GOVC_DATACENTER/GOVC_CLUSTER cleared (Bug #618)"

# Always uses the explicit ESXi config (~/.vmware.conf.esxi) so the test works
# regardless of whether run.sh was invoked with -v esxi or -v vcenter.
e2e_run "Ensure govc installed" "make -sC cli govc"
e2e_run "Copy ESXi vmware.conf" "cp -v ~/.vmware.conf.esxi vmware.conf"

e2e_run "Verify stale GOVC_DATACENTER/GOVC_CLUSTER cleared on ESXi" \
	"source scripts/include_all.sh && \
	 export GOVC_DATACENTER=StaleTestDC GOVC_CLUSTER=StaleTestCluster && \
	 source <(normalize-vmware-conf) && \
	 echo 'ESXi detected — checking stale vars cleared' && \
	 [ -z \"\$GOVC_DATACENTER\" ] || { echo \"FAIL: GOVC_DATACENTER='\$GOVC_DATACENTER' (expected empty)\"; exit 1; } && \
	 [ -z \"\$GOVC_CLUSTER\" ] || { echo \"FAIL: GOVC_CLUSTER='\$GOVC_CLUSTER' (expected empty)\"; exit 1; } && \
	 echo 'PASS: GOVC_DATACENTER and GOVC_CLUSTER are empty'"

e2e_run -q "Remove vmware.conf" "rm -f vmware.conf"

test_end

# ============================================================================

suite_end; _rc=$?

exit $_rc
