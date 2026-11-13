#!/bin/bash
# Delete a lab test cluster from conno or disco, whichever host has the directory.
#
# The TUI on one host cannot see a cluster that was created on the other.
# Both hosts share 10.0.1.201 for sno, so a VM left up on disco blocks a
# conno install even when conno has no ~/aba/sno.
#
# Usage: test/func/test-delete-sno.sh [cluster]
# Default cluster is sno. Run it directly. It is not part of run-all-tests.sh.
#
# Does not remove the cluster directory. aba delete powers the VMs off first.

set -o pipefail

cd "$(dirname "$0")/../.." || exit 1

cluster="${1:-sno}"
case "$cluster" in
	sno|sno2|sno3|sno4|compact|compact2|standard|ocp) ;;
	*)
		echo "Refusing unexpected cluster name: $cluster" >&2
		exit 1
		;;
esac

case "$cluster" in
	sno) ip=10.0.1.201 ;;
	sno2) ip=10.0.1.202 ;;
	sno3) ip=10.0.1.203 ;;
	sno4) ip=10.0.1.204 ;;
	compact) ip=10.0.1.71 ;;
	compact2) ip=10.0.1.91 ;;
	standard) ip=10.0.1.81 ;;
	ocp) ip=10.0.1.100 ;;
esac

ssh_cfg="$HOME/.aba/ssh.conf"
hosts="conno.example.com disco.example.com"
found=0
failed=0

for host in $hosts; do
	if ssh -F "$ssh_cfg" "$host" "test -d ~/aba/$cluster"; then
		echo "[$host] deleting ~/aba/$cluster"
		found=$(( found + 1 ))
		if ! ssh -F "$ssh_cfg" "$host" "cd ~/aba && aba -d $cluster delete --yes"; then
			echo "[$host] delete failed" >&2
			failed=$(( failed + 1 ))
		fi
	else
		echo "[$host] no ~/aba/$cluster"
	fi
done

echo "Waiting for $ip to stop answering..."
free=0
try=1
while [ "$try" -le 12 ]; do
	if ! ssh -F "$ssh_cfg" conno.example.com "arping -c 1 -w 2 $ip" 2>&1 | grep -qi reply; then
		free=1
		break
	fi
	echo "  $ip still in use ($try/12)"
	sleep 10
	try=$(( try + 1 ))
done

if [ "$failed" -ne 0 ]; then
	echo "Delete command failed on $failed host(s)." >&2
	exit 1
fi
if [ "$free" -ne 1 ]; then
	if [ "$found" -eq 0 ]; then
		echo "$ip is still in use, and neither host has ~/aba/$cluster." >&2
		echo "The VM was orphaned. Delete needs that directory on the host that created it." >&2
	else
		echo "$ip is still in use after delete." >&2
	fi
	exit 1
fi
if [ "$found" -eq 0 ]; then
	echo "No ~/aba/$cluster on conno or disco. $ip is already free."
else
	echo "$cluster deleted. $ip is free."
fi
exit 0
