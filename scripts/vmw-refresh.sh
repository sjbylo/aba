#!/bin/bash -e
# Refresh VMs: delete and re-create them, start them.

source scripts/include_all.sh

#[ "$1" = "1" -o "$1" = "true" ] && export DEBUG_ABA=1 && shift
aba_debug "Running: $0 $* at $(date) in dir: $PWD"

. <(process_args $*)

# Only prompt about deletion if VMs exist from a previous install.
# On fresh install, no VMs exist — just proceed to create.
if scripts/vmw-exists.sh; then
	ask "To re-start the installation, delete, re-create & start the VM(s)" || exit 0
	scripts/vmw-delete.sh || true
fi

scripts/vmw-create.sh --start --nomaccheck  # Do not re-check the mac addresses since we are re-creating the exact same VMs

