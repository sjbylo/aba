#!/bin/bash -e
# Refresh VMs: delete and re-create them on the KVM host

source scripts/include_all.sh

aba_debug "Running: $0 $* at $(date) in dir: $PWD"

. <(process_args "$@")

# Only prompt about deletion if VMs exist from a previous install.
# On fresh install, no VMs exist — just proceed to create.
if scripts/kvm-exists.sh; then
	ask "To re-start the installation, delete, re-create & start the VM(s)" || exit 0
	scripts/kvm-delete.sh || true
fi

scripts/kvm-create.sh --start --nomaccheck
