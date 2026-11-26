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
# --channel is before --version. cli-validation also runs the reverse
# order on a fresh aba.conf, because --version starts the catalog jobs.
suite_configure_aba() {
	e2e_run "Configure aba.conf" \
		"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain) --machine-network $(pool_machine_network) --gateway $(pool_gateway) $*"
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
	e2e_run "Re-apply aba.conf" \
		"aba --noask --platform vmw --channel $TEST_CHANNEL --version $OCP_VERSION --base-domain $(pool_domain) --machine-network $(pool_machine_network) --gateway $(pool_gateway)"
	suite_setup_vmware_env
	suite_setup_ntp
	[ -n "$ops" ] && suite_setup_operator_set "abatest" "$ops"
}

# --- suite_cleanup_oc_mirror_cache [--remote] --------------------------------
# Remove oc-mirror caches from /root and /home, plus stale temp dirs in /var/tmp.
# Pass --remote to also clean disN.
suite_cleanup_oc_mirror_cache() {
	e2e_run "Remove oc-mirror caches (conN)" \
		"sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror | xargs sudo rm -rf"
	e2e_run "Remove stale oc-mirror temp dirs >1 day old (conN)" \
		"find /var/tmp -maxdepth 1 -type d -name 'container_images_storage*' -mtime +0 | xargs rm -rf"
	if [ "${1:-}" = "--remote" ]; then
		e2e_run_remote -q "Remove oc-mirror caches (disN)" \
			"sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror | xargs sudo rm -rf"
		e2e_run_remote -q "Remove stale oc-mirror temp dirs >1 day old (disN)" \
			"find /var/tmp -maxdepth 1 -type d -name 'container_images_storage*' -mtime +0 | xargs rm -rf"
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
    \"${host}:${POOL_REG_PORT}\": {
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
stuck=$(oc get po -A --no-headers | awk '"'"'{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print $1, $2}'"'"')
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

# --- suite_clone_cluster_workdir <src> <dst> [image_source] --------------------
# Second ABA working directory for an already-managed live cluster.
# Shares ~/.aba/clusters/<fqdn>/ via symlink — does NOT run aba import --force
# (which must refuse healthy already-managed clusters and must not rewrite
# platform in state.sh).
suite_clone_cluster_workdir() {
	local src="${1:?}"
	local dst="${2:?}"
	local isrc="${3:-}"
	local sd

	[ -d "$src" ] || { echo "FAIL: source cluster dir missing: $src" >&2; return 1; }
	[ -L "$src/clusterstate" ] || { echo "FAIL: $src/clusterstate is not a symlink" >&2; return 1; }
	sd=$(readlink -f "$src/clusterstate") || return 1
	[ -d "$sd" ] || { echo "FAIL: shared state missing: $sd" >&2; return 1; }

	rm -rf "$dst"
	mkdir -p "$dst"
	cp -a "$src/cluster.conf" "$dst/"
	if [ -n "$isrc" ]; then
		sed -i "s|^image_source=.*|image_source=$isrc|" "$dst/cluster.conf"
	fi
	ln -fs ../templates/Makefile.cluster "$dst/Makefile"
	( cd "$dst" && make -s init )
	ln -sfn "$sd" "$dst/clusterstate"
	mkdir -p "$dst/iso-agent-based/auth"
	if [ -f "$src/iso-agent-based/auth/kubeconfig" ]; then
		cp -p "$src/iso-agent-based/auth/kubeconfig" "$dst/iso-agent-based/auth/kubeconfig"
	elif [ -f "$sd/kubeconfig" ]; then
		cp -p "$sd/kubeconfig" "$dst/iso-agent-based/auth/kubeconfig"
	fi
	if [ -f "$src/iso-agent-based/rendezvousIP" ]; then
		cp -p "$src/iso-agent-based/rendezvousIP" "$dst/iso-agent-based/rendezvousIP"
	fi
	touch "$dst/.install-complete"
	echo "Cloned working dir $src -> $dst (shared state $sd)"
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

# Stop, start, kill, shutdown --wait, and startup on a cluster that is already Ready.
# on_pat/off_pat match aba ls (poweredOn/poweredOff, or running/shut-off).
# count is how many VMs that cluster has. msgs=1 checks the vSphere screen lines.
# location is local or remote (disN, commands run in ~/aba).
e2e_cluster_vm_lifecycle() {
	local dir="$1" on_pat="$2" off_pat="$3" count="$4" msgs="${5:-}" loc="${6:-local}"
	local safe step poll waitready
	safe=$(printf '%s' "$dir" | tr -c 'A-Za-z0-9' _)
	if [ "$loc" = "remote" ]; then
		step() { e2e_run_remote "$1" "cd ~/aba && $2"; }
		poll() { e2e_poll_remote "$1" "$2" "$3" "cd ~/aba && $4"; }
		waitready() { e2e_wait_cluster_ready "$dir" remote "${1:-3300}"; }
	else
		step() { e2e_run "$1" "$2"; }
		poll() { e2e_poll "$1" "$2" "$3" "$4"; }
		waitready() { e2e_wait_cluster_ready "$dir" local "${1:-3300}"; }
	fi
	step "$dir: $count VMs are up" \
		"[ \$(aba --dir $dir ls | grep -c -i '$on_pat') -eq $count ]"
	if [ -n "$msgs" ]; then
		step "$dir: stop" \
			"mkdir -p \$HOME/tmp && aba --dir $dir stop --wait > \$HOME/tmp/e2e-stop-${safe}.out 2>&1; _rc=\$?; cat \$HOME/tmp/e2e-stop-${safe}.out; exit \$_rc"
		step "$dir: guest shutdown was requested" \
			"grep -q 'guest shutdown requested' \$HOME/tmp/e2e-stop-${safe}.out"
	else
		step "$dir: stop" "aba --dir $dir stop --wait"
	fi
	step "$dir: $count VMs are off after stop" \
		"[ \$(aba --dir $dir ls | grep -c -i '$off_pat') -eq $count ]"
	step "$dir: start" "aba --dir $dir start"
	step "$dir: $count VMs are up after start" \
		"[ \$(aba --dir $dir ls | grep -c -i '$on_pat') -eq $count ]"
	if [ -n "$msgs" ]; then
		step "$dir: kill" \
			"mkdir -p \$HOME/tmp && aba --dir $dir kill > \$HOME/tmp/e2e-kill-${safe}.out 2>&1; _rc=\$?; cat \$HOME/tmp/e2e-kill-${safe}.out; exit \$_rc"
		step "$dir: kill powered the VMs off" \
			"grep -q 'powered off' \$HOME/tmp/e2e-kill-${safe}.out"
	else
		step "$dir: kill" "aba --dir $dir kill"
	fi
	step "$dir: $count VMs are off after kill" \
		"[ \$(aba --dir $dir ls | grep -c -i '$off_pat') -eq $count ]"
	step "$dir: start after kill" "aba --dir $dir start"
	poll 600 15 "$dir: SSH after kill" "aba --dir $dir ssh --cmd hostname"
	waitready 4200
	if [ -n "$msgs" ]; then
		step "$dir: shutdown" \
			"mkdir -p \$HOME/tmp && aba --dir $dir shutdown -y --wait > \$HOME/tmp/e2e-sd-${safe}.out 2>&1; _rc=\$?; cat \$HOME/tmp/e2e-sd-${safe}.out; exit \$_rc"
		step "$dir: shutdown reports every node powered off" \
			"grep -q 'All nodes powered off' \$HOME/tmp/e2e-sd-${safe}.out"
	else
		step "$dir: shutdown" "aba --dir $dir shutdown -y --wait"
	fi
	step "$dir: $count VMs are off after shutdown" \
		"[ \$(aba --dir $dir ls | grep -c -i '$off_pat') -eq $count ]"
	step "$dir: startup" "aba --dir $dir startup"
	step "$dir: $count VMs are up after startup" \
		"[ \$(aba --dir $dir ls | grep -c -i '$on_pat') -eq $count ]"
	poll 600 15 "$dir: nodes Ready after startup" \
		"aba --dir $dir run --cmd 'oc get nodes --no-headers' | grep -qw Ready && ! aba --dir $dir run --cmd 'oc get nodes --no-headers' | grep -qw NotReady"
	waitready 3300
}
