#!/bin/bash
# Uninstall Quay mirror registry from localhost.
# Called by reg-uninstall.sh dispatcher; reads state from $regcreds_dir/state.sh.
#
# Idempotent: if probes show the registry is already fully gone, clear local
# state and succeed without calling mirror-registry uninstall. If uninstall
# fails but probes then show fully gone (e.g. Ansible fails because the
# service unit is already absent), treat as success. Leftover state still aborts.

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

if ask -n --auto-yes "Uninstall Quay mirror registry on localhost, installed at $reg_host:$reg_port (root: $reg_root)"; then

	_stale=$(reg_stale_report quay)
	if [ -z "$_stale" ]; then
		aba_info "Quay registry already gone on localhost -- clearing local state"
		reg_close_firewall
		reg_finish_uninstall "Quay" "already uninstalled"
		exit 0
	fi

	ensure_quay_registry

	# Check for existing "ansible_runner_instance" container
	podman ps -a | grep -q quay.io.*ansible_runner_instance && \
		aba_info "Removing stale ansible_runner_instance ..." && \
		podman stop ansible_runner_instance && podman rm ansible_runner_instance

	aba_info "Running command: ./mirror-registry uninstall -v --autoApprove $reg_root_opts"
	# $reg_root_opts is intentionally unquoted — it expands to multiple arguments.
	# shellcheck disable=SC2086
	_uninst_rc=0
	./mirror-registry uninstall -v --autoApprove $reg_root_opts || _uninst_rc=$?

	_stale=$(reg_stale_report quay)
	if [ -n "$_stale" ]; then
		if [ "$_uninst_rc" -ne 0 ]; then
			aba_abort \
				"mirror-registry uninstall failed (exit=$_uninst_rc) and left stale state:" \
				"$_stale" \
				"Investigate the uninstall failure above. Do not force-clean past an aba failure."
		fi
		aba_abort \
			"mirror-registry uninstall reported success but left stale state:" \
			"$_stale" \
			"Investigate why mirror-registry's Ansible playbook did not fully clean up."
	fi

	if [ "$_uninst_rc" -ne 0 ]; then
		aba_info "mirror-registry uninstall exited $_uninst_rc but registry is fully gone -- treating as success"
	fi

	reg_close_firewall
	reg_finish_uninstall "Quay" "uninstall successful"
	exit 0
fi

exit 1
