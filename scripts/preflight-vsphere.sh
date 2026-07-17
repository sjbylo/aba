#!/bin/bash -e
# Run ONLY the vSphere preflight block (Layers 1-4) against a real vCenter.
# Skips the platform-agnostic checks (DNS, NTP, IP conflicts) that the full
# `make preflight` / `aba install` flow would run first.
#
# Since the production flow now prints a visible OK line per passing probe
# and an informational footer when D-12 warnings fire, this wrapper is
# essentially a thin shell around preflight_check_vsphere that adds:
#   - Standalone setup (sources include_all.sh and normalisers)
#   - INFO_ABA=1 so the D-12 explanatory footer surfaces
#   - A terse summary block at the end
#
# Usage:
#   cd <cluster-dir>
#   ../scripts/preflight-vsphere.sh
#
# OR from the aba root:
#   scripts/preflight-vsphere.sh <cluster-dir>
#
# Exit code = number of errors reported by preflight_check_vsphere.
# Zero = all hard checks passed.

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

# Disable set -e so individual layer failures don't abort the wrapper
# before the summary. Counters carry the status.
set +e

source scripts/include_all.sh

# include_all.sh installs a 'trap show_error ERR' that calls exit on any
# non-zero. Preflight probes deliberately return non-zero as counter-bump
# signals (not fatal errors). Clear the trap so all layers run fully.
trap - ERR

# Surface aba_info lines too (the D-12 explanatory footer uses aba_info,
# which is gated behind INFO_ABA by default). aba_success is always visible.
export INFO_ABA=1

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

_preflight_errors=0
_preflight_warnings=0
_vsphere_d12_count=0

source scripts/preflight-check-vsphere.sh
preflight_check_vsphere

# --- Summary ---------------------------------------------------------------

# Colours only on a TTY so log captures stay plain ASCII.
if [ -t 1 ]; then
	_C_GREEN=$'\033[32m'
	_C_RED=$'\033[31m'
	_C_YEL=$'\033[33m'
	_C_OFF=$'\033[0m'
else
	_C_GREEN=""; _C_RED=""; _C_YEL=""; _C_OFF=""
fi

real_warnings=$(( _preflight_warnings - _vsphere_d12_count ))
[ "$real_warnings" -lt 0 ] && real_warnings=0

echo
echo "=============================================================="
echo " vSphere preflight summary"
echo "=============================================================="
printf " %-26s %s\n" "Errors (blocking):"            "$_preflight_errors"
printf " %-26s %s\n" "Real warnings:"                "$real_warnings"
printf " %-26s %s\n" "D-12 info (group-resolved):"   "$_vsphere_d12_count"
echo "=============================================================="

if [ "$_preflight_errors" -gt 0 ]; then
	echo "${_C_RED}RESULT: NOT READY${_C_OFF} - fix the errors above before 'aba install'."
elif [ "$real_warnings" -gt 0 ]; then
	echo "${_C_YEL}RESULT: REVIEW REQUIRED${_C_OFF} - real warnings were reported above."
else
	echo "${_C_GREEN}RESULT: OK${_C_OFF} - all hard checks passed; aba install will proceed."
fi

exit "$_preflight_errors"
