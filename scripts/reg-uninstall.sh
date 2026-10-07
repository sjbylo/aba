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
	if [ "$reg_vendor" = "existing" ]; then
		aba_abort \
			"This is an externally-managed registry (registered, not installed by ABA)." \
			"Use 'aba -d $(basename $PWD) unregister' to remove the local credentials." \
			"The registry itself will not be modified."
	fi

	# PLANs are emitted by _progress_plan-uninstall Makefile target (scripts/progress-plan.sh)

	if [ "$reg_ssh_key" ]; then
		exec scripts/reg-uninstall-${reg_vendor}-remote.sh "$@"
	else
		exec scripts/reg-uninstall-${reg_vendor}.sh "$@"
	fi
fi

# Backward compat: old-style reg-uninstall.sh from pre-migration installs
if [ -s reg-uninstall.sh ]; then
	source reg-uninstall.sh

	if ask -n --auto-yes "Uninstall the previously installed mirror registry on host $reg_host_to_del"; then
		reg_delete

		rm -rf "${regcreds_dir:?}/"*
		rm -f ./reg-uninstall.sh

		exit 0
	fi

	exit 1
fi

# Fallback: no state file found -- try to detect running containers
source scripts/reg-common.sh

aba_warn \
	"No registry state found in $regcreds_dir/state.sh." \
	"Attempting to detect a running registry ..."

sleep 1

verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

if [ ! "$reg_ssh_user" ]; then reg_ssh_user=$(whoami); fi

# Resolve vendor (handles "auto" → quay/docker based on architecture)
vendor="$(resolved_reg_vendor)"

# Set up reg_root and reg_root_opts correctly for the resolved vendor
reg_setup_data_dir "$vendor"

ssh_conf_file=~/.aba/ssh.conf

# Enable interactive prompting, but respect -y flag if the user passed it
export ask=1

# Get container names (including stopped) from local or remote host
_is_remote=
_podman_ps=""
if [ "$reg_ssh_key" ]; then
	_is_remote=1
	if ! _podman_ps=$(ssh -F $ssh_conf_file $reg_ssh_user@$reg_host "podman ps -a --format '{{.Names}}'" 2>&1); then
		aba_abort "Cannot reach registry host $reg_host via SSH. Check connectivity and SSH key.\n  Output: $_podman_ps"
	fi
else
	_podman_ps=$(podman ps -a --format '{{.Names}}' 2>/dev/null || true)
fi

# Detect registry container or data directory based on vendor type
_found=
case "$vendor" in
	docker)
		echo "$_podman_ps" | grep -q "^registry$" && _found=1
		;;
	quay)
		echo "$_podman_ps" | grep -q "quay-app\|quay" && _found=1
		;;
	$_QUAY_NG_VENDOR)
		echo "$_podman_ps" | grep -q "^systemd-quay$" && _found=1
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

if ask -n --auto-yes "Detected $vendor registry on $_location (data: $reg_root). Uninstall this registry"; then
	if [ "$_is_remote" ]; then
		_ssh="ssh -i $reg_ssh_key -F $ssh_conf_file $reg_ssh_user@$reg_host"
		case "$vendor" in
			docker)           reg_docker_remove "$_ssh" ;;
			quay)             reg_quay_remove "$_ssh" ;;
			$_QUAY_NG_VENDOR) reg_quay_ng_remove "$_ssh" ;;
			*)                aba_abort "Unknown registry vendor: $vendor" ;;
		esac
		reg_close_firewall --ssh
	else
		case "$vendor" in
			docker)           reg_docker_remove ;;
			quay)             reg_quay_remove ;;
			$_QUAY_NG_VENDOR) reg_quay_ng_remove ;;
			*)                aba_abort "Unknown registry vendor: $vendor" ;;
		esac
		reg_close_firewall
	fi
else
	exit 1
fi

# Back up credentials (after successful uninstall) then clear them
if [ -d "$regcreds_dir" ]; then
	rm -rf "${regcreds_dir}.bk" && mv "$regcreds_dir" "${regcreds_dir}.bk"
else
	rm -rf "${regcreds_dir:?}/"*
fi

# Invalidate cached mirror-verify result so TUI doesn't show stale "mirror ready"
aba_mirror_verify_refresh

aba_success "Registry uninstall successful"
