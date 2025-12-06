#!/bin/bash -e
# Refresh VMs: delete and re-create them, start them.

source scripts/include_all.sh

#[ "$1" = "1" -o "$1" = "true" ] && export DEBUG_ABA=1 && shift
aba_debug "Running: $0 $* at $(date) in dir: $PWD"

. <(process_args $*)

ask "To (re)start the installation, delete, re-create & start the VM(s)" || exit 0

# If "n" to delete, then stop
scripts/vmw-delete.sh || true

scripts/vmw-create.sh --start --nomac

