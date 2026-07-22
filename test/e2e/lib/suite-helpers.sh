#!/usr/bin/env bash
# =============================================================================
# E2E Framework v2 -- Suite Helpers
# =============================================================================
# Shared multi-step operations extracted from integration suites. Each helper
# wraps a commonly repeated sequence of e2e_run / e2e_diag calls so suite
# files read like a high-level test plan.
#
# Depends on: lib/framework.sh (e2e_run, e2e_run_remote, e2e_diag)
#             lib/config-helpers.sh (pool_domain, pool_dns_server, pool_cluster_name)
#
# Source AFTER framework.sh and config-helpers.sh.
#
# All functions are optional -- suites can still inline commands when the
# helper doesn't fit. These are convenience, not enforcement.
# =============================================================================

# --- suite_configure_aba [opts...] -------------------------------------------
# Non-interactive ABA configuration: platform, channel, version, base-domain.
# dns_servers is auto-detected from conN's resolv.conf (pointing at local dnsmasq).
#
# Usage: suite_configure_aba [--extra-flag value ...]
suite_configure_aba() {
	# Gateway = first usable IP in machine_network (e.g. 10.0.0.0/20 → 10.0.0.1)
	local _mn _gw
	_mn=$(pool_machine_network)
	_gw="${_mn%%.*}.$(echo "${_mn#*.}" | sed 's|\.[^.]*$|.1|')"  # network+1
	e2e_run "Configure aba.conf" \
		"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain) --machine-network $_mn --gateway $_gw $*"
}

# --- suite_verify_aba_conf ---------------------------------------------------
# Four-grep verification of aba.conf after configuration.
suite_verify_aba_conf() {
	e2e_run "Verify aba.conf: ask=false" "grep ^ask=false aba.conf"
	e2e_run "Verify aba.conf: platform=vmw" "grep ^platform=vmw aba.conf"
	e2e_run "Verify aba.conf: channel" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
	e2e_run "Verify aba.conf: version format" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}' aba.conf"
}

# --- suite_setup_vmware_env -------------------------------------------------
# Copy vmware.conf, set VC_FOLDER, verify GOVC_URL present.
suite_setup_vmware_env() {
	e2e_run "Copy vmware.conf" "cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
	e2e_run "Set VC_FOLDER in vmware.conf" \
		"sed -i 's#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
	e2e_run "Verify vmware.conf" "grep ^GOVC_URL= vmware.conf"
}

# --- suite_setup_ntp ---------------------------------------------------------
# Set NTP servers via aba CLI.
suite_setup_ntp() {
	local ntp_ip="${1:-${NTP_IP:-${NTP_SERVER:-10.0.1.8}}}"
	e2e_run "Set NTP servers" "aba --ntp $ntp_ip ntp.example.com"
}

# --- suite_setup_operator_set [set_name] [operators] -------------------------
# Write operator-set template and apply via aba CLI.
# Defaults to "abatest" set with "kiali-ossm" operators.
suite_setup_operator_set() {
	local set_name="${1:-abatest}"
	local operators="${2:-kiali-ossm}"
	e2e_run "Set operator sets ($set_name)" \
		"echo '$operators' > templates/operator-set-${set_name} && aba --op-sets ${set_name}"
}

# --- suite_reapply_config ----------------------------------------------------
# Re-apply full configuration after reset or interactive test.
# Calls configure, vmware env, NTP, and operator sets.
suite_reapply_config() {
	local ops="${1:-}"
	local _mn _gw
	_mn=$(pool_machine_network)
	_gw="${_mn%%.*}.$(echo "${_mn#*.}" | sed 's|\.[^.]*$|.1|')"
	e2e_run "Re-apply aba.conf" \
		"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain) --machine-network $_mn --gateway $_gw"
	suite_setup_vmware_env
	suite_setup_ntp
	[ -n "$ops" ] && suite_setup_operator_set "abatest" "$ops"
}

# --- suite_cleanup_oc_mirror_cache [--remote] --------------------------------
# Remove oc-mirror caches from /root and /home, plus stale temp dirs in /var/tmp.
# Pass --remote to also clean disN.
suite_cleanup_oc_mirror_cache() {
	e2e_run "Remove oc-mirror caches (conN)" \
		"sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"
	e2e_run "Remove stale oc-mirror temp dirs >1 day old (conN)" \
		"find /var/tmp -maxdepth 1 -type d -name 'container_images_storage*' -mtime +0 2>/dev/null | xargs rm -rf"
	if [ "${1:-}" = "--remote" ]; then
		e2e_run_remote -q "Remove oc-mirror caches (disN)" \
			"sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror 2>/dev/null | xargs sudo rm -rf"
		e2e_run_remote -q "Remove stale oc-mirror temp dirs >1 day old (disN)" \
			"find /var/tmp -maxdepth 1 -type d -name 'container_images_storage*' -mtime +0 2>/dev/null | xargs rm -rf"
	fi
}

# --- suite_create_mirror_workdir ---------------------------------------------
# Create mirror.conf.  data_dir is left at the default (empty = ~) so that
# each user's home directory is used and configs transfer cleanly across users.
suite_create_mirror_workdir() {
	e2e_run "Create mirror.conf" "aba -d mirror mirror.conf"
	e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"
}

# --- suite_point_mirror_to_pool_registry [host] ------------------------------
# Point mirror.conf at the local pool registry on conN.
# Clears reg_ssh_key and reg_ssh_user (registry is local, not remote via SSH).
suite_point_mirror_to_pool_registry() {
	local host="${1:-${CON_HOST:-con${POOL_NUM}.${VM_BASE_DOMAIN}}}"
	e2e_run "Set reg_host to local registry" \
		"sed -i 's/^reg_host=.*/reg_host=${host}/g' mirror/mirror.conf"
	e2e_run "Clear reg_ssh_key (local registry)" \
		"sed -i 's/^reg_ssh_key=.*/reg_ssh_key=/g' mirror/mirror.conf"
	e2e_run "Clear reg_ssh_user (local registry)" \
		"sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/g' mirror/mirror.conf"
	e2e_diag "Show mirror.conf" "grep -E '^\w' mirror/mirror.conf"
}

# --- suite_ensure_pool_registry ----------------------------------------------
# Ensure the pool registry on conN is running and synced for the current
# OCP version. Reads version/channel from aba.conf.
suite_ensure_pool_registry() {
	local host="${1:-${CON_HOST:-con${POOL_NUM}.${VM_BASE_DOMAIN}}}"
	local _ocp_version _ocp_channel
	_ocp_version=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
	_ocp_channel=$(grep '^ocp_channel=' aba.conf | cut -d= -f2 | awk '{print $1}')

	e2e_run "Ensure pool registry running (OCP ${_ocp_channel} ${_ocp_version})" \
		"test/e2e/scripts/setup-pool-registry.sh --channel ${_ocp_channel} --version ${_ocp_version} --host ${host}"
}

# --- suite_generate_pool_reg_pull_secret [host] ------------------------------
# Generate a pull secret JSON for the pool registry (init:p4ssw0rd).
suite_generate_pool_reg_pull_secret() {
	local host="${1:-${CON_HOST:-con${POOL_NUM}.${VM_BASE_DOMAIN}}}"
	e2e_run "Generate pool-registry pull secret" \
		"enc_pw=\$(echo -n 'init:p4ssw0rd' | base64 -w0) && cat > /tmp/pool-reg-pull-secret.json <<EOPS
{
  \"auths\": {
    \"${host}:8443\": {
      \"auth\": \"\$enc_pw\"
    }
  }
}
EOPS"
}

# --- suite_verify_disk_usage [mount] [max_gb] --------------------------------
# Assert disk usage is below threshold after reset/cleanup.
# Default: check / < 50GB (single-partition layout; all data on /).
suite_verify_disk_usage() {
	local mount="${1:-/}"
	local max_gb="${2:-50}"
	e2e_run "Verify $mount disk usage < ${max_gb}GB" \
		"used_gb=\$(df $mount --output=used -BG | tail -1 | tr -d ' G'); echo \"[setup] $mount used: \${used_gb}GB\"; [ \$used_gb -lt $max_gb ]"
}

# --- suite_reset_and_install -------------------------------------------------
# Full reset + install cycle with optional disk check.
suite_reset_and_install() {
	e2e_run "Reset aba to clean state" "./install && aba reset -f"
	suite_cleanup_oc_mirror_cache "$@"
}

# --- suite_bounce_stuck_pods [cluster_dir] [location] ------------------------
# Bounce pods that are not fully ready (ready < total, not Completed).
# Intended as a recovery heuristic when a cluster install stalls due to
# transient scheduling or image-pull issues on known-good infrastructure.
#
# Excludes etcd and kube-apiserver pods (too dangerous to bounce mid-install).
# Logs every pod it deletes so failures can still be diagnosed.
#
# Usage: suite_bounce_stuck_pods "sno" "remote"
suite_bounce_stuck_pods() {
	local cluster_dir="${1:-.}"
	local location="${2:-local}"

	local bounce_cmd='
export KUBECONFIG=~/aba/'"$cluster_dir"'/iso-agent-based/auth/kubeconfig
echo "--- Bouncing stuck pods (not-ready, not Completed) ---"
stuck=$(oc get po -A --no-headers 2>/dev/null | awk '"'"'{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print $1, $2}'"'"')
if [ -z "$stuck" ]; then
	echo "No stuck pods found."
	exit 0
fi
echo "$stuck" | while read ns pod; do
	# Never bounce etcd or kube-apiserver
	case "$pod" in etcd-*|kube-apiserver-*) echo "  SKIP (critical): $ns/$pod"; continue ;; esac
	echo "  DELETE: $ns/$pod"
	oc delete pod "$pod" -n "$ns" --grace-period=0 --force || true
done
echo "--- Bounce complete ---"'

	if [ "$location" = "remote" ]; then
		e2e_run_remote "Bounce stuck pods (recovery)" "$bounce_cmd"
	else
		e2e_run "Bounce stuck pods (recovery)" "$bounce_cmd"
	fi
}

# --- suite_full_setup --------------------------------------------------------
# Complete setup sequence used by most integration suites:
# install aba, reset, configure, verify, vmware env, NTP, operator sets.
#
# Usage: suite_full_setup [--remote] [--ops "operator-list"]
suite_full_setup() {
	local _remote="" _ops="kiali-ossm"
	while [ $# -gt 0 ]; do
		case "$1" in
			--remote) _remote="--remote"; shift ;;
			--ops)    _ops="$2"; shift 2 ;;
			*) shift ;;
		esac
	done

	e2e_install_aba
	e2e_run "Reset aba" "aba reset -f"
	suite_cleanup_oc_mirror_cache $_remote

	suite_configure_aba
	suite_verify_aba_conf
	suite_setup_vmware_env
	suite_setup_ntp
	[ -n "$_ops" ] && suite_setup_operator_set "abatest" "$_ops"
}
