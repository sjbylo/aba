#!/usr/bin/env bash
# =============================================================================
# E2E Framework -- Pool Cleanup Helpers
# =============================================================================
# Extracted from runner.sh. Functions that clean disN state and process
# leftover cleanup files from crashed/abandoned suite runs.
#
# Depends on:
#   lib/remote.sh        -- _essh
#   lib/constants.sh     -- E2E_LOG_DIR
#   runner.sh globals    -- DIS_SSH_USER, DIS_VM, VM_BASE_DOMAIN, VC_FOLDER,
#                           VM_DATASTORE, VM_DEFAULT_USER, _E2E_STALE_FW_PORTS,
#                           _E2E_ABA_INTERNAL_DIRS, POOL_NUM, _RUNNER_DIR
# =============================================================================

# --- Clean disN via ABA commands (replaces snapshot revert) -------------------
# Instead of reverting disN to a VMware snapshot, use ABA's own cleanup to
# return disN to a clean state.  This exercises aba uninstall/reset code paths
# and is faster (no VM reboot + SSH wait).
#
# Covers: registry uninstall, filesystem cleanup, podman prune, cache removal,
#         firewalld baseline restore, VC_FOLDER/GOVC_DATASTORE patch.
#
# Prerequisite: _pre_suite_cleanup has already run (deletes clusters/mirrors
#               via .cleanup/.mirror-cleanup files).

_cleanup_dis() {
	local dis_host="${DIS_SSH_USER}@${DIS_VM}.${VM_BASE_DOMAIN}"
	echo ""
	echo "  Cleaning disN ($dis_host) via ABA commands ..."

	# Three mirror install/uninstall cases:
	#   1. conN → conN (local):  _cleanup_con_registry() already handled this.
	#   2. conN → disN (remote): _cleanup_con_registry() already handled this
	#      (aba uninstall from conN SSHes to disN to tear down Quay).
	#   3. disN → disN (local):  Must uninstall FROM disN -- handled below.
	local _dis_fqdn="${DIS_VM}.${VM_BASE_DOMAIN}"
	local _default_user="${VM_DEFAULT_USER:-steve}"

	# Case 3: uninstall any mirror installed locally on disN.
	# Only trigger when a registry was actually installed (marker file exists).
	# ~/aba/mirror/ always exists on disN after deploy (it's part of the source tree).
	echo "  Checking for locally-installed registries on disN ..."
	local _uninstall_failed=""
	local _try_user
	for _try_user in root "$_default_user"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_essh "$_uhost" "
			_aba=\$HOME/.e2e-harness/bin/aba
			if [ -f ~/aba/mirror/.available ] || [ -f ~/aba/mirror/.installed ] || [ -f ~/aba/mirror/.unavailable ]; then
				echo '  [cleanup] Found mirror dir for $_try_user on disN -- uninstalling locally'
				if cd ~/aba && \$_aba -y -d mirror uninstall 2>&1; then
					echo '  [cleanup] uninstall OK'
				else
					echo '  [cleanup] uninstall failed -- trying aba unregister (external registry)'
					cd ~/aba && \$_aba -y -d mirror unregister 2>&1 || exit 1
				fi
			fi
		" 2>&1 || {
			echo "  ERROR: aba uninstall/unregister as $_try_user on disN failed (rc=$?)"
			_uninstall_failed=1
		}
	done
	if [ -n "$_uninstall_failed" ]; then
		echo "  FATAL: aba uninstall on disN failed. Cannot proceed with dirty host."
		return 1
	fi

	# Case 2 fallback: remotely-installed registries whose conN state was lost
	# (e.g. snapshot revert wiped conN markers). ABA writes INSTALLED_BY_ABA.md
	# inside each data dir at install time -- scan disN for these breadcrumbs
	# and run mirror-registry uninstall for each one found.
	echo "  Scanning disN for orphaned registries (INSTALLED_BY_ABA.md) ..."
	for _try_user in root "$_default_user"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		local _orphan_dirs
		_orphan_dirs=$(_essh "$_uhost" "find ~/e2e-mirror-* ~/${_E2E_ABA_INTERNAL_DIRS// / ~/} -maxdepth 2 -name INSTALLED_BY_ABA.md -type f" || true)
		if [ -n "$_orphan_dirs" ]; then
			echo "  [cleanup] Found orphaned registry breadcrumbs for $_try_user on disN:"
			echo "$_orphan_dirs" | while read -r _md_path; do
				local _data_dir
				_data_dir=$(dirname "$_md_path")
				echo "    $_data_dir"
				# Attempt proper uninstall using mirror-registry if available
				_essh "$_uhost" "
					if [ -x '$_data_dir/../mirror-registry' ] || command -v mirror-registry >/dev/null; then
						_mr=\$(command -v mirror-registry || echo '$_data_dir/../mirror-registry')
						echo '  [cleanup] Running mirror-registry uninstall for $_data_dir'
						\$_mr uninstall -v --autoApprove \
							--quayRoot '$_data_dir/quay-install' \
							--quayStorage '$_data_dir/quay-install/quay-storage' \
							--sqliteStorage '$_data_dir/quay-install/sqlite-storage' 2>&1 || true
					else
						echo '  [cleanup] mirror-registry not found -- using aba uninstall'
						_aba=\$HOME/.e2e-harness/bin/aba
						if [ -x \"\$_aba\" ] && [ -f ~/aba/mirror/.available ]; then
							cd ~/aba && \$_aba -y -d mirror uninstall 2>&1 || true
						fi
					fi
				" 2>&1
			done
		fi
	done

	# Post-uninstall assertion: verify no stale podman state on disN.
	# Catches the exact failure mode where mirror-registry uninstall silently
	# skips cleanup, leaving redis_pass secrets and systemd units behind.
	local _podman_stale=""
	for _try_user in root "$_default_user"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_essh "$_uhost" "podman secret ls --format '{{.Name}}' | grep -q redis_pass" \
			&& _podman_stale+="  $_try_user: redis_pass podman secret exists"$'\n'
		_essh "$_uhost" "podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres'" \
			&& _podman_stale+="  $_try_user: quay containers still present"$'\n'
		_essh "$_uhost" "systemctl --user list-units 'quay-*' --no-legend | grep -v 'not-found' | grep -q ." \
			&& _podman_stale+="  $_try_user: quay systemd user units still active"$'\n'
	done
	if [ -n "$_podman_stale" ]; then
		echo "  FATAL: Stale podman state found on disN after aba uninstall:"
		echo "$_podman_stale"
		echo "  This will cause WRONGPASS / PermissionError on the next install."
		echo "  Investigate why 'aba uninstall' did not clean up podman state."
		echo "  Manual recovery: test/e2e/tools/force-clean-vm.sh <user@host>"
		return 1
	fi

	# 1. Clean disN filesystem for all users (aba code, CLI tools, caches, mirror data)
	echo "  Cleaning disN filesystem (non-mirror artifacts) ..."
	for _try_user in root "$_default_user"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_essh "$_uhost" "rm -rf ~/aba/* ~/aba/.??* ~/tmp/* ~/.aba/mirror ~/.cache/agent ~/.oc-mirror && rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane}" 2>&1
		# Registry/test data dirs may contain files owned by container-mapped UIDs
		# (rootless podman UID remapping), so sudo is needed for cleanup.
		# Uses globs (e2e-mirror-*, e2e-test-*) + ABA-internal dirs.
		_essh "$_uhost" "sudo rm -rf ~/e2e-mirror-* ~/e2e-test-*" 2>&1
		for _mdir in $_E2E_ABA_INTERNAL_DIRS; do
			_essh "$_uhost" "sudo rm -rf ~/$_mdir" 2>&1
		done
	done
	# disN must never have a Red Hat pull secret (true air-gap invariant)
	for _try_user in root "$_default_user"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_essh "$_uhost" "rm -f ~/.pull-secret.json" 2>&1
	done

	# Remove stale CA trust anchors from previous registry installs
	_essh "$dis_host" "sudo rm -f /etc/pki/ca-trust/source/anchors/rootCA.pem && sudo update-ca-trust" 2>&1

	# 2. Restore baseline system state (firewalld on, as created by setup-infra)
	_essh "$dis_host" "sudo systemctl enable firewalld; sudo systemctl start firewalld" 2>&1

	# 3. Remove stale firewall ports from permanent config (survive restart)
	echo "  Resetting firewall ports on disN ..."
	for _port in $_E2E_STALE_FW_PORTS; do
		_essh "$dis_host" "sudo firewall-cmd --query-port=$_port --permanent >/dev/null && sudo firewall-cmd --remove-port=$_port --permanent" 2>&1
	done
	_essh "$dis_host" "sudo firewall-cmd --reload" 2>&1

	# Verify no stale ports remain on disN
	local _dis_fw_ports
	_dis_fw_ports=$(_essh "$dis_host" "sudo firewall-cmd --list-ports")
	if [ -n "$_dis_fw_ports" ]; then
		echo "  WARNING: disN still has firewall ports after reset: $_dis_fw_ports"
	else
		echo "  disN firewall verified: no test ports"
	fi

	# 4. Ensure VC_FOLDER / GOVC_DATASTORE are correct on disN
	if [ -n "${VC_FOLDER:-}" ]; then
		_essh "$dis_host" "sed -i \"s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER}#g\" ~/.vmware.conf" \
			&& echo "  Set VC_FOLDER=${VC_FOLDER} on $dis_host" \
			|| echo "  WARNING: could not set VC_FOLDER on $dis_host"
	fi
	if [ -n "${VM_DATASTORE:-}" ]; then
		_essh "$dis_host" "sed -i \"s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g\" ~/.vmware.conf" \
			&& echo "  Set GOVC_DATASTORE=${VM_DATASTORE} on $dis_host" \
			|| echo "  WARNING: could not set GOVC_DATASTORE on $dis_host"
	fi

	# 5. Verify port 8443 is free (registry fully uninstalled).
	#    Cross-user scenarios (steve->root) are handled by snapshot revert in run.sh.
	#    This catches same-user partial installs where aba uninstall couldn't fully
	#    tear down orphaned containers.
	if _essh "$dis_host" "ss -tlnp | grep -q ':8443 '"; then
		echo "  WARNING: port 8443 still occupied after cleanup -- retrying aba uninstall"
		for _try_user in root "$_default_user"; do
			local _uhost="${_try_user}@${_dis_fqdn}"
			# Crash-recovery fallback: aba uninstall already ran but couldn't stop
			# orphaned containers (partial install, no config left).  podman stop
			# is the only option when aba state is gone.
			_essh "$_uhost" "
				cd /tmp
				if podman ps -q | grep -q .; then
					echo '  [cleanup] Stopping $_try_user containers on disN'
					podman stop -a -t 5 || true
					podman rm -af || true
				fi
			" 2>&1 || true
		done
		# Final check
		if _essh "$dis_host" "ss -tlnp | grep -q ':8443 '"; then
			echo "  FATAL: port 8443 STILL occupied on disN after all cleanup attempts"
			return 1
		fi
		echo "  disN port 8443 freed after retry"
	fi

	echo "  disN cleanup verified: clean state"
	echo "  disN cleanup complete."
}
