#!/bin/bash -e
# Refresh VMs: delete and re-create them, start them.

source scripts/include_all.sh

[ "$1" ] && set -x

ask "Delete the VMs, then re-create & start them" || exit 0

# If "n" to delete, then stop
scripts/vmw-delete.sh || true

scripts/vmw-create.sh --start --nomac 

