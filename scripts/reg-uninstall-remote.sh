#!/bin/bash
# Generic SSH orchestrator for remote registry uninstall.
# Called by reg-uninstall.sh dispatcher with vendor name as first argument.
# Usage: reg-uninstall-remote.sh <quay|docker> [args...]
# Reads install-time state from $regcreds_dir/state.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

vendor="$1"; shift

aba_debug "Starting: $0 vendor=$vendor $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

verify-aba-conf || true

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No registry state found in $regcreds_dir/state.sh"
fi

source "$regcreds_dir/state.sh"

ssh_conf_file=~/.aba/ssh.conf
_ssh="ssh -i $REG_SSH_KEY -F $ssh_conf_file $REG_SSH_USER@$REG_HOST"

# Verify SSH connectivity
if ! $_ssh true; then
	aba_abort \
		"Cannot SSH to '$REG_SSH_USER@$REG_HOST' using key '$REG_SSH_KEY'" \
		"The registry was installed remotely but SSH access has failed." \
		"Fix SSH connectivity and try again."
fi

if ask "Uninstall $vendor registry on remote host $REG_SSH_USER@$REG_HOST:$REG_ROOT"; then

	case "$vendor" in
		quay)
			aba_info "Uninstalling Quay registry on remote host $REG_HOST ..."

			# Ensure mirror-registry binary is available on remote host (tarball provided by Makefile deps)
			if ! $_ssh "test -f $REG_ROOT/../mirror-registry"; then
				aba_info "mirror-registry not found on remote host, uploading ..."
				tarball=""
				for f in mirror-registry-*.tar.gz; do
					[ -f "$f" ] && tarball="$f" && break
				done
				if [ -z "$tarball" ]; then
					aba_abort "mirror-registry tarball not found in $(pwd). Run 'aba -d mirror uninstall' so the Makefile provides it."
				fi

				# Use a unique temp dir to avoid conflicts with leftover files from previous runs
				remote_tmp="/tmp/aba-reg-uninstall-$$"
				$_ssh "mkdir -p $remote_tmp" || aba_abort "Failed to create temp dir on $REG_HOST"
				trap '$_ssh "rm -rf $remote_tmp" 2>/dev/null' EXIT

				_scp="scp -i $REG_SSH_KEY -F $ssh_conf_file"
				$_scp "$tarball" "$REG_SSH_USER@$REG_HOST:$remote_tmp/" || \
					aba_abort "Failed to copy mirror-registry tarball to $REG_HOST"
				$_ssh "cd $remote_tmp && tar xmf $tarball && mv mirror-registry $REG_ROOT/../" || \
					aba_abort "Failed to extract/move mirror-registry on $REG_HOST"
				$_ssh "rm -rf $remote_tmp"
			fi

			aba_info "Running: mirror-registry uninstall on $REG_HOST ..."
			if ! $_ssh "cd $REG_ROOT/.. && ./mirror-registry uninstall -v --autoApprove $REG_ROOT_OPTS"; then
				aba_abort "Quay mirror-registry uninstall failed on $REG_HOST"
			fi
			;;

		docker)
			aba_info "Uninstalling Docker registry on remote host $REG_HOST ..."
			$_ssh "podman rm -f registry 2>/dev/null; \
				$SUDO rm -rf $REG_ROOT" || true
			;;

		*)
			aba_abort "Unknown registry vendor: $vendor"
			;;
	esac

	rm -rf "${regcreds_dir:?}/"*
	rm -f .installed
	touch .uninstalled

	aba_info_ok "Remote $vendor registry uninstall successful"
	exit 0
fi

exit 1
