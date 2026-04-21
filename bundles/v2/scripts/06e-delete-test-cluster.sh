#!/bin/bash -e
# Phase 06e: Delete test cluster VMs (tests passed, no longer needed)
#
# Frees hypervisor resources before the large bundle upload to cloud/NAS.
# The cluster directory and its config files are preserved for 07-upload
# (it reads imageset-config.yaml from the mirror dir).

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

echo_step "Delete test cluster VMs (tests passed, freeing resources before upload) ..."

if [ -d "$WORK_TEST_INSTALL/aba/$CLUSTER_NAME" ]; then
	cd "$WORK_TEST_INSTALL/aba"
	aba --dir "$CLUSTER_NAME" delete
else
	echo "No cluster dir found at $WORK_TEST_INSTALL/aba/$CLUSTER_NAME -- nothing to delete"
fi
