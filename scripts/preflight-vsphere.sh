#!/bin/bash -e
# Run ONLY the vSphere preflight block (Layers 1-4) against a real vCenter.
# Skips the platform-agnostic checks (DNS, NTP, IP conflicts) that the full
# `make preflight` / `aba install` flow would run first.
#
# Usage:
#   cd <cluster-dir>
#   ../scripts/preflight-vsphere.sh
#
# OR from the aba root, passing the cluster dir:
#   scripts/preflight-vsphere.sh <cluster-dir>
#
# Exit code = number of errors reported by preflight_check_vsphere.
# Zero = all checks passed. Non-zero = at least one layer failed.

CLUSTER_DIR="${1:-.}"
if [ ! -d "$CLUSTER_DIR" ]; then
	echo "ERROR: cluster dir '$CLUSTER_DIR' not found" >&2
	exit 2
fi
cd "$CLUSTER_DIR"

if [ ! -f scripts/include_all.sh ]; then
	echo "ERROR: run from a cluster dir (scripts/ symlink not found in '$PWD')" >&2
	echo "       Generate one with: aba cluster -n <name> -t sno --step cluster.conf" >&2
	exit 2
fi

if [ ! -f vmware.conf ]; then
	echo "ERROR: vmware.conf not found in '$PWD'" >&2
	echo "       Copy your working vmware.conf into this cluster dir first." >&2
	exit 2
fi

# Disable set -e so individual layer failures don't abort the wrapper before
# we print the summary. preflight_check_vsphere tracks failures via counters.
set +e

source scripts/include_all.sh
source <(normalize-aba-conf)
source <(normalize-cluster-conf)

# Fresh counters (the full flow inherits these from preflight-check.sh; we're
# running standalone, so initialize them here).
_preflight_errors=0
_preflight_warnings=0

source scripts/preflight-check-vsphere.sh
preflight_check_vsphere

echo
echo "=== vSphere-only preflight summary ==="
echo "errors:   $_preflight_errors"
echo "warnings: $_preflight_warnings"

exit "$_preflight_errors"
