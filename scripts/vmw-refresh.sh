#!/bin/bash -e
# Refresh VMs: delete and re-create them, start them.

source scripts/include_all.sh

#[ "$1" = "1" -o "$1" = "true" ] && export DEBUG_ABA=1 && shift
aba_debug "Running: $0 $* at $(date) in dir: $PWD"

. <(process_args "$@")

# Only prompt about deletion if VMs exist from a previous install.
# On fresh install, no VMs exist — just proceed to create.
# Exit 2 from vmw-exists = hypervisor unreachable — must abort, not skip.
# Capture via || so set -e / ERR trap do not treat "no VMs" (exit 1) as fatal.
_exists_rc=0
scripts/vmw-exists.sh || _exists_rc=$?
if [ $_exists_rc -eq 2 ]; then
	aba_abort "Cannot reach vCenter — refusing to refresh (existing VMs may still be running)"
elif [ $_exists_rc -eq 0 ]; then
	scripts/vmw-delete.sh || true
fi

rm -f .install-complete .vms-ready

scripts/vmw-create.sh --start --nomaccheck  # Do not re-check the mac addresses since we are re-creating the exact same VMs

aba_progress "DONE|ci_vms" || true
# vmw-create.sh --start already powered the VMs on. Close Boot nodes here so
# it does not sit at No-op until monitor starts. Bare metal uses bm-ask-boot.sh.
aba_progress "START|ci_boot" || true
aba_progress "DONE|ci_boot" || true

