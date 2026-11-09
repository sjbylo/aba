#!/bin/bash -e
# bm-sim-boot.sh -- Boot a platform=bm cluster's agent ISO on a test VM (vSphere).
#
# INTENT:    BM install path skips HV create/upload/start. For lab BM simulation,
#            reuse the existing vmw-* scripts against the cluster dir so a VM
#            boots the already-built agent ISO without switching platform=vmw.
# CALLED BY: Developer / tester only — never by ABA runtime or Make.
# CWD:       Any; resolves cluster dir from arg or current directory.
# REQUIRES:  cluster.conf, vmware.conf, macs.conf (or mac_prefix),
#            iso-agent-based/agent.*.iso already built (`aba iso`).
# PRODUCES:  Datastore ISO images/agent-<cluster>.iso; cluster VMs created,
#            ISO attached, powered on.
# SIDE EFFECTS: Deletes existing cluster VMs if present (via vmw-refresh.sh).
#               Does NOT touch Make stamps (.iso-uploaded / .vms-ready) so the
#               BM install chain stays a no-op HV path.
# IDEMPOTENT: Yes (refresh deletes + recreates).
#
# Usage:
#   tools/bm-sim-boot.sh              # cluster dir = cwd
#   tools/bm-sim-boot.sh ocp          # path relative to ABA root or absolute
#   tools/bm-sim-boot.sh /path/to/ocp
#
# Then typically: aba -d <cluster> mon   (or continue the BM install flow)

usage() {
	sed -n '2,24p' "$0" | sed 's/^# \?//'
	exit "${1:-0}"
}

case "${1:-}" in
	-h|--help) usage 0 ;;
esac

ABA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve cluster directory
if [ -n "${1:-}" ]; then
	if [ -d "$1" ]; then
		CLUSTER_DIR="$(cd "$1" && pwd)"
	elif [ -d "$ABA_ROOT/$1" ]; then
		CLUSTER_DIR="$(cd "$ABA_ROOT/$1" && pwd)"
	else
		echo "Error: cluster directory not found: $1" >&2
		exit 1
	fi
else
	CLUSTER_DIR="$PWD"
fi

cd "$CLUSTER_DIR"

if [ ! -f cluster.conf ]; then
	echo "Error: not a cluster directory (no cluster.conf): $CLUSTER_DIR" >&2
	echo "Usage: tools/bm-sim-boot.sh [CLUSTER_DIR]" >&2
	exit 1
fi

if [ ! -s vmware.conf ]; then
	echo "Error: vmware.conf missing in $CLUSTER_DIR" >&2
	echo "Run 'aba -d $(basename "$CLUSTER_DIR") vmw' first (needed even for BM sim)." >&2
	exit 1
fi

ARCH=$(uname -m)
[ "$ARCH" = "amd64" ] && ARCH=x86_64
ISO="iso-agent-based/agent.${ARCH}.iso"
if [ ! -s "$ISO" ]; then
	echo "Error: ISO not found: $CLUSTER_DIR/$ISO" >&2
	echo "Run 'aba -d $(basename "$CLUSTER_DIR") iso' first." >&2
	exit 1
fi

# Cluster scripts/ is a symlink into the ABA tree; run from cluster CWD.
echo "[ABA] BM sim: upload ISO + create/start VMs in $CLUSTER_DIR"
echo "[ABA]   ISO: $ISO ($(du -h "$ISO" | awk '{print $1}'))"

scripts/vmw-upload.sh
scripts/vmw-refresh.sh

echo "[ABA] BM sim: VMs powered on with agent ISO attached."
echo "[ABA] Next: aba -d $(basename "$CLUSTER_DIR") mon"
