#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- Deploy / Harness Sync
# =============================================================================
# Consolidates ALL scp operations into a single module.
# The old run.sh had 4 copies of the same scp block -- this eliminates that.
#
# Functions:
#   sync_harness     -- push test harness to ~/.e2e-harness/ on a conN target
#   sync_infra_aba   -- push infra-owned aba binary to conN + disN
#   sync_source      -- push ABA source tarball to ~/aba on a conN target
#   sync_extras      -- push notify.sh, vmware.conf, root essentials
#   deploy_pool      -- full deploy to one pool (source + harness + extras)
#
# Dependencies: remote.sh (for _essh, _escp, _con_target)
# =============================================================================

# Build an ABA source tarball from the developer's checkout.
# Writes path to temp tarball on stdout.
_make_source_tar() {
	local aba_root="$1"
	local _tar _manifest _paths=()
	_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
	_manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.deploy-manifest"

	if [ -f "$_manifest" ]; then
		while IFS= read -r _line; do
			_line="${_line%%#*}"
			_line="${_line## }"
			_line="${_line%% }"
			[ -z "$_line" ] && continue
			_paths+=("$_line")
		done < "$_manifest"
	else
		_paths=(scripts/ templates/ tools/ test/lib.sh Makefile cli/Makefile aba install)
	fi

	tar czf "$_tar" -C "$aba_root" --exclude='*/.*' "${_paths[@]}"
	echo "$_tar"
}

# Push test harness to ~/.e2e-harness/ on conN.
# Preserves logs/ directory (only code is replaced).
# Usage: sync_harness <user@host> <aba_root> <deploy_config_env>
sync_harness() {
	local target="$1"
	local aba_root="$2"
	local deploy_config="$3"

	_essh "$target" "rm -rf ~/.e2e-harness/{lib,suites,scripts,runner.sh,config.env,pools.conf} && mkdir -p ~/.e2e-harness/{lib,suites,scripts,logs}" || return 1

	# Clean stale regular-file *-summary.log and summary.log left by old rsync deploys.
	# suite_start creates these as symlinks; a regular file blocks ln -sf and tail -F.
	_essh "$target" "cd ~/.e2e-harness/logs 2>/dev/null && for f in *-summary.log summary.log; do [ -f \"\$f\" ] && [ ! -L \"\$f\" ] && rm -f \"\$f\"; done" || true

	_escp "${aba_root}/test/e2e/runner.sh"          "${target}:~/.e2e-harness/runner.sh" &&
	_escp "$deploy_config"                           "${target}:~/.e2e-harness/config.env" &&
	_escp "${aba_root}/test/e2e/pools.conf"          "${target}:~/.e2e-harness/pools.conf" &&
	_escp "${aba_root}/test/e2e/lib/"*.sh            "${target}:~/.e2e-harness/lib/" &&
	_escp "${aba_root}/test/e2e/suites/"suite-*.sh   "${target}:~/.e2e-harness/suites/" &&
	_escp "${aba_root}/test/e2e/scripts/"*.sh        "${target}:~/.e2e-harness/scripts/"
}

# Deploy infra-owned aba binary to ~/.e2e-harness/bin/aba on both conN and disN.
# In dev mode (local file present), uses the working-copy scripts/aba.sh so
# uncommitted changes are picked up. Otherwise falls back to git show.
# Deploys for both root and $VM_DEFAULT_USER so cleanup functions can SSH as either.
# Usage: sync_infra_aba <pool_num> <aba_root>
sync_infra_aba() {
	local pool_num="$1"
	local aba_root="$2"
	local branch="${E2E_GIT_BRANCH:-dev}"
	local default_user="${VM_DEFAULT_USER:-steve}"
	local domain="${VM_BASE_DOMAIN:-example.com}"
	local con_fqdn="con${pool_num}.${domain}"
	local dis_fqdn="dis${pool_num}.${domain}"

	local _tmp
	_tmp=$(mktemp /tmp/aba-infra.XXXXXX.sh)
	if [ -f "$aba_root/scripts/aba.sh" ]; then
		cp "$aba_root/scripts/aba.sh" "$_tmp"
	else
		git -C "$aba_root" show "${branch}:scripts/aba.sh" > "$_tmp" || {
			echo "    WARNING: could not extract aba.sh from branch $branch" >&2
			rm -f "$_tmp"
			return 1
		}
	fi

	local _host _user _target
	for _host in "$con_fqdn" "$dis_fqdn"; do
		for _user in root "$default_user"; do
			_target="${_user}@${_host}"
			_essh "$_target" "mkdir -p ~/.e2e-harness/bin" &&
			_escp "$_tmp" "${_target}:~/.e2e-harness/bin/aba" &&
			_essh "$_target" "chmod +x ~/.e2e-harness/bin/aba" || {
				echo "    WARNING: failed to deploy infra aba to $_target" >&2
				rm -f "$_tmp"
				return 1
			}
		done
	done
	rm -f "$_tmp"
}
# Backward-compat alias
sync_dis_aba() { sync_infra_aba "$@"; }

# Push ABA source tarball to ~/aba on conN (for --dev mode).
# Overlays on existing ~/aba (never wipes).
# Deploys to BOTH the target user's ~/aba AND root's ~/aba, because
# the runner may run as root (-u root) which uses /root/aba/ -- a
# separate directory from /home/<user>/aba/.
# Also refreshes ~/bin/aba for both users (installed by ./install).
# Usage: sync_source <user@host> <tarball_path>
sync_source() {
	local target="$1"
	local tarball="$2"
	local _user="${target%%@*}"
	local _host="${target#*@}"

	# Upload tarball once to /tmp (accessible by both users)
	_escp "$tarball" "${target}:/tmp/aba-deploy.tar.gz" || return 1

	# Extract for the deploy user
	_essh "$target" "mkdir -p ~/aba && tar xzf /tmp/aba-deploy.tar.gz -C ~/aba" || return 1

	# Extract for root too if connected as non-root
	if [ "$_user" != "root" ]; then
		_essh "root@${_host}" "mkdir -p ~/aba && tar xzf /tmp/aba-deploy.tar.gz -C ~/aba" || true
	fi

	# Refresh ~/bin/aba for both users (./install copies scripts/aba.sh there)
	_essh "$target" "[ -f ~/aba/scripts/aba.sh ] && cp ~/aba/scripts/aba.sh ~/bin/aba && chmod +x ~/bin/aba" || true
	if [ "$_user" != "root" ]; then
		_essh "root@${_host}" "[ -f ~/aba/scripts/aba.sh ] && cp ~/aba/scripts/aba.sh ~/bin/aba && chmod +x ~/bin/aba" || true
	fi

	# Cleanup
	_essh "${target}" "rm -f /tmp/aba-deploy.tar.gz"
	[ "$_user" != "root" ] && _essh "root@${_host}" "rm -f /tmp/aba-deploy.tar.gz" || true
}

# Push optional extras: notify.sh, vmware.conf, root essentials.
# Usage: sync_extras <user@host> <user> [pool_num]
sync_extras() {
	local target="$1"
	local user="$2"
	local pool_num="${3:-}"

	# notify.sh
	if [ -x ~/bin/notify.sh ]; then
		_essh "$target" "mkdir -p ~/bin" &&
		_escp ~/bin/notify.sh "${target}:~/bin/notify.sh" &&
		_essh "$target" "chmod +x ~/bin/notify.sh"
	fi

	# Deploy vmware.conf to all pool VMs so runner.sh sources correct
	# GOVC_ credentials (golden snapshot may have stale values).
	local _vf="${CLI_VMWARE_CONF:-$HOME/.vmware.conf}"
	if [ -f "$_vf" ]; then
		[ -n "${CLI_VMWARE_CONF:-}" ] && _escp "$_vf" "${target}:${CLI_VMWARE_CONF}"
		_escp "$_vf" "${target}:~/.vmware.conf"
		local _host="${target#*@}"
		local _dis_host="${_host/con/dis}"
		for _dt in "root@${_host}" "${target/con/dis}" "root@${_dis_host}"; do
			_escp "$_vf" "${_dt}:~/.vmware.conf" 2>/dev/null || true
		done
	fi

	# Deploy per-pool VMWARE_CONF from pools.conf (e.g. ~/.vmware.conf.vc.pools)
	# so suites using $VMWARE_CONF find the file at the expected path.
	if [ -n "$pool_num" ]; then
		local _pool_vconf
		_pool_vconf=$(_pool_vmware_conf "${_RUN_DIR}/pools.conf" "$pool_num" 2>/dev/null) || true
		if [ -n "$_pool_vconf" ]; then
			local _pool_vf
			_pool_vf="$(eval echo "$_pool_vconf")"
			if [ -f "$_pool_vf" ] && [ "$_pool_vf" != "$_vf" ]; then
				local _host="${target#*@}"
				local _dis_host="${_host/con/dis}"
				_escp "$_pool_vf" "${target}:${_pool_vconf}"
				for _dt in "root@${_host}" "${target/con/dis}" "root@${_dis_host}"; do
					_escp "$_pool_vf" "${_dt}:${_pool_vconf}" 2>/dev/null || true
				done
			fi
		fi
	fi

	# Always deploy ESXi config so ESXi-specific tests work regardless of -v flag
	if [ -f "$HOME/.vmware.conf.esxi" ] && [ "$_vf" != "$HOME/.vmware.conf.esxi" ]; then
		_escp "$HOME/.vmware.conf.esxi" "${target}:~/.vmware.conf.esxi"
	fi

	# Ensure KVM VLAN route survives provisioning gaps or snapshot reverts.
	local _root_target="root@${target#*@}"
	_essh "$_root_target" \
		"nmcli -g ipv4.routes connection show ens192 2>/dev/null | grep -q '10.10.123.0/24' || \
		 { nmcli connection modify ens192 +ipv4.routes '10.10.123.0/24 ${KVM_HOST_LAB_IP:-10.0.1.10}' && \
		   nmcli connection up ens192; }" 2>/dev/null || true

	# Ensure dnsmasq config includes all cluster entries (e.g. kvm-sno-vlan).
	# VMs provisioned before new entries were added won't have them.
	# Re-run _vm_setup_dnsmasq() (single source of truth) if stale.
	if [ -n "$pool_num" ]; then
		if ! _essh "$_root_target" "grep -q 'kvm-sno-vlan' /etc/dnsmasq.d/e2e-pool.conf" 2>/dev/null; then
			if type _vm_setup_dnsmasq &>/dev/null; then
				_vm_setup_dnsmasq "con${pool_num}" "${user}" "con${pool_num}"
			else
				local _lib_dir
				_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
				source "$_lib_dir/vm-network.sh"
				_vm_setup_dnsmasq "con${pool_num}" "${user}" "con${pool_num}"
			fi
		fi
	fi

	# Push corrected Makefile + template to disN after snapshot reverts.
	# Pool-ready snapshots pre-date the cli:download:govc fallback fix;
	# without --dev the ABA source tree is never re-synced, so we push
	# just the two files that changed.
	local _aba_root="${_RUN_DIR%/test/e2e}"
	local _host="${target#*@}"
	local _dis_host="${_host/con/dis}"
	for _dt in "${target/con/dis}" "root@${_dis_host}"; do
		_essh "$_dt" "[ -d ~/aba/templates ]" 2>/dev/null || continue
		_escp "${_aba_root}/templates/Makefile.cluster" "${_dt}:~/aba/templates/Makefile.cluster" 2>/dev/null || true
		_escp "${_aba_root}/Makefile"                   "${_dt}:~/aba/Makefile" 2>/dev/null || true
	done

	# Root essentials (govc, pull-secret, vmware.conf)
	_deploy_root_essentials "$target" "$user"
}

# Deploy govc, pull-secret, and vmware.conf so that root users (or freshly
# reverted VMs) have the essentials before runner.sh's pre-suite checks.
_deploy_root_essentials() {
	local target="$1"
	local user="$2"

	_essh "$target" "mkdir -p ~/.e2e-harness/bin ~/bin"

	local _govc_src="${HOME}/bin/govc"
	if [ -x "$_govc_src" ]; then
		_escp "$_govc_src" "${target}:~/.e2e-harness/bin/govc"
		_essh "$target" "cp ~/.e2e-harness/bin/govc ~/bin/govc && chmod 755 ~/bin/govc"
	fi

	if [ "$user" = "root" ]; then
		local _ps="$HOME/.pull-secret.json"
		[ -f "$_ps" ] && _escp "$_ps" "${target}:~/.pull-secret.json"
	fi
}

# Full deploy to one pool: source (if --dev) + harness + extras.
# Usage: deploy_pool <pool_num> <aba_root> <deploy_config> [source_tarball]
deploy_pool() {
	local pool_num="$1"
	local aba_root="$2"
	local deploy_config="$3"
	local source_tar="${4:-}"

	local user="${CON_SSH_USER:-steve}"
	local target
	target=$(_con_target "$pool_num" "$user")

	echo -n "    con${pool_num}: "

	# Check for running suite (skip unless --force)
	local _running_sess=""
	_running_sess=$(_essh "$target" "tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null) || _running_sess=""
	if [ "$_running_sess" = "yes" ]; then
		if [ -z "${CLI_FORCE:-}" ]; then
			echo "RUNNING (skipped -- use --force to deploy anyway)"
			return 0
		fi
		echo -n "RUNNING (hot-deploy) "
	fi

	# Source deploy (--dev mode)
	if [ -n "$source_tar" ]; then
		if sync_source "$target" "$source_tar"; then
			echo -n "source "
		else
			echo "FAILED (source deploy)"
			return 1
		fi
	fi

	# Harness deploy
	if sync_harness "$target" "$aba_root" "$deploy_config"; then
		sync_infra_aba "$pool_num" "$aba_root" || echo "WARNING: infra aba deploy to pool ${pool_num} failed"
		sync_extras "$target" "$user" "$pool_num"
		echo "+ harness done"
	else
		echo "+ harness FAILED"
		return 1
	fi
}

# Deploy harness + source/git to all pools.
# Wraps the per-pool harness deploy, dev-mode source push, and git branch sync.
# Globals: CLI_POOL_LIST, CLI_DEV, CLI_CON_USER, _RUN_DIR, _ABA_ROOT,
#          _DEPLOY_CONFIG_ENV, E2E_GIT_BRANCH, E2E_GIT_REPO_SLUG, CON_SSH_USER
_deploy_to_pools() {
	local _saved_con_ssh_user="${CON_SSH_USER:-}"

	_export_pool_ssh_user() {
		local _pool="$1"
		local _u
		_u=$(_pool_con_user "${_RUN_DIR}/pools.conf" "$_pool" 2>/dev/null) || true
		[ -n "${CLI_CON_USER:-}" ] && _u="$CLI_CON_USER"
		export CON_SSH_USER="${_u:-${_saved_con_ssh_user:-steve}}"
	}

	echo ""
	echo "  Deploying test harness to conN hosts ..."
	local _p target
	for _p in $CLI_POOL_LIST; do
		_export_pool_ssh_user "$_p"
		target=$(_con_target "$_p")
		if sync_harness "$target" "$_ABA_ROOT" "$_DEPLOY_CONFIG_ENV"; then
			sync_dis_aba "$_p" "$_ABA_ROOT" || echo "    WARNING: infra aba deploy to dis${_p} failed"
			sync_extras "$target" "${CON_SSH_USER:-steve}" "$_p"
			_essh "$target" "sudo loginctl enable-linger ${CON_SSH_USER:-steve}"
			echo "    con${_p}: harness deployed to ~/.e2e-harness/"
		else
			echo "    con${_p}: FAILED to deploy harness (skipping)" >&2
		fi
	done
	export CON_SSH_USER="${_saved_con_ssh_user:-steve}"

	if [ -n "${CLI_DEV:-}" ]; then
		echo ""
		echo "  Developer mode: pushing ABA source to conN hosts ..."
		local _deploy_tar _deploy_size
		_deploy_tar=$(_make_source_tar "$_ABA_ROOT")
		_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
		echo "  Source tarball: $_deploy_size"
		_saved_con_ssh_user="${CON_SSH_USER:-}"
		for _p in $CLI_POOL_LIST; do
			_export_pool_ssh_user "$_p"
			target=$(_con_target "$_p")
			echo -n "    con${_p}: "
			if sync_source "$target" "$_deploy_tar"; then
				echo "done"
			else
				echo "FAILED"
			fi
		done
		export CON_SSH_USER="${_saved_con_ssh_user:-steve}"
		rm -f "$_deploy_tar"
	else
		# Non-dev mode: install ABA from git on any conN that doesn't have it yet.
		local _need_install=""
		_saved_con_ssh_user="${CON_SSH_USER:-}"
		for _p in $CLI_POOL_LIST; do
			_export_pool_ssh_user "$_p"
			target=$(_con_target "$_p")
			if ! _essh "$target" "test -x ~/aba/install" 2>/dev/null; then
				_need_install=1
				break
			fi
		done
		if [ -n "$_need_install" ]; then
			echo ""
			echo "  Installing ABA from git ($E2E_GIT_BRANCH) on conN hosts ..."
			for _p in $CLI_POOL_LIST; do
				_export_pool_ssh_user "$_p"
				target=$(_con_target "$_p")
				echo -n "    con${_p}: "
				if _essh "$target" "test -x ~/aba/install" 2>/dev/null; then
					echo "already installed"
				elif _essh "$target" "cd ~ && rm -rf ~/aba && bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$E2E_GIT_REPO_SLUG/refs/heads/$E2E_GIT_BRANCH/install)\" -- $E2E_GIT_BRANCH $E2E_GIT_REPO_SLUG" 2>&1; then
					echo "done"
				else
					echo "FAILED"
				fi
			done
		fi

		# After -V revert, ~/aba may exist (from snapshot) but on the wrong branch.
		# Ensure all conN hosts are on E2E_GIT_BRANCH.
		echo ""
		echo "  Ensuring ABA is on branch '$E2E_GIT_BRANCH' on conN hosts ..."
		local _cur_branch
		for _p in $CLI_POOL_LIST; do
			_export_pool_ssh_user "$_p"
			target=$(_con_target "$_p")
			echo -n "    con${_p}: "
			_cur_branch=$(_essh "$target" "cd ~/aba && git rev-parse --abbrev-ref HEAD 2>/dev/null" 2>/dev/null) || _cur_branch=""
			if [ "$_cur_branch" = "$E2E_GIT_BRANCH" ]; then
				_essh "$target" "cd ~/aba && git fetch origin $E2E_GIT_BRANCH && git reset --hard FETCH_HEAD" >/dev/null 2>&1
				echo "ok (already on $E2E_GIT_BRANCH)"
			elif [ -n "$_cur_branch" ]; then
				if _essh "$target" "cd ~/aba && git fetch origin $E2E_GIT_BRANCH && git checkout -B $E2E_GIT_BRANCH FETCH_HEAD" >/dev/null 2>&1; then
					echo "switched $_cur_branch -> $E2E_GIT_BRANCH"
				else
					echo "FAILED to switch to $E2E_GIT_BRANCH"
				fi
			else
				echo "skipped (no git repo)"
			fi
		done
		export CON_SSH_USER="${_saved_con_ssh_user:-steve}"
	fi
}
