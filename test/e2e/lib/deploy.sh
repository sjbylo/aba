#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- Deploy / Harness Sync
# =============================================================================
# Consolidates ALL scp operations into a single module.
# The old run.sh had 4 copies of the same scp block -- this eliminates that.
#
# Functions:
#   sync_harness     -- push test harness to ~/.e2e-harness/ on a conN target
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
	local _tar
	_tar=$(mktemp /tmp/aba-deploy.XXXXXX.tar.gz)
	tar czf "$_tar" -C "$aba_root" \
		--exclude='*/.*' \
		scripts/ \
		templates/ \
		test/lib.sh \
		Makefile \
		cli/Makefile \
		aba \
		install
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

	_escp "${aba_root}/test/e2e/runner.sh"          "${target}:~/.e2e-harness/runner.sh" &&
	_escp "$deploy_config"                           "${target}:~/.e2e-harness/config.env" &&
	_escp "${aba_root}/test/e2e/pools.conf"          "${target}:~/.e2e-harness/pools.conf" &&
	_escp "${aba_root}/test/e2e/lib/"*.sh            "${target}:~/.e2e-harness/lib/" &&
	_escp "${aba_root}/test/e2e/suites/"suite-*.sh   "${target}:~/.e2e-harness/suites/" &&
	_escp "${aba_root}/test/e2e/scripts/"*.sh        "${target}:~/.e2e-harness/scripts/"
}

# Push ABA source tarball to ~/aba on conN (for --dev mode).
# Overlays on existing ~/aba (never wipes).
# Usage: sync_source <user@host> <tarball_path>
sync_source() {
	local target="$1"
	local tarball="$2"

	_essh "$target" "mkdir -p ~/aba" &&
	_escp "$tarball" "${target}:/tmp/aba-deploy.tar.gz" &&
	_essh "$target" "tar xzf /tmp/aba-deploy.tar.gz -C ~/aba && rm -f /tmp/aba-deploy.tar.gz"
}

# Push optional extras: notify.sh, vmware.conf, root essentials.
# Usage: sync_extras <user@host> <user>
sync_extras() {
	local target="$1"
	local user="$2"

	# notify.sh
	if [ -x ~/bin/notify.sh ]; then
		_essh "$target" "mkdir -p ~/bin" &&
		_escp ~/bin/notify.sh "${target}:~/bin/notify.sh" &&
		_essh "$target" "chmod +x ~/bin/notify.sh"
	fi

	# Custom vmware.conf
	if [ -n "${CLI_VMWARE_CONF:-}" ] && [ -f "${CLI_VMWARE_CONF:-}" ]; then
		_escp "$CLI_VMWARE_CONF" "${target}:${CLI_VMWARE_CONF}"
	fi

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
		local _vf="$HOME/.vmware.conf"
		[ -f "$_vf" ] && _escp "$_vf" "${target}:~/.vmware.conf"
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
		sync_extras "$target" "$user"
		echo "+ harness done"
	else
		echo "+ harness FAILED"
		return 1
	fi
}
