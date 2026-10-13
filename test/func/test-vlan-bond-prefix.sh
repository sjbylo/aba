#!/bin/bash
# VLAN bond agent config must use prefix_length from cluster.conf.
# Bug #1125: agent-config-vlan-bond.yaml.j2 hardcoded prefix-length 24.

set -euo pipefail

cd "$(dirname "$0")/../.."

out=$(
	cluster_name=bug1125 \
	rendezvous_ip=10.0.1.203 \
	num_masters=3 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	vlan=100 \
	prefix_length=20 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens1f0 ens1f1" \
	arr_ips="10.0.1.203 10.0.1.204 10.0.1.205" \
	arr_macs="00:50:56:01:00:01 00:50:56:01:00:02 00:50:56:01:00:03 00:50:56:01:00:04 00:50:56:01:00:05 00:50:56:01:00:06" \
	scripts/j2 templates/agent-config-vlan-bond.yaml.j2
)

n20=$(printf '%s\n' "$out" | grep -c 'prefix-length: 20' || true)
n24=$(printf '%s\n' "$out" | grep -c 'prefix-length: 24' || true)

if [ "$n20" -eq 3 ] && [ "$n24" -eq 0 ]; then
	echo "PASS: three nodes use prefix-length 20"
	exit 0
fi

echo "FAIL: expected 3 lines of prefix-length 20 and none of 24 (got 20=$n20 24=$n24)"
printf '%s\n' "$out" | grep 'prefix-length:'
exit 1
