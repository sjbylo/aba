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

			# Run mirror-registry uninstall on the remote host
			if $_ssh "test -f $REG_ROOT/../mirror-registry"; then
				$_ssh "cd $REG_ROOT/.. && ./mirror-registry uninstall -v --autoApprove $REG_ROOT_OPTS"
			else
				# Fallback: try to find mirror-registry in common locations
				aba_warning "mirror-registry binary not found in expected location on $REG_HOST."
				aba_warning "Attempting to stop Quay containers directly ..."
				$_ssh "podman rm -f quay-postgres quay-redis quay-app 2>/dev/null; \
					$SUDO rm -rf $REG_ROOT" || true
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
