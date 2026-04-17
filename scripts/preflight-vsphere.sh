#!/bin/bash -e
# Run ONLY the vSphere preflight block (Layers 1-4) against a real vCenter.
# Skips the platform-agnostic checks (DNS, NTP, IP conflicts) that the full
# `make preflight` / `aba install` flow would run first.
#
# Unlike `make preflight`, this wrapper enables DEBUG_ABA=1 so every probe
# (including successful ones) prints a line - so you see what passed, not
# just what failed. A categorised summary at the end explains each finding.
#
# Usage:
#   cd <cluster-dir>
#   ../scripts/preflight-vsphere.sh
#
# OR from the aba root, passing the cluster dir:
#   scripts/preflight-vsphere.sh <cluster-dir>
#
# Exit code = number of REAL errors reported by preflight_check_vsphere.
# Zero = all hard checks passed (warnings may still be present; see summary
# for whether they are informational or need action).

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

# Turn on the ABA debug channel so every layer's "ok" / "resolved" aba_debug
# line surfaces. The production flow keeps these silent (quiet-on-success
# convention), but as a diagnostic tool we WANT to see the green checks.
export DEBUG_ABA=1

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

# Capture run output so the summary can count the D-12 group-auth warnings
# separately from any real warnings.
_smoke_out=$(mktemp)
trap 'rm -f "$_smoke_out"' EXIT

source scripts/preflight-check-vsphere.sh
preflight_check_vsphere 2>&1 | tee "$_smoke_out"

# Count the D-12 "no role assigned / group assignments not resolved" warnings
# separately. These are INFORMATIONAL: they mean the user's effective privs
# come from AD/LDAP group membership that govc can't introspect - the install
# will still work IF the groups actually grant the required privileges.
d12_warnings=$(grep -c "D-12; group assignments not resolved" "$_smoke_out" || true)
real_warnings=$(( _preflight_warnings - d12_warnings ))

echo
echo "=============================================================="
echo " vSphere preflight summary"
echo "=============================================================="
printf "%-28s %s\n" "Errors (blocking):"            "$_preflight_errors"
printf "%-28s %s\n" "Real warnings:"                "$real_warnings"
printf "%-28s %s\n" "D-12 info warnings:"           "$d12_warnings"
echo

if [ "$_preflight_errors" -gt 0 ]; then
	echo "RESULT: NOT READY - fix the errors above before running 'aba install'."
elif [ "$real_warnings" -gt 0 ]; then
	echo "RESULT: REVIEW REQUIRED - real warnings were reported above."
else
	echo "RESULT: OK - all hard checks passed."
	if [ "$d12_warnings" -gt 0 ]; then
		echo
		echo "About the $d12_warnings D-12 warning(s):"
		echo "  These fire when 'govc permissions.ls' returns no DIRECT role"
		echo "  binding for your user on a given scope. On enterprise vCenter"
		echo "  that almost always means the user gets its privileges via AD"
		echo "  or LDAP group membership, which govc cannot expand. The"
		echo "  preflight therefore cannot pre-verify that those privileges"
		echo "  are sufficient - it is a GAP in coverage, not a failure. If"
		echo "  your groups actually grant the privileges listed in"
		echo "  scripts/vmware-required-privileges.sh, 'aba install' will"
		echo "  succeed; if they do not, the installer will fail later with"
		echo "  a clear privilege error."
	fi
fi

exit "$_preflight_errors"
