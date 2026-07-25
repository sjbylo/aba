#!/bin/bash
# Generic SSH orchestrator for remote registry uninstall.
# Called by reg-uninstall.sh dispatcher with vendor name as first argument.
# Usage: reg-uninstall-remote.sh <quay|docker> [args...]
# Reads install-time state from $regcreds_dir/state.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh
source scripts/reg-common.sh

vendor="$1"; shift

aba_debug "Starting: $0 vendor=$vendor $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
export regcreds_display="regcreds"

# No verify-aba-conf — uninstall uses state.sh, not aba.conf values

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No registry state found in $regcreds_display/state.sh"
fi

source "$regcreds_dir/state.sh"

ssh_conf_file=~/.aba/ssh.conf
_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"

# Verify SSH connectivity
if ! $_ssh true; then
	aba_abort \
		"Cannot SSH to '$reg_ssh_user@$reg_host' using key '$reg_ssh_key'" \
		"The registry was installed remotely but SSH access has failed." \
		"Fix SSH connectivity and try again."
fi

if ask -n --auto-yes "Uninstall $vendor registry on remote host $reg_ssh_user@$reg_host:$reg_root"; then

	# mirror-registry binary and supporting files live alongside reg_root
	_mirror_dir="$(dirname "$reg_root")"

	# Already fully gone on the remote host → clear local state and succeed.
	_stale=$(reg_stale_report "$vendor" "$_ssh")
	if [ -z "$_stale" ]; then
		aba_info "$vendor registry already gone on $reg_host -- clearing local state"
		reg_close_firewall --ssh
		reg_finish_uninstall "Remote $vendor" "already uninstalled"
		exit 0
	fi

	case "$vendor" in
		quay)
			aba_info "Uninstalling Quay registry on remote host $reg_host ..."

			# Ensure mirror-registry binary AND its supporting files are on remote host.
			# mirror-registry needs execution-environment.tar, image-archive.tar, sqlite3.tar
			# in the same directory — check for all of them, not just the binary.
			if ! $_ssh "test -f $_mirror_dir/mirror-registry && test -f $_mirror_dir/execution-environment.tar"; then
				aba_info "mirror-registry or supporting files not found on remote host, uploading ..."
				tarball=""
				for f in mirror-registry-*.tar.gz; do
					[ -f "$f" ] && tarball="$f" && break
				done
				if [ -z "$tarball" ]; then
					aba_abort "mirror-registry tarball not found in $(pwd). Run 'aba -d mirror uninstall' so the Makefile provides it."
				fi

				# Use remote user's temp dir — $ABA_TMP is local-user-specific
				remote_tmp="/tmp/.aba-${reg_ssh_user}/reg-uninstall-$$"
				$_ssh "mkdir -p $remote_tmp" || aba_abort "Failed to create temp dir on $reg_host"
				trap '$_ssh "rm -rf $remote_tmp" 2>/dev/null' EXIT

				_scp="scp -i $reg_ssh_key -F $ssh_conf_file"
				$_scp "$tarball" "$reg_ssh_user@$reg_host:$remote_tmp/" || \
					aba_abort "Failed to copy mirror-registry tarball to $reg_host"
				# Extract into the parent of REG_ROOT so mirror-registry binary and its
				# supporting files are in the directory where mirror-registry expects them.
				# mkdir -p ensures the parent dir exists (may have been removed already).
				$_ssh "mkdir -p $_mirror_dir && tar -C $_mirror_dir --no-same-owner -xmzf $remote_tmp/$tarball" || \
					aba_abort "Failed to extract mirror-registry on $reg_host"
				$_ssh "rm -rf $remote_tmp"
			fi

			aba_info "Running: mirror-registry uninstall on $reg_host ..."
			_uninst_rc=0
			$_ssh "cd $_mirror_dir && ./mirror-registry uninstall -v --autoApprove $reg_root_opts" || _uninst_rc=$?

			_stale=$(reg_stale_report quay "$_ssh")
			if [ -n "$_stale" ]; then
				if [ "$_uninst_rc" -ne 0 ]; then
					aba_abort \
						"Quay mirror-registry uninstall failed on $reg_host (exit=$_uninst_rc) and left stale state:" \
						"$_stale" \
						"Investigate the uninstall failure above. Do not force-clean past an aba failure."
				fi
				aba_abort \
					"mirror-registry uninstall reported success but left stale state on $reg_host:" \
					"$_stale" \
					"Investigate why mirror-registry's Ansible playbook did not fully clean up."
			fi
			[ "$_uninst_rc" -ne 0 ] && \
				aba_info "mirror-registry uninstall exited $_uninst_rc on $reg_host but registry is fully gone -- treating as success"
			;;

		docker)
			aba_info "Uninstalling Docker registry on remote host $reg_host ..."
			$_ssh "podman rm -f registry 2>/dev/null; \
				$SUDO rm -rf $reg_root" || true

			_stale=$(reg_stale_report docker "$_ssh")
			if [ -n "$_stale" ]; then
				aba_abort \
					"Docker registry uninstall left stale state on $reg_host:" \
					"$_stale" \
					"Investigate and clean up manually before retrying."
			fi
			;;

		$_QUAY_NG_VENDOR)
			aba_info "Uninstalling $_QUAY_NG_VENDOR registry on remote host $reg_host ..."
			$_ssh "if systemctl --user is-active quay.service &>/dev/null; then \
					systemctl --user stop quay.service; \
				fi; \
				rm -f ~/.config/containers/systemd/quay.container; \
				systemctl --user daemon-reload 2>/dev/null; \
				[ -d '$reg_root' ] && $SUDO rm -rf '$reg_root'" || \
				aba_warn "Remote $_QUAY_NG_VENDOR cleanup returned non-zero"

			_stale=$(reg_stale_report "$_QUAY_NG_VENDOR" "$_ssh")
			if [ -n "$_stale" ]; then
				aba_abort \
					"$_QUAY_NG_VENDOR registry uninstall left stale state on $reg_host:" \
					"$_stale" \
					"Investigate and clean up manually before retrying."
			fi
			;;

		*)
			aba_abort "Unknown registry vendor: $vendor"
			;;
	esac

	reg_close_firewall --ssh
	reg_finish_uninstall "Remote $vendor" "uninstall successful"
	exit 0
fi

exit 1
