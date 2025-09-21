#!/bin/bash -e
# Refresh VMs: delete and re-create them, start them.

source scripts/include_all.sh

. <(process_args $*)
# eval all key value args
###. <(echo $* | tr " " "\n")

# FIXME: [ "$1" ] && set -x  # Not really needed

ask "To (re)start the installation, delete, re-create & start the VM(s)" || exit 0

# If "n" to delete, then stop
scripts/vmw-delete.sh || true

# If only mastwrs should be started (masters=1) then do just that
#if [ "$masters" ]; then
#	scripts/vmw-create.sh --nomac
#	scripts/vmw-start.sh masters=1  # We only start masters, assuming the worker will be started by later by some other process
#else
	scripts/vmw-create.sh --start --nomac
#fi

