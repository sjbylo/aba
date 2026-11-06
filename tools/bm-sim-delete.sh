#!/bin/bash
# bm-sim-delete.sh -- Power off and destroy the vSphere VMs for a BM sim cluster.
#
# INTENT:    Companion to tools/bm-sim-boot.sh. The BM install path does not
#            create these VMs, so they are removed out of band.
# CALLED BY: Developer / tester, and the bm-mac-matrix suite. Never by Make.
# CWD:       Any.
# REQUIRES:  vmware.conf in the cluster dir, or ~/aba/vmware.conf / the repo
#            vmware.conf when only a cluster name is given. govc on PATH
#            or in ~/bin.
# PRODUCES:  Nothing. The named VMs and their vCenter folder are gone.
# SIDE EFFECTS: Does NOT touch Make stamps, the cluster directory, or DNS.
# IDEMPOTENT: Yes. Missing VMs are success.
#
# Usage:
#   tools/bm-sim-delete.sh                 # cluster dir = cwd
#   tools/bm-sim-delete.sh ocp             # dir, or a name if that dir is gone
#   tools/bm-sim-delete.sh /path/to/ocp

usage() {
	sed -n '2,18p' "$0" | sed 's/^# \?//'
	exit "${1:-0}"
}

case "${1:-}" in
	-h|--help) usage 0 ;;
esac

ABA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/bin:${PATH}"

CLUSTER_NAME=""
VMWARE_CONF=""

if [ -z "${1:-}" ]; then
	if [ -f cluster.conf ]; then
		CLUSTER_NAME="$(basename "$PWD")"
		VMWARE_CONF="$PWD/vmware.conf"
	else
		echo "Error: not a cluster directory (no cluster.conf)." >&2
		echo "Usage: tools/bm-sim-delete.sh [CLUSTER_DIR|CLUSTER_NAME]" >&2
		exit 1
	fi
elif [ -d "$1" ]; then
	CLUSTER_NAME="$(basename "$(cd "$1" && pwd)")"
	VMWARE_CONF="$(cd "$1" && pwd)/vmware.conf"
elif [ -d "$ABA_ROOT/$1" ]; then
	CLUSTER_NAME="$(basename "$1")"
	VMWARE_CONF="$ABA_ROOT/$1/vmware.conf"
else
	# Dir already removed. The name is enough to find the VMs.
	CLUSTER_NAME="$(basename "$1")"
	if [ -f "$ABA_ROOT/vmware.conf" ]; then
		VMWARE_CONF="$ABA_ROOT/vmware.conf"
	elif [ -f "${HOME}/aba/vmware.conf" ]; then
		VMWARE_CONF="${HOME}/aba/vmware.conf"
	fi
fi

if [ ! -s "$VMWARE_CONF" ]; then
	echo "Error: vmware.conf not found for $CLUSTER_NAME" >&2
	echo "Run 'aba vmw' first (needed even for BM sim)." >&2
	exit 1
fi

set -a
# shellcheck disable=SC1090
source "$VMWARE_CONF"
set +a

if ! command -v govc >/dev/null 2>&1; then
	echo "Error: govc not on PATH (looked in \$PATH and ~/bin)" >&2
	exit 1
fi

echo "[ABA] BM sim: delete VMs for $CLUSTER_NAME"

found=0
while IFS= read -r vm; do
	[ -n "$vm" ] || continue
	base=$(basename "$vm")
	case "$base" in
		"$CLUSTER_NAME"|"$CLUSTER_NAME"-*)
			found=1
			echo "[ABA] BM sim: power off $vm"
			govc vm.power -off -force "$vm" || true
			echo "[ABA] BM sim: destroy $vm"
			govc vm.destroy "$vm" || true
			;;
	esac
done < <(govc find / -type m 2>/dev/null || true)

if [ -n "${VC_FOLDER:-}" ]; then
	govc object.destroy "${VC_FOLDER}/${CLUSTER_NAME}" >/dev/null 2>&1 || true
fi

if [ "$found" -eq 0 ]; then
	echo "[ABA] BM sim: no VMs named ${CLUSTER_NAME} or ${CLUSTER_NAME}-*"
fi

echo "[ABA] BM sim: delete done for $CLUSTER_NAME"
exit 0
