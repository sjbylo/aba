#!/bin/bash
# Uninstall Quay mirror registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.

[ -z "${INFO_ABA+x}" ] && export INFO_ABA=1

source scripts/include_all.sh
source scripts/reg-common.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")
export regcreds_display="regcreds"

# No verify-aba-conf — uninstall uses state.sh, not aba.conf values

if [ ! -s "$regcreds_dir/state.sh" ]; then
	aba_abort "No Quay registry state found in $regcreds_display/state.sh"
fi

source "$regcreds_dir/state.sh"

if ask "Uninstall Quay mirror registry on localhost, installed at $reg_host:$reg_port (root: $reg_root)"; then

	ensure_quay_registry

	# Check for existing "ansible_runner_instance" container
	podman ps -a | grep -q quay.io.*ansible_runner_instance && \
		aba_info "Removing stale ansible_runner_instance ..." && \
		podman stop ansible_runner_instance && podman rm ansible_runner_instance

	aba_info "Running command: ./mirror-registry uninstall -v --autoApprove $reg_root_opts"
	# $reg_root_opts is intentionally unquoted — it expands to multiple arguments.
	# shellcheck disable=SC2086
	./mirror-registry uninstall -v --autoApprove $reg_root_opts || exit 1

	reg_close_firewall

	# Post-uninstall assertions: verify Quay is fully gone on localhost.
	# mirror-registry uninstall uses Ansible which can silently skip steps.
	_stale=""
	[ -d "$reg_root" ] && _stale+="  reg_root ($reg_root) still exists"$'\n'
	ss -tlnp | grep -q ":${reg_port:-8443} " && _stale+="  Port ${reg_port:-8443} still listening"$'\n'
	podman ps -a --format '{{.Names}}' | grep -qE 'quay-app|quay-redis|quay-postgres' && _stale+="  Quay containers still present"$'\n'
	podman secret ls --format '{{.Name}}' | grep -q redis_pass && _stale+="  redis_pass podman secret still exists"$'\n'
	if [ -n "$_stale" ]; then
		aba_abort \
			"mirror-registry uninstall reported success but left stale state:" \
			"$_stale" \
			"Investigate why mirror-registry's Ansible playbook did not fully clean up."
	fi

	rm -rf "${regcreds_dir:?}/"*

	aba_info_ok "Quay registry uninstall successful"
	exit 0
fi

exit 1
