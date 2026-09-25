#!/bin/bash -e
# Refresh VMs: delete and re-create them on the KVM host

source scripts/include_all.sh

aba_debug "Running: $0 $* at $(date) in dir: $PWD"

. <(process_args "$@")

# Only prompt about deletion if VMs exist from a previous install.
# On fresh install, no VMs exist — just proceed to create.
# Exit 2 from kvm-exists = hypervisor unreachable — must abort, not skip.
# Capture via || so set -e / ERR trap do not treat "no VMs" (exit 1) as fatal.
_exists_rc=0
scripts/kvm-exists.sh || _exists_rc=$?
if [ $_exists_rc -eq 2 ]; then
	aba_abort "Cannot reach KVM host — refusing to refresh (existing VMs may still be running)"
elif [ $_exists_rc -eq 0 ]; then
	scripts/kvm-delete.sh || true
fi

rm -f .install-complete .autorefresh .auto-agent-up

scripts/kvm-create.sh --start --nomaccheck
