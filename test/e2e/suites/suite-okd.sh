#!/usr/bin/env bash
# =============================================================================
# Suite: OKD
# =============================================================================
# Purpose: Fresh OKD install paths on one pool, using this tree (run.sh --dev).
#          OpenShift suites do not set distribution=okd, so they are not a
#          substitute.
#
#   - Resolve the previous stable OKD minor and reject OpenShift-only channels
#   - Stop upgrade and the Red Hat day-2 commands
#   - Direct and proxy install-config (no mirror sources)
#   - Image set pins the release digest and one community-catalog operator
#   - One proxy SNO install from the internet (release only)
#   - Save and load that release plus the operator, with --remove-signatures
#   - Install one SNO from the mirror, then day2, and see the operator in the catalog
#
# The virt set names Red Hat operators. OKD reads only the community catalog.
# day2-virt and day2-osus stay rejected. The operator under test is
# community-kubevirt-hyperconverged.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/suite-helpers.sh"

# --- Configuration ----------------------------------------------------------

NTP_IP="${NTP_SERVER:-10.0.1.8}"
DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
INTERNAL_BASTION="$(pool_internal_bastion)"
SNO="$(pool_cluster_name sno)"

# aba --version writes the version, starts cli-download-all.sh and the
# catalog downloads, and returns. Both keep running under ~/.aba/runner.
# Wait, then require each task's exit file to be 0 and the pid to be gone.
# The catalog wait has to finish too: its run_once waiters are subshells of
# that aba process, so a suite that only waits for the CLIs still looks like
# it left aba running.
okd_wait_cli_downloads() {
	e2e_run "Wait for CLI downloads started by --version" \
		"cd ~/aba && scripts/cli-download-all.sh --wait"
	e2e_run "Runner exit files are 0 and those downloads have exited" \
		'cd ~/aba && items=$(make --no-print-directory -sC cli out-download-all) || exit 1; [ -n "$items" ] || exit 1; for item in $items; do d="$HOME/.aba/runner/cli:download:${item}"; rc=$(cat "$d/exit" 2>/dev/null) || rc=MISSING; echo "cli:download:$item exit=$rc"; [ "$rc" = 0 ] || exit 1; if [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "still running: cli:download:$item pid $(cat "$d/pid")"; exit 1; fi; done'
	e2e_run "Wait for catalog downloads started by --version" \
		"cd ~/aba && scripts/download-and-wait-catalogs.sh"
	e2e_run "Catalog runner exit files are 0 and those downloads have exited" \
		'cd ~/aba && source scripts/include_all.sh && source <(normalize-aba-conf) && minor=$(_ver_minor "$ocp_version") && [ -n "$minor" ] || exit 1; for catalog in $(dist_catalogs); do d="$HOME/.aba/runner/catalog:${minor}:${catalog}"; rc=$(cat "$d/exit" 2>/dev/null) || rc=MISSING; echo "catalog:$minor:$catalog exit=$rc"; [ "$rc" = 0 ] || exit 1; if [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo "still running: catalog:$minor:$catalog pid $(cat "$d/pid")"; exit 1; fi; done'
}

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests \
	"Setup: OKD config" \
	"Guards: channel and unsupported commands" \
	"Direct: install-config" \
	"Proxy: install-config" \
	"Image set: release digest" \
	"Community operator is in the image set" \
	"Proxy: install SNO" \
	"Proxy: verify and delete" \
	"Save: mirror to disk" \
	"Air gap: load on disN" \
	"Air gap: install SNO from the mirror" \
	"Air gap: day2 community catalog" \
	"Cleanup: delete cluster and restore OpenShift"

suite_begin "okd"

# ============================================================================
# 1. Setup
# ============================================================================
test_begin "Setup: OKD config"

e2e_install_aba --curl

# latest follows the newest minor. 5.0's agent image is the one that
# failed secure boot and the registration race. previous is the prior minor.
e2e_run "Select OKD stable and the previous release" \
	"aba --distribution okd --noask --platform vmw --channel stable --version previous \
		--base-domain $(pool_domain) --machine-network $(pool_machine_network) \
		--gateway $(pool_gateway) --dns $(pool_dns_server) --ntp ${NTP_IP}"
okd_wait_cli_downloads

e2e_run "Verify distribution=okd" "grep '^distribution=okd' aba.conf"
e2e_run "Verify channel=stable" "grep '^ocp_channel=stable' aba.conf"
e2e_run "Verify an OKD release version" \
	"grep -E '^ocp_version=[0-9]+\\.[0-9]+\\.[0-9]+-okd-scos\\.[0-9]+' aba.conf"

suite_setup_vmware_env

test_end

# ============================================================================
# 2. Guards
# ============================================================================
test_begin "Guards: channel and unsupported commands"

e2e_run "Reject the fast channel" \
	"aba --channel fast >/tmp/e2e-okd-channel.out 2>&1 || true; grep -q 'not a channel' /tmp/e2e-okd-channel.out"
e2e_run "Reject --upgrade-to" \
	"aba --upgrade-to 9.9.9-okd-scos.1 >/tmp/e2e-okd-upgrade-to.out 2>&1 || true; grep -q 'unsupported for OKD' /tmp/e2e-okd-upgrade-to.out"

# A cluster directory is required before the command guard runs.
e2e_run "Create a config-only cluster dir for the command guards" \
	"rm -rf $SNO && aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I direct --step cluster.conf"

for _op in upgrade upgrade-mon day2-osus day2-virt; do
	e2e_run "Reject ${_op}" \
		"aba -d $SNO ${_op} >/tmp/e2e-okd-guard.out 2>&1 || true; grep -q 'unsupported for OKD' /tmp/e2e-okd-guard.out"
done

test_end

# ============================================================================
# 3. Direct install-config
# ============================================================================
test_begin "Direct: install-config"

unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
[ -f ~/.proxy-unset.sh ] && source ~/.proxy-unset.sh

e2e_run "Generate direct agent config" "aba -d $SNO agentconf"
assert_file_exists "$SNO/install-config.yaml"
e2e_run "Direct: image_source=direct" "grep '^image_source=direct' $SNO/cluster.conf"
e2e_run "Direct: no imageContentSources" "! grep imageContentSources $SNO/install-config.yaml"
e2e_run "Direct: no proxy" "! grep httpProxy $SNO/install-config.yaml"

test_end

# ============================================================================
# 4. Proxy install-config
# ============================================================================
test_begin "Proxy: install-config"

[ -f ~/.proxy-set.sh ] && source ~/.proxy-set.sh

# No VM exists yet. Replace the direct config so -I proxy is what gets rendered.
e2e_run "Replace cluster dir for proxy" "rm -rf $SNO"
e2e_run "Create proxy cluster config" \
	"aba cluster -n $SNO -t sno -i $(pool_sno_ip) -I proxy --step cluster.conf"
e2e_run "Write the lab proxy into cluster.conf" \
	"sed -i 's|^#http_proxy=.*|http_proxy=http://10.0.1.8:3128|' $SNO/cluster.conf && \
	 sed -i 's|^#https_proxy=.*|https_proxy=http://10.0.1.8:3128|' $SNO/cluster.conf && \
	 sed -i 's|^#no_proxy=.*|no_proxy=.lan,.example.com|' $SNO/cluster.conf"
e2e_run "Generate proxy agent config" "aba -d $SNO agentconf"

assert_file_exists "$SNO/install-config.yaml"
e2e_run "Proxy: httpProxy is set" "grep httpProxy $SNO/install-config.yaml"
e2e_run "Proxy: httpsProxy is set" "grep httpsProxy $SNO/install-config.yaml"
e2e_run "Proxy: no imageContentSources" "! grep imageContentSources $SNO/install-config.yaml"

test_end

# ============================================================================
# 5. Image set pins the OKD release
# ============================================================================
test_begin "Image set: release digest"

e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
e2e_run "Render the image set" \
	"rm -f mirror/data/imageset-config.yaml && make -C mirror data/imageset-config.yaml"
e2e_run "Release is pinned by digest" \
	"grep -q 'quay.io/okd/scos-release@sha256:' mirror/data/imageset-config.yaml"
e2e_run "Graph data is off for a pinned release" \
	"grep -q 'graph: false' mirror/data/imageset-config.yaml"

test_end

# ============================================================================
# 6. Keep one community operator selected. Save and load mirror its images.
# The proxy install below does not use this mirror.
# ============================================================================
test_begin "Community operator is in the image set"

e2e_run "Select a community operator" "aba --ops community-kubevirt-hyperconverged"
e2e_run "Re-render the image set with that operator" \
	"rm -f mirror/data/imageset-config.yaml && make -C mirror data/imageset-config.yaml"
e2e_run "community-kubevirt-hyperconverged is in the image set" \
	"grep -q community-kubevirt-hyperconverged mirror/data/imageset-config.yaml"

test_end

# ============================================================================
# 7. Proxy SNO install
# ============================================================================
test_begin "Proxy: install SNO"

e2e_add_to_cluster_cleanup "$PWD/$SNO"
e2e_run -r 2 10 "Install SNO through the proxy" "aba -d $SNO install"

test_end

# ============================================================================
# 8. Verify the proxy cluster, then delete it so the air-gap install can reuse the name
# ============================================================================
test_begin "Proxy: verify and delete"

e2e_wait_cluster_ready "$SNO" local 3300
e2e_run "Cluster version is an OKD release" \
	"aba --dir $SNO run --cmd 'oc get clusterversion version -o jsonpath={.status.desired.version}' | grep -q okd-scos"
e2e_run "Delete the proxy cluster" "aba --dir $SNO delete --yes"

test_end

# ============================================================================
# 9. Save
# ============================================================================
test_begin "Save: mirror to disk"

# The proxy install exported http_proxy in this shell. Save talks to quay.io directly.
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
[ -f ~/.proxy-unset.sh ] && source ~/.proxy-unset.sh

e2e_run -r 2 10 "Save the OKD release to disk" \
	"set -o pipefail; aba -d mirror save --retry 2>&1 | tee /tmp/e2e-okd-save.log"
e2e_run "Save passed --remove-signatures to oc-mirror" \
	"grep -q -- '--remove-signatures' /tmp/e2e-okd-save.log"
e2e_run "Archive exists" "ls mirror/data/mirror_*.tar >/dev/null"

test_end

# ============================================================================
# 10. Load on the disconnected bastion
# ============================================================================
test_begin "Air gap: load on disN"

# A normal bundle never includes mirror/mirror.conf. --primed is the
# only bundle that packs it. Create the file on disN and point it here.
e2e_run -r 2 10 "Bundle the tree to disN" \
	"aba -y -f bundle -o - | ssh ${INTERNAL_BASTION} 'tar xf - -C ~'"
e2e_run_remote "Install ABA on disN" "cd ~/aba && ./install"
e2e_run_remote "Setup DNS on disN" "cd ~/aba && aba setup dns -y"
e2e_run_remote "Create mirror.conf on disN" \
	"cd ~/aba && aba -d mirror mirror.conf"
e2e_run_remote "Point the registry at disN" \
	"cd ~/aba && aba --dir mirror --vendor omr --reg-host ${DIS_HOST}"
e2e_add_to_mirror_cleanup "$PWD/mirror" remote
e2e_run_remote "Install the registry on disN" "cd ~/aba && aba -d mirror install"
e2e_run_remote -r 2 10 "Load the archive" \
	"cd ~/aba && set -o pipefail; aba -d mirror load --retry 2>&1 | tee /tmp/e2e-okd-load.log"
e2e_run_remote "Load passed --remove-signatures to oc-mirror" \
	"grep -q -- '--remove-signatures' /tmp/e2e-okd-load.log"
e2e_run_remote "Load wrote a community CatalogSource" \
	"cd ~/aba && ls mirror/data/working-dir/cluster-resources/cs-community-operator-index*.yaml >/dev/null"

test_end

# ============================================================================
# 11. Install from the loaded registry
# ============================================================================
test_begin "Air gap: install SNO from the mirror"

e2e_add_to_cluster_cleanup "$PWD/$SNO" remote
e2e_run_remote "Create the mirror-backed cluster config" \
	"cd ~/aba && aba cluster -n $SNO -t sno --starting-ip $(pool_sno_ip) --step cluster.conf"
e2e_run_remote -r 2 10 "Install SNO from the loaded registry" \
	"aba -d ~/aba/$SNO install"
e2e_wait_cluster_ready "$SNO" remote 3300
e2e_run_remote "Mirrored cluster version is an OKD release" \
	"cd ~/aba && aba --dir $SNO run --cmd 'oc get clusterversion version -o jsonpath={.status.desired.version}' | grep -q okd-scos"

test_end

# ============================================================================
# 12. day2 applies the mirrored community catalog
# ============================================================================
test_begin "Air gap: day2 community catalog"

e2e_run_remote -r 2 10 "Apply day2 from the mirror" \
	"cd ~/aba && aba --dir $SNO day2"
e2e_poll_remote 180 15 "community-kubevirt-hyperconverged is in the catalog" \
	"cd ~/aba && aba --dir $SNO run --cmd 'oc get packagemanifests' | grep -q community-kubevirt-hyperconverged"

test_end

# ============================================================================
# 13. Cleanup
# ============================================================================
test_begin "Cleanup: delete cluster and restore OpenShift"

e2e_run_remote "Delete the mirrored cluster" \
	"cd ~/aba && aba --dir $SNO delete --yes"
e2e_run_remote "Uninstall the registry" \
	"cd ~/aba && aba -d mirror uninstall --delete-data || true"

# The next OpenShift suite on this pool must not inherit distribution=okd.
e2e_run "Restore OpenShift defaults" \
	"aba --distribution ocp --noask --platform vmw --channel ${TEST_CHANNEL:-stable} --version ${OCP_VERSION:-p} \
		--base-domain $(pool_domain) --machine-network $(pool_machine_network) --gateway $(pool_gateway)"
okd_wait_cli_downloads
e2e_run "distribution is OpenShift" "grep -q '^distribution=ocp$' aba.conf"

test_end
