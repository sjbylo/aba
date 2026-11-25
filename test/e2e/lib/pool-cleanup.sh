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
				if cd ~/aba && \$_aba -y -d mirror uninstall --delete-data 2>&1; then
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
							cd ~/aba && \$_aba -y -d mirror uninstall --delete-data 2>&1 || true
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
	_essh "$dis_host" "sudo rm -f /etc/pki/ca-trust/source/anchors/aba-rootCA.pem /etc/pki/ca-trust/source/anchors/rootCA.pem && sudo update-ca-trust" 2>&1

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

# Drop registries.d on some runs only.
# ensure-sigstore-registries.sh does not replace a file that is already there.
# Always deleting would only exercise a fresh write. Never deleting would
# only exercise a leftover. 3/10 is the fresh path. One draw covers conN and
# disN, so a failure log names a single choice. The next aba rewrites the
# namespace files. sync and load rewrite the per-mirror file.
_e2e_maybe_reset_registries_d() {
	local _user _dis

	if [ $(( RANDOM % 10 )) -ge 3 ]; then
		echo "  registries.d: kept (not this run's 3/10 reset)"
		return 0
	fi
	echo "  registries.d: removed (3/10 reset). The next aba writes the current files."
	rm -rf "$HOME/.config/containers/registries.d"
	if [ "$(id -u)" -ne 0 ]; then
		sudo rm -rf /root/.config/containers/registries.d \
			|| echo "  WARNING: could not reset root's registries.d on conN"
	fi
	_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
	for _user in root "${VM_DEFAULT_USER:-steve}" "${DIS_SSH_USER:-steve}"; do
		_essh "${_user}@${_dis}" "rm -rf ~/.config/containers/registries.d" \
			|| echo "  WARNING: could not reset registries.d for $_user on disN"
	done
}

# Drop the live catalog index on some runs, on conN only.
# catalogs/ stays. Those files are the shipped copies. ABA reads them to
# refill .index and never writes them back, so deleting them leaves a hole
# until the next code deploy. run_once start skips a catalog task that
# already succeeded, and the usual wait passes -S, so those task dirs are
# cleared too. The next catalog step copies the shipped index back, or
# downloads one when the shipped file is not there.
_e2e_maybe_reset_catalog_indexes() {
	local _aba _d _n=0

	if [ $(( RANDOM % 10 )) -ge 3 ]; then
		echo "  catalog indexes: kept (not this run's 3/10 reset)"
		return 0
	fi

	_aba="${_ABA_ROOT:-$HOME/aba}"
	echo "  catalog indexes: removed ~/aba/.index (3/10 reset, conN only). catalogs/ stays."
	rm -rf "$_aba/.index"
	shopt -s nullglob
	for _d in "$HOME/.aba/runner"/catalog:*; do
		rm -rf "$_d"
		_n=$(( _n + 1 ))
	done
	shopt -u nullglob
	echo "  catalog indexes: cleared $_n catalog run_once task(s)"
}

# Drop three non-critical RPMs on some runs, on conN and disN.
# disN reaches the RHEL repos through the dnf proxy. ens256 stays down.
# install -q calls install-rpms.sh on the next aba and puts these back.
# podman stays: removing it can stop a registry that is already running.
# python3, make, jq, and which stay: the path that reinstalls packages
# needs them, or rpm -q does not see the real python package.
_e2e_maybe_reset_rpms() {
	local -a _safe=(dialog httpd-tools skopeo bash-completion diffutils acl)
	local -a _pick=()
	local _i _p _user _dis _rm

	if [ $(( RANDOM % 10 )) -ge 3 ]; then
		echo "  rpms: kept (not this run's 3/10 reset)"
		return 0
	fi

	while [ ${#_pick[@]} -lt 3 ] && [ ${#_safe[@]} -gt 0 ]; do
		_i=$(( RANDOM % ${#_safe[@]} ))
		_pick+=("${_safe[_i]}")
		unset "_safe[_i]"
		_safe=("${_safe[@]}")
	done

	echo "  rpms: removing ${_pick[*]} (3/10 reset, conN and disN). The next aba installs them again."
	for _p in "${_pick[@]}"; do
		if rpm -q --quiet "$_p"; then
			sudo dnf remove -y --noautoremove "$_p" >/dev/null \
				|| echo "  WARNING: could not remove $_p on conN"
		else
			echo "  rpms: $_p was not installed on conN"
		fi
	done
	_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
	_rm=""
	for _p in "${_pick[@]}"; do
		_rm="${_rm:+$_rm }$_p"
	done
	for _user in root "${VM_DEFAULT_USER:-steve}" "${DIS_SSH_USER:-steve}"; do
		_essh "${_user}@${_dis}" "for _p in $_rm; do if rpm -q --quiet \"\$_p\"; then sudo dnf remove -y --noautoremove \"\$_p\" >/dev/null || echo \"  WARNING: could not remove \$_p\"; else echo \"  rpms: \$_p was not installed\"; fi; done" \
			|| echo "  WARNING: could not reset rpms for $_user on disN"
	done
}

# Derived container auth. The pull secret and ~/.aba/mirror creds stay.
# ~/.docker/auth.yaml is not a file aba writes.
# A dummy registry login is planted after the optional delete. create-containers-auth
# merges into a file that is already there, so that login must still be present
# when the suite ends. A missing file is copied from the pull secret and would
# drop the dummy, which is why the plant happens after the delete.
_E2E_AUTH_DUMMY_HOST=e2e-chaos.invalid
_E2E_AUTH_DUMMY_AUTH=ZTJlLWNoYW9zOnVudXNlZA==
_E2E_AUTH_DUMMY_MARKER=/tmp/e2e-auth-dummy

_e2e_rm_container_auth() {
	rm -f "$HOME/.docker/config.json" \
		"$HOME/.containers/auth.json" \
		"$HOME/.config/containers/auth.json"
	if [[ "${XDG_RUNTIME_DIR:-}" == /* ]]; then
		rm -f "$XDG_RUNTIME_DIR/containers/auth.json"
	fi
}

# $1 is the auth file. Creates it when missing. Leaves every other login.
_e2e_plant_auth_file() {
	local dest="$1" dir tmp
	dir=$(dirname "$dest")
	mkdir -p "$dir" || return 1
	if [ ! -s "$dest" ]; then
		printf '%s\n' "{\"auths\":{\"${_E2E_AUTH_DUMMY_HOST}\":{\"auth\":\"${_E2E_AUTH_DUMMY_AUTH}\"}}}" > "$dest"
		chmod 600 "$dest"
		return 0
	fi
	tmp=$(mktemp "$dir/.e2e-auth.XXXXXX")
	if ! jq --arg h "$_E2E_AUTH_DUMMY_HOST" --arg a "$_E2E_AUTH_DUMMY_AUTH" \
		'.auths //= {} | .auths[$h].auth = $a' "$dest" > "$tmp"; then
		rm -f "$tmp"
		echo "  WARNING: could not plant dummy auth in $dest"
		return 1
	fi
	mv "$tmp" "$dest"
	chmod 600 "$dest"
}

# Only the two files aba merges. A new ~/.config/containers/auth.json would
# hide ~/.docker/config.json from podman.
_e2e_plant_auth_home() {
	_e2e_plant_auth_file "$HOME/.docker/config.json" || return 1
	_e2e_plant_auth_file "$HOME/.containers/auth.json" || return 1
}

_e2e_maybe_reset_container_auth() {
	local _user _dis _rm

	if [ $(( RANDOM % 10 )) -ge 3 ]; then
		echo "  container auth: kept (not this run's 3/10 reset)"
	else
		echo "  container auth: removed (3/10 reset). The next save/sync/load writes it again."
		_e2e_rm_container_auth
		if [ "$(id -u)" -ne 0 ]; then
			sudo bash -c 'rm -f /root/.docker/config.json /root/.containers/auth.json /root/.config/containers/auth.json; if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ "${XDG_RUNTIME_DIR#/}" != "$XDG_RUNTIME_DIR" ]; then rm -f "$XDG_RUNTIME_DIR/containers/auth.json"; fi' \
				|| echo "  WARNING: could not reset root container auth on conN"
		fi
		_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
		_rm='rm -f ~/.docker/config.json ~/.containers/auth.json ~/.config/containers/auth.json; if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ "${XDG_RUNTIME_DIR#/}" != "$XDG_RUNTIME_DIR" ]; then rm -f "$XDG_RUNTIME_DIR/containers/auth.json"; fi'
		for _user in root "${VM_DEFAULT_USER:-steve}" "${DIS_SSH_USER:-steve}"; do
			_essh "${_user}@${_dis}" "$_rm" \
				|| echo "  WARNING: could not reset container auth for $_user on disN"
		done
	fi

	echo "  container auth: planted ${_E2E_AUTH_DUMMY_HOST} (must still be there at suite end)"
	: > "$_E2E_AUTH_DUMMY_MARKER"
	_e2e_plant_auth_home || echo "  WARNING: dummy auth plant failed for $USER on conN"
	if [ "$(id -u)" -ne 0 ]; then
		sudo env HOME=/root \
			_E2E_AUTH_DUMMY_HOST="$_E2E_AUTH_DUMMY_HOST" \
			_E2E_AUTH_DUMMY_AUTH="$_E2E_AUTH_DUMMY_AUTH" \
			bash -s <<'END_PLANT' || echo "  WARNING: dummy auth plant failed for root on conN"
_e2e_plant_auth_file() {
	local dest="$1" dir tmp
	dir=$(dirname "$dest")
	mkdir -p "$dir" || return 1
	if [ ! -s "$dest" ]; then
		printf '%s\n' "{\"auths\":{\"${_E2E_AUTH_DUMMY_HOST}\":{\"auth\":\"${_E2E_AUTH_DUMMY_AUTH}\"}}}" > "$dest"
		chmod 600 "$dest"
		return 0
	fi
	tmp=$(mktemp "$dir/.e2e-auth.XXXXXX")
	if ! jq --arg h "$_E2E_AUTH_DUMMY_HOST" --arg a "$_E2E_AUTH_DUMMY_AUTH" \
		'.auths //= {} | .auths[$h].auth = $a' "$dest" > "$tmp"; then
		rm -f "$tmp"
		echo "  WARNING: could not plant dummy auth in $dest"
		return 1
	fi
	mv "$tmp" "$dest"
	chmod 600 "$dest"
}
_e2e_plant_auth_file /root/.docker/config.json && \
	_e2e_plant_auth_file /root/.containers/auth.json
END_PLANT
	fi
	_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
	for _user in root "${VM_DEFAULT_USER:-steve}" "${DIS_SSH_USER:-steve}"; do
		_essh "${_user}@${_dis}" \
			"_E2E_AUTH_DUMMY_HOST='${_E2E_AUTH_DUMMY_HOST}' _E2E_AUTH_DUMMY_AUTH='${_E2E_AUTH_DUMMY_AUTH}' bash -s" <<'END_PLANT' \
			|| echo "  WARNING: dummy auth plant failed for $_user on disN"
_e2e_plant_auth_file() {
	local dest="$1" dir tmp
	dir=$(dirname "$dest")
	mkdir -p "$dir" || return 1
	if [ ! -s "$dest" ]; then
		printf '%s\n' "{\"auths\":{\"${_E2E_AUTH_DUMMY_HOST}\":{\"auth\":\"${_E2E_AUTH_DUMMY_AUTH}\"}}}" > "$dest"
		chmod 600 "$dest"
		return 0
	fi
	tmp=$(mktemp "$dir/.e2e-auth.XXXXXX")
	if ! jq --arg h "$_E2E_AUTH_DUMMY_HOST" --arg a "$_E2E_AUTH_DUMMY_AUTH" \
		'.auths //= {} | .auths[$h].auth = $a' "$dest" > "$tmp"; then
		rm -f "$tmp"
		echo "  WARNING: could not plant dummy auth in $dest"
		return 1
	fi
	mv "$tmp" "$dest"
	chmod 600 "$dest"
}
_e2e_plant_auth_file "$HOME/.docker/config.json" && \
	_e2e_plant_auth_file "$HOME/.containers/auth.json"
END_PLANT
		echo "${_user}@${_dis}" >> "$_E2E_AUTH_DUMMY_MARKER"
	done
}

# Fail when a planted dummy login was removed. Merge keeps other registries.
_e2e_auth_dummy_present() {
	local dest="$1"
	[ -s "$dest" ] || return 1
	jq -e --arg h "$_E2E_AUTH_DUMMY_HOST" --arg a "$_E2E_AUTH_DUMMY_AUTH" \
		'.auths[$h].auth == $a' "$dest" >/dev/null
}

_e2e_assert_auth_dummy() {
	local _target _miss=0 _f
	[ -s "$_E2E_AUTH_DUMMY_MARKER" ] || return 0

	for _f in "$HOME/.docker/config.json" "$HOME/.containers/auth.json"; do
		if ! _e2e_auth_dummy_present "$_f"; then
			echo "  container auth: dummy missing from $_f"
			_miss=1
		fi
	done
	if [ "$(id -u)" -ne 0 ]; then
		for _f in /root/.docker/config.json /root/.containers/auth.json; do
			if ! sudo jq -e --arg h "$_E2E_AUTH_DUMMY_HOST" --arg a "$_E2E_AUTH_DUMMY_AUTH" \
				'.auths[$h].auth == $a' "$_f" >/dev/null; then
				echo "  container auth: dummy missing from $_f"
				_miss=1
			fi
		done
	fi
	while IFS= read -r _target; do
		[ -n "$_target" ] || continue
		if ! _essh "$_target" "$_E2E_AUTH_DUMMY_HOST='$_E2E_AUTH_DUMMY_HOST' _E2E_AUTH_DUMMY_AUTH='$_E2E_AUTH_DUMMY_AUTH'; for f in ~/.docker/config.json ~/.containers/auth.json; do jq -e --arg h \"\$_E2E_AUTH_DUMMY_HOST\" --arg a \"\$_E2E_AUTH_DUMMY_AUTH\" '.auths[\$h].auth == \$a' \"\$f\" >/dev/null || exit 1; done"; then
			echo "  container auth: dummy missing for $_target"
			_miss=1
		fi
	done < "$_E2E_AUTH_DUMMY_MARKER"
	[ "$_miss" -eq 0 ]
}
