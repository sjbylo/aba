#!/bin/bash
# Dispatcher: uninstalls the currently installed registry.
# Reads persistent state from $regcreds_dir/state.sh to determine vendor
# and whether it was a local or remote install.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")

# No verify-aba-conf — uninstall uses state.sh, not aba.conf values

# Primary path: use persistent state.sh written at install time
if [ -s "$regcreds_dir/state.sh" ]; then
	source "$regcreds_dir/state.sh"

	# Externally-managed registries must use 'unregister', not 'uninstall'
	if [ "$REG_VENDOR" = "existing" ]; then
		aba_abort \
			"This is an externally-managed registry (registered, not installed by ABA)." \
			"Use 'aba -d $(basename $PWD) unregister' to remove the local credentials." \
			"The registry itself will not be modified."
	fi

	if [ "$REG_SSH_KEY" ]; then
		exec scripts/reg-uninstall-remote.sh "$REG_VENDOR" "$@"
	else
		exec scripts/reg-uninstall-${REG_VENDOR}.sh "$@"
	fi
fi

# Backward compat: old-style reg-uninstall.sh from pre-migration installs
if [ -s reg-uninstall.sh ]; then
	source reg-uninstall.sh

	if ask "Uninstall the previously installed mirror registry on host $reg_host_to_del"; then
		reg_delete

		rm -rf "${regcreds_dir:?}/"*
		rm -f ./reg-uninstall.sh

		exit 0
	fi

	exit 1
fi

# Fallback: no state file found -- try to detect running containers
aba_warning \
	"No registry state found in $regcreds_dir/state.sh." \
	"Attempting to detect a running registry ..."

sleep 1

verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

if [ ! "$data_dir" ]; then
	if [ "$reg_ssh_key" ]; then data_dir='~'; else data_dir=~; fi
fi
if [ ! "$reg_ssh_user" ]; then reg_ssh_user=$(whoami); fi

# Determine vendor from mirror.conf (reg_vendor is set by normalize-mirror-conf)
vendor="${reg_vendor:-auto}"
[ "$vendor" = "auto" ] && vendor="quay"

ssh_conf_file=~/.aba/ssh.conf

# Enable interactive prompting, but respect -y flag if the user passed it
export ask=1

# Get container names (including stopped) from local or remote host
_is_remote=
_podman_ps=""
if [ "$reg_ssh_key" ]; then
	_is_remote=1
	_podman_ps=$(ssh -F $ssh_conf_file $reg_ssh_user@$reg_host "podman ps -a --format '{{.Names}}'" 2>/dev/null || true)
else
	_podman_ps=$(podman ps -a --format '{{.Names}}' 2>/dev/null || true)
fi

# Detect registry container or data directory based on vendor type
_found=
case "$vendor" in
	docker)
		reg_root=$data_dir/docker-reg
		echo "$_podman_ps" | grep -q "^registry$" && _found=1
		;;
	quay)
		reg_root=$data_dir/quay-install
		reg_root_opt="--quayRoot \"$reg_root\" --quayStorage \"$reg_root/quay-storage\" --sqliteStorage \"$reg_root/sqlite-storage\""
		echo "$_podman_ps" | grep -q "quay-app\|quay" && _found=1
		;;
esac

# Also check if registry data directory exists (container may be gone but data remains)
if [ ! "$_found" ]; then
	if [ "$_is_remote" ]; then
		ssh -F $ssh_conf_file $reg_ssh_user@$reg_host "[ -d '$reg_root' ]" 2>/dev/null && _found=1
	else
		[ -d "$reg_root" ] && _found=1
	fi
fi

if [ ! "$_found" ]; then
	aba_info "No $vendor registry detected (no container or data at $reg_root). Nothing to uninstall."
	exit 0
fi

_location="localhost"
[ "$_is_remote" ] && _location="$reg_ssh_user@$reg_host"

if ask "Detected $vendor registry on $_location (data: $reg_root). Uninstall this registry"; then
	if [ -d "$regcreds_dir" ]; then
		rm -rf "${regcreds_dir}.bk" && mv "$regcreds_dir" "${regcreds_dir}.bk"
	fi

	if [ "$_is_remote" ]; then
		_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"
		case "$vendor" in
			docker)
				aba_info "Removing Docker registry container and data on $reg_host ..."
				$_ssh "podman rm -f registry; sudo rm -rf $reg_root" || true
				;;
			quay)
				ensure_quay_registry
				cmd="eval ./mirror-registry uninstall -v --targetHostname $reg_host --targetUsername $reg_ssh_user --autoApprove -k \"$reg_ssh_key\" $reg_root_opt"
				aba_info "Running command: $cmd"
				$cmd || exit 1
				;;
		esac
	else
		case "$vendor" in
			docker)
				aba_info "Removing Docker registry container and data ..."
				podman rm -f registry || true
				[ -d "$reg_root" ] && $SUDO rm -rf "$reg_root"
				;;
			quay)
				ensure_quay_registry
				cmd="eval ./mirror-registry uninstall -v --autoApprove $reg_root_opt"
				aba_info "Running command: $cmd"
				$cmd || exit 1
				;;
		esac
	fi
else
	exit 1
fi

rm -rf "${regcreds_dir:?}/"*

aba_info_ok "Registry uninstall successful"
