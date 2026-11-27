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
#   lib/vc-folder.sh     -- _e2e_vc_folder_allowed, _e2e_rewrite_vc_file
#   runner.sh globals    -- DIS_SSH_USER, DIS_VM, VM_BASE_DOMAIN, VC_FOLDER,
#                           VM_DATASTORE, VM_DEFAULT_USER, _E2E_STALE_FW_PORTS,
#                           _E2E_ABA_INTERNAL_DIRS, POOL_NUM, _RUNNER_DIR
# =============================================================================

_E2E_LIB_DIR_CLEAN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F _e2e_vc_folder_allowed >/dev/null 2>&1; then
	source "$_E2E_LIB_DIR_CLEAN/vc-folder.sh"
fi

# Point conN and disN at this pool's vCenter folder, then refuse to start
# when one of this pool's e2e VMs is already sitting in the production folder.
# Another pool's VMs there do not block this pool.
# Runs on a kept disN tree as well as a wiped one. The folder is pool
# identity, not leftover state.
_e2e_enforce_pool_folder() {
	local folder="${VC_FOLDER:-}"
	local ds="${VM_DATASTORE:-}"
	local dis_host hits govc_bin

	if ! _e2e_vc_folder_allowed "$folder"; then
		echo "  FATAL: VC_FOLDER '${folder}' is not /Datacenter/vm/aba-e2e/poolN." >&2
		echo "  abatesting is the production folder and must not be used by e2e." >&2
		return 1
	fi

	echo "  Enforcing VC_FOLDER=$folder on conN and disN"
	_e2e_rewrite_vc_file "$HOME/.vmware.conf" "$folder" "$ds" || return 1
	_e2e_rewrite_vc_file "$HOME/aba/vmware.conf" "$folder" "$ds" || return 1
	if sudo test -e /root/.vmware.conf; then
		local _root_copy
		_root_copy=$(mktemp)
		sudo cp /root/.vmware.conf "$_root_copy" || return 1
		sudo chown "$USER" "$_root_copy" || return 1
		_e2e_rewrite_vc_file "$_root_copy" "$folder" "$ds" || { rm -f "$_root_copy"; return 1; }
		sudo cp "$_root_copy" /root/.vmware.conf || { rm -f "$_root_copy"; return 1; }
		sudo chmod 600 /root/.vmware.conf || { rm -f "$_root_copy"; return 1; }
		rm -f "$_root_copy"
	fi

	dis_host="${DIS_SSH_USER:-steve}@${DIS_VM}.${VM_BASE_DOMAIN}"
	_essh "$dis_host" bash -s -- "$folder" "$ds" <<'EOF' || return 1
set -e
folder="$1"
ds="$2"
rewrite() {
	file="$1"
	as_root="${2:-}"
	run() { if [ -n "$as_root" ]; then sudo "$@"; else "$@"; fi; }
	run test -e "$file" || return 0
	run test -s "$file" || return 0
	run grep -q 'VC_FOLDER=' "$file" || return 0
	run sed -i -E "s#^[#[:space:]]*(export[[:space:]]+)?VC_FOLDER=.*#VC_FOLDER=${folder}#" "$file"
	if [ -n "$ds" ]; then
		run sed -i -E "s#^[#[:space:]]*(export[[:space:]]+)?GOVC_DATASTORE=.*#GOVC_DATASTORE=${ds}#" "$file"
	fi
	if run grep -q abatesting "$file"; then
		echo "FATAL: $file still contains abatesting" >&2
		return 1
	fi
	run grep -qx "VC_FOLDER=${folder}" "$file"
}
rewrite "$HOME/.vmware.conf"
rewrite "$HOME/aba/vmware.conf"
rewrite /root/.vmware.conf root
EOF

	govc_bin="${_FRAMEWORK_BIN:-}/govc"
	[ -x "$govc_bin" ] || govc_bin=$(command -v govc || true)
	if [ ! -x "$govc_bin" ]; then
		echo "  FATAL: govc not found. Cannot prove abatesting has no e2e VMs." >&2
		return 1
	fi
	if ! hits=$("$govc_bin" find /Datacenter/vm/abatesting -type m 2>&1); then
		if echo "$hits" | grep -q 'not found'; then
			return 0
		fi
		echo "  FATAL: cannot list /Datacenter/vm/abatesting ($hits)" >&2
		return 1
	fi
	if [ -z "${POOL_NUM:-}" ]; then
		echo "  FATAL: POOL_NUM is unset. Cannot tell which abatesting VMs belong to this pool." >&2
		return 1
	fi
	local line mine="" other=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
			*/e2e-*) ;;
			*) continue ;;
		esac
		if _e2e_abatesting_path_is_pool "$line" "$POOL_NUM"; then
			mine="${mine}${line}"$'\n'
		else
			other="${other}${line}"$'\n'
		fi
	done <<EOF
$hits
EOF
	if [ -n "$mine" ]; then
		echo "  FATAL: this pool's e2e VMs exist under /Datacenter/vm/abatesting." >&2
		echo "  E2E must not use that folder. Refusing to start." >&2
		printf '%s' "$mine" | sed 's/^/    /' >&2
		echo "  These VMs are not in the pool folder, so aba delete from a corrected vmware.conf will not see them." >&2
		return 1
	fi
	if [ -n "$other" ]; then
		echo "  Another pool has e2e VMs under abatesting. This pool is not blocked."
		printf '%s' "$other" | sed 's/^/    /'
	fi
}

# Run one command as a disN user. root and steve accept the shared key.
# testy only accepts testy_rsa, which lives on the VM, so steve uses sudo.
# A missing testy account returns 1 and does not run the command.
_e2e_dis_as() {
	local _user="$1"
	shift
	local _fqdn="${DIS_VM}.${VM_BASE_DOMAIN}"
	local _def="${VM_DEFAULT_USER:-steve}"
	local _cmd="$*"
	if [ "$_user" = "testy" ]; then
		_essh "${_def}@${_fqdn}" "id testy >/dev/null 2>&1 || exit 1; sudo -u testy -H env XDG_RUNTIME_DIR=/run/user/\$(id -u testy) bash -c $(printf '%q' "$_cmd")"
		return
	fi
	_essh "${_user}@${_fqdn}" "$_cmd"
}

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
	local _default_user="${VM_DEFAULT_USER:-steve}"
	local -a _dis_users=(root steve testy)
	if [ "$_default_user" != root ] && [ "$_default_user" != steve ] && [ "$_default_user" != testy ]; then
		_dis_users+=("$_default_user")
	fi

	# One draw for the whole disN tree. A keep leaves registries and files so a
	# later suite can trip over them. A delete is the fresh path. The pool
	# registry container and $POOL_REG_DIR are not part of this wipe.
	if [ $(( RANDOM % 10 )) -ge 3 ]; then
		_E2E_DIS_TREE_KEPT=1
		echo "  disN tree: kept (not this run's 3/10 reset)"
		return 0
	fi
	_E2E_DIS_TREE_KEPT=
	echo ""
	echo "  Cleaning disN ($dis_host) via ABA commands ..."
	echo "  disN tree: removed (3/10 reset). Pool registry is left in place."

	# Three mirror install/uninstall cases:
	#   1. conN → conN (local):  _cleanup_con_registry() already handled this.
	#   2. conN → disN (remote): _cleanup_con_registry() already handled this
	#      (aba uninstall from conN SSHes to disN to tear down Quay).
	#   3. disN → disN (local):  Must uninstall FROM disN -- handled below.
	local _dis_fqdn="${DIS_VM}.${VM_BASE_DOMAIN}"

	# Case 3: uninstall any mirror installed locally on disN.
	# Only trigger when a registry was actually installed (marker file exists).
	# ~/aba/mirror/ always exists on disN after deploy (it's part of the source tree).
	echo "  Checking for locally-installed registries on disN ..."
	local _uninstall_failed=""
	local _try_user
	for _try_user in "${_dis_users[@]}"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_e2e_dis_as "$_try_user" "
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
			if [ "$_try_user" = testy ] && ! _essh "${VM_DEFAULT_USER:-steve}@${_dis_fqdn}" "id testy >/dev/null 2>&1"; then
				continue
			fi
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
	for _try_user in "${_dis_users[@]}"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		local _orphan_dirs
		_orphan_dirs=$(_e2e_dis_as "$_try_user" "find ~/e2e-mirror-* ~/${_E2E_ABA_INTERNAL_DIRS// / ~/} -maxdepth 2 -name INSTALLED_BY_ABA.md -type f" || true)
		if [ -n "$_orphan_dirs" ]; then
			echo "  [cleanup] Found orphaned registry breadcrumbs for $_try_user on disN:"
			echo "$_orphan_dirs" | while read -r _md_path; do
				local _data_dir
				_data_dir=$(dirname "$_md_path")
				echo "    $_data_dir"
				# Attempt proper uninstall using mirror-registry if available
				_e2e_dis_as "$_try_user" "
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
	for _try_user in "${_dis_users[@]}"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_e2e_dis_as "$_try_user" "podman secret ls --format '{{.Name}}' | grep -q redis_pass" \
			&& _podman_stale+="  $_try_user: redis_pass podman secret exists"$'\n'
		_e2e_dis_as "$_try_user" "podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres'" \
			&& _podman_stale+="  $_try_user: quay containers still present"$'\n'
		_e2e_dis_as "$_try_user" "systemctl --user list-units 'quay-*' --no-legend | grep -v 'not-found' | grep -q ." \
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
	for _try_user in "${_dis_users[@]}"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_e2e_dis_as "$_try_user" "rm -rf ~/aba/* ~/aba/.??* ~/tmp/* ~/.aba/mirror ~/.cache/agent ~/.oc-mirror && rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane}" 2>&1
		# Registry/test data dirs may contain files owned by container-mapped UIDs
		# (rootless podman UID remapping), so sudo is needed for cleanup.
		# Uses globs (e2e-mirror-*, e2e-test-*) + ABA-internal dirs.
		_e2e_dis_as "$_try_user" "sudo rm -rf ~/e2e-mirror-* ~/e2e-test-*" 2>&1
		for _mdir in $_E2E_ABA_INTERNAL_DIRS; do
			_e2e_dis_as "$_try_user" "sudo rm -rf ~/$_mdir" 2>&1
		done
	done
	# disN must never have a Red Hat pull secret (true air-gap invariant)
	for _try_user in "${_dis_users[@]}"; do
		local _uhost="${_try_user}@${_dis_fqdn}"
		_e2e_dis_as "$_try_user" "rm -f ~/.pull-secret.json" 2>&1
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

	# VC_FOLDER is applied after this function returns, including when the
	# disN tree was kept. A warning-only sed here used to leave abatesting
	# in place and the suite still started.

	# 5. Verify port 8443 is free (registry fully uninstalled).
	#    Cross-user scenarios (steve->root) are handled by snapshot revert in run.sh.
	#    This catches same-user partial installs where aba uninstall couldn't fully
	#    tear down orphaned containers.
	if _essh "$dis_host" "ss -tlnp | grep -q ':8443 '"; then
		echo "  WARNING: port 8443 still occupied after cleanup -- retrying aba uninstall"
		for _try_user in "${_dis_users[@]}"; do
			local _uhost="${_try_user}@${_dis_fqdn}"
			# Crash-recovery fallback: aba uninstall already ran but couldn't stop
			# orphaned containers (partial install, no config left).  podman stop
			# is the only option when aba state is gone.
			# pool-registry is the lab registry. Never stop or remove it.
			_e2e_dis_as "$_try_user" "
				cd /tmp
				podman ps -a --format '{{.Names}}' | while read -r _n; do
					[ -n \"\$_n\" ] || continue
					[ \"\$_n\" = pool-registry ] && continue
					echo \"  [cleanup] Stopping \$_n\"
					podman stop -t 5 \"\$_n\" || true
					podman rm -f \"\$_n\" || true
				done
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
	echo "  catalog indexes: cleared ~/aba/.index contents (3/10 reset, conN only). catalogs/ stays."
	# Keep the directory. It is in the repo, and mirror/.index is a symlink to it.
	if [ -d "$_aba/.index" ]; then
		find "$_aba/.index" -mindepth 1 -delete
	fi
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
# merges into the files of the user who runs aba. That login must still be
# present when the suite ends. A missing file is copied from the pull secret
# and would drop the dummy, which is why the plant happens after the delete.
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
	if [ $(( RANDOM % 10 )) -ge 3 ]; then
		echo "  container auth: kept (not this run's 3/10 reset)"
	else
		echo "  container auth: removed (3/10 reset). The next save/sync/load writes it again."
		_e2e_rm_container_auth
	fi

	echo "  container auth: planted ${_E2E_AUTH_DUMMY_HOST} (must still be there at suite end)"
	rm -f "$_E2E_AUTH_DUMMY_MARKER"
	if ! _e2e_plant_auth_home; then
		echo "  FATAL: dummy auth plant failed for $USER" >&2
		return 1
	fi
	if ! _e2e_auth_dummy_present "$HOME/.docker/config.json" \
		|| ! _e2e_auth_dummy_present "$HOME/.containers/auth.json"; then
		echo "  FATAL: dummy auth did not stick for $USER" >&2
		return 1
	fi
	# -s is the assert's "this run planted" check, so the file cannot be empty.
	printf '%s\n' "$HOME" > "$_E2E_AUTH_DUMMY_MARKER"
}

# Fail when a planted dummy login was removed from the user who ran aba.
# Merge keeps other registries. Root and the remote host are not merged by
# create-containers-auth unless that user is the one running aba.
_e2e_auth_dummy_present() {
	local dest="$1"
	[ -s "$dest" ] || return 1
	jq -e --arg h "$_E2E_AUTH_DUMMY_HOST" --arg a "$_E2E_AUTH_DUMMY_AUTH" \
		'.auths[$h].auth == $a' "$dest" >/dev/null
}

_e2e_auth_dummy_log() {
	local msg="$1" log
	echo "$msg"
	log="${E2E_LOG_FILE:-}"
	if [ -z "$log" ] && [ -n "${E2E_LOG_DIR:-}" ] && [ -n "${SUITE:-}" ]; then
		log="${E2E_LOG_DIR}/${SUITE}-latest.log"
	fi
	[ -n "$log" ] && echo "$msg" >> "$log"
}

_e2e_assert_auth_dummy() {
	local _miss=0 _f
	[ -s "$_E2E_AUTH_DUMMY_MARKER" ] || return 0

	for _f in "$HOME/.docker/config.json" "$HOME/.containers/auth.json"; do
		if ! _e2e_auth_dummy_present "$_f"; then
			_e2e_auth_dummy_log "  container auth: dummy missing from $_f"
			_miss=1
		fi
	done
	[ "$_miss" -eq 0 ]
}

# Shell that deletes leftover state under root, steve, and testy.
# $1 is a space-separated item list. The old ~/.aba.previous.backup stamp is
# always removed. E2E_STATE_BASE (tests) points homes at $base/$user.
_e2e_state_reset_script() {
	cat <<-'EOF'
	items=$1
	base=${E2E_STATE_BASE:-}
	want() {
		case " $items " in
			*" $1 "*) return 0 ;;
			*) return 1 ;;
		esac
	}
	for u in root steve testy; do
		if [ -n "$base" ]; then
			h="$base/$u"
		else
			case "$u" in
				root) h=/root ;;
				*) h=/home/$u ;;
			esac
		fi
		[ -d "$h" ] || continue
		rm -f "$h/.aba.previous.backup"
		if want caches; then
			rm -rf "$h/.oc-mirror" "$h/.cache/agent" "$h/tmp"
			if [ -d "$h/aba" ]; then
				find "$h/aba" -type d -name .oc-mirror -prune -exec rm -rf {} +
			fi
		fi
		if want backup; then
			rm -f "$h/.aba/.previous.backup"
		fi
		if want bins; then
			rm -f "$h/bin/oc" "$h/bin/kubectl" "$h/bin/oc-mirror" \
				"$h/bin/openshift-install" "$h/bin/govc" "$h/bin/butane" "$h/bin/aba"
		fi
		if want auth; then
			rm -f "$h/.docker/config.json" \
				"$h/.containers/auth.json" \
				"$h/.config/containers/auth.json"
			rm -f "$h/.ssh"/quay_installer*
		fi
		if want sshconf; then
			# A tree that cannot rewrite ssh.conf has to keep the file.
			if [ -d "$h/aba/scripts" ] && [ ! -f "$h/aba/scripts/ensure-ssh-conf.sh" ]; then
				:
			else
				rm -f "$h/.aba/ssh.conf"
			fi
		fi
		if want runner; then
			# Kill setsid jobs first. A bare rm leaves them running.
			if [ -f "$h/aba/scripts/include_all.sh" ]; then
				sudo -u "$u" -H bash -c 'source "$1" && run_once -G' _ "$h/aba/scripts/include_all.sh" || true
			fi
			rm -rf "$h/.aba/runner"
		fi
		if want abacache; then
			rm -rf "$h/.aba/cache"
		fi
	done
	EOF
}

# $1 item list. With E2E_STATE_BASE set, run against that tree and do not SSH.
_e2e_state_reset_run() {
	local items="$1" script _dis _user
	script=$(_e2e_state_reset_script)
	if [ -n "${E2E_STATE_BASE:-}" ]; then
		bash -s -- "$items" <<<"$script"
		return
	fi
	echo "  state files on conN: ${items:-none} (old backup stamp always removed)"
	sudo bash -s -- "$items" <<<"$script" \
		|| echo "  WARNING: conN state reset failed"
	_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
	_user="${VM_DEFAULT_USER:-steve}"
	echo "  state files on disN (${_user}): ${items:-none}"
	_essh "${_user}@${_dis}" "sudo bash -s -- $(printf '%q' "$items")" <<<"$script" \
		|| echo "  WARNING: disN state reset failed"
}

# Image prune for root, steve, and testy. Skip volume prune when the pool
# registry container or its directory is on this host. Never stop or remove
# a container named pool-registry. $1 is the registry directory.
_e2e_podman_prune_script() {
	cat <<-'EOF'
	regdir=$1
	for u in root steve testy; do
		id "$u" >/dev/null 2>&1 || continue
		if [ "$u" = root ]; then
			podman image prune -af || true
		else
			sudo -u "$u" podman image prune -af || true
		fi
	done
	if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx pool-registry || [ -d "$regdir" ]; then
		echo "  podman volumes: skipped (pool registry present)"
	else
		podman volume prune -f || true
		for u in steve testy; do
			id "$u" >/dev/null 2>&1 || continue
			sudo -u "$u" podman volume prune -f || true
		done
	fi
	EOF
}

_e2e_podman_prune_run() {
	local script _dis _user _dir
	script=$(_e2e_podman_prune_script)
	_dir="${POOL_REG_DIR:-/opt/pool-reg}"
	echo "  podman: pruning unused images on conN"
	sudo bash -s -- "$_dir" <<<"$script" \
		|| echo "  WARNING: podman prune failed on conN"
	_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
	_user="${VM_DEFAULT_USER:-steve}"
	echo "  podman: pruning unused images on disN"
	_essh "${_user}@${_dis}" "sudo bash -s -- $(printf '%q' "$_dir")" <<<"$script" \
		|| echo "  WARNING: podman prune failed on disN"
}

# Delete /etc/dnsmasq.d/aba-*.conf and restart dnsmasq.
# Never aba remove dns (that stops dnsmasq). Never e2e-pool.conf.
# E2E_DNS_DIR overrides the directory for tests and skips the restart.
_e2e_dns_reset_script() {
	cat <<-'EOF'
	dnsdir=${E2E_DNS_DIR:-/etc/dnsmasq.d}
	removed=
	for f in "$dnsdir"/aba-*.conf; do
		[ -e "$f" ] || continue
		case "$f" in
			*/e2e-pool.conf) continue ;;
		esac
		rm -f "$f"
		removed=1
	done
	if [ -n "$removed" ] && [ -z "${E2E_DNS_DIR:-}" ]; then
		systemctl restart dnsmasq || true
	fi
	EOF
}

_e2e_dns_reset_run() {
	local script _dis _user
	script=$(_e2e_dns_reset_script)
	if [ -n "${E2E_DNS_DIR:-}" ]; then
		bash -s <<<"$script"
		return
	fi
	echo "  ABA DNS: removing aba-*.conf on conN"
	sudo bash -s <<<"$script" || echo "  WARNING: ABA DNS reset failed on conN"
	_dis="${DIS_VM}.${VM_BASE_DOMAIN}"
	_user="${VM_DEFAULT_USER:-steve}"
	echo "  ABA DNS: removing aba-*.conf on disN"
	_essh "${_user}@${_dis}" "sudo bash -s" <<<"$script" \
		|| echo "  WARNING: ABA DNS reset failed on disN"
}

# Independent 3/10 draws. One roll of each item covers conN and disN, and
# root, steve, and testy. Runs before the container-auth plant so a delete
# cannot drop the dummy login that plant just wrote.
_e2e_maybe_reset_host_state() {
	local _items="" _name _label
	local -A _labels=(
		[caches]="oc-mirror and agent cache"
		[backup]="previous.backup"
		[bins]="CLI bins"
		[auth]="auth files"
		[sshconf]="ssh.conf"
		[runner]="runner state"
		[abacache]="aba cache"
		[images]="podman images"
		[dns]="ABA DNS"
	)
	local -a _names=(caches backup bins auth sshconf runner abacache images dns)
	for _name in "${_names[@]}"; do
		_label="${_labels[$_name]}"
		if [ $(( RANDOM % 10 )) -lt 3 ]; then
			_items="${_items:+$_items }$_name"
			echo "  ${_label}: removed (3/10 reset)"
		else
			echo "  ${_label}: kept (not this run's 3/10 reset)"
		fi
	done
	_e2e_state_reset_run "$_items"
	case " $_items " in
		*" images "*) _e2e_podman_prune_run ;;
	esac
	case " $_items " in
		*" dns "*) _e2e_dns_reset_run ;;
	esac
}
