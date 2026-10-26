#!/bin/bash
# Test: disk_hint and bond_mode parsing, precedence, YAML output, and validation
# Covers: _parse_disk_hint, _validate_bond_mode, _resolve_node_setting,
#         agent-config template rendering with rootDeviceHints and bond_mode

set -euo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== disk_hint / bond_mode Tests ==="

# ---------------------------------------------------------------------------
# _parse_disk_hint tests
# ---------------------------------------------------------------------------
echo ""
echo "--- _parse_disk_hint: path shorthand ---"

out=$(_parse_disk_hint "/dev/sda")
if echo "$out" | grep -q '"deviceName": "/dev/sda"'; then
	_pass "path shorthand /dev/sda"
else
	_fail "path shorthand /dev/sda: got $out"
fi

out=$(_parse_disk_hint "/dev/disk/by-id/wwn-0x5000")
if echo "$out" | grep -q '"deviceName": "/dev/disk/by-id/wwn-0x5000"'; then
	_pass "path shorthand by-id"
else
	_fail "path shorthand by-id: got $out"
fi

# Non-path value that doesn't start with a recognized key= → deviceName
out=$(_parse_disk_hint "sda")
if echo "$out" | grep -q '"deviceName": "sda"'; then
	_pass "unrecognized bare value → deviceName"
else
	_fail "unrecognized bare value: got $out"
fi

echo ""
echo "--- _parse_disk_hint: criteria ---"

out=$(_parse_disk_hint "path=/dev/sda,minSizeGigabytes=200")
if echo "$out" | grep -q '"deviceName": "/dev/sda"' && echo "$out" | grep -q '"minSizeGigabytes": 200'; then
	_pass "path + minSizeGigabytes criteria"
else
	_fail "path + minSizeGigabytes: got $out"
fi

out=$(_parse_disk_hint "model=Samsung,vendor=ATA")
if echo "$out" | grep -q '"model": "Samsung"' && echo "$out" | grep -q '"vendor": "ATA"'; then
	_pass "model + vendor criteria"
else
	_fail "model + vendor: got $out"
fi

out=$(_parse_disk_hint "rotational=true")
if echo "$out" | grep -q '"rotational": true'; then
	_pass "rotational boolean"
else
	_fail "rotational boolean: got $out"
fi

out=$(_parse_disk_hint "minSizeGigabytes=100,maxSizeGigabytes=500")
if echo "$out" | grep -q '"minSizeGigabytes": 100' && echo "$out" | grep -q '"maxSizeGigabytes": 500'; then
	_pass "size range criteria"
else
	_fail "size range: got $out"
fi

echo ""
echo "--- _parse_disk_hint: validation errors ---"

# badkey=foo: not a recognized key prefix → treated as deviceName path shorthand
out=$(_parse_disk_hint "badkey=foo" 2>/dev/null)
if echo "$out" | grep -q '"deviceName": "badkey=foo"'; then
	_pass "unrecognized key prefix → deviceName shorthand"
else
	_fail "unrecognized key prefix: got $out"
fi

# Unknown key within valid criteria (first key recognized, second not)
if _parse_disk_hint "path=/dev/sda,badkey=foo" 2>/dev/null; then
	_fail "should reject unknown key in criteria"
else
	_pass "rejects unknown key in criteria"
fi

if _parse_disk_hint "path=/dev/sda,deviceName=/dev/sdb" 2>/dev/null; then
	_fail "should reject path + deviceName"
else
	_pass "rejects path + deviceName conflict"
fi

if _parse_disk_hint "minSizeGigabytes=abc" 2>/dev/null; then
	_fail "should reject non-integer size"
else
	_pass "rejects non-integer minSizeGigabytes"
fi

if _parse_disk_hint "minSizeGigabytes=0" 2>/dev/null; then
	_fail "should reject zero size"
else
	_pass "rejects zero minSizeGigabytes"
fi

if _parse_disk_hint "rotational=yes" 2>/dev/null; then
	_fail "should reject non-boolean rotational"
else
	_pass "rejects non-boolean rotational"
fi

if _parse_disk_hint "model=Samsung,model=WDC" 2>/dev/null; then
	_fail "should reject duplicate key"
else
	_pass "rejects duplicate key"
fi

if _parse_disk_hint "" 2>/dev/null; then
	_fail "should reject empty string"
else
	_pass "rejects empty string"
fi

# ---------------------------------------------------------------------------
# _validate_bond_mode tests
# ---------------------------------------------------------------------------
echo ""
echo "--- _validate_bond_mode ---"

for mode in balance-rr active-backup balance-xor broadcast 802.3ad balance-tlb balance-alb; do
	if _validate_bond_mode "$mode" 2>/dev/null; then
		_pass "valid mode: $mode"
	else
		_fail "should accept mode: $mode"
	fi
done

if _validate_bond_mode "round-robin" 2>/dev/null; then
	_fail "should reject unknown mode 'round-robin'"
else
	_pass "rejects unknown mode 'round-robin'"
fi

# Empty is OK (means "not set")
if _validate_bond_mode "" 2>/dev/null; then
	_pass "empty mode accepted"
else
	_fail "empty mode should be accepted"
fi

# ---------------------------------------------------------------------------
# _resolve_node_setting tests
# ---------------------------------------------------------------------------
echo ""
echo "--- _resolve_node_setting: precedence ---"

# Global only
export disk_hint="/dev/sda"
unset disk_hint_master disk_hint_worker disk_hint_node_master1 2>/dev/null || true
out=$(_resolve_node_setting disk_hint master1 master)
if [ "$out" = "/dev/sda" ]; then
	_pass "global fallback"
else
	_fail "global fallback: expected /dev/sda, got '$out'"
fi

# Role override
export disk_hint_master="/dev/nvme0"
out=$(_resolve_node_setting disk_hint master1 master)
if [ "$out" = "/dev/nvme0" ]; then
	_pass "role override"
else
	_fail "role override: expected /dev/nvme0, got '$out'"
fi

# Node override
export disk_hint_node_master1="/dev/vda"
out=$(_resolve_node_setting disk_hint master1 master)
if [ "$out" = "/dev/vda" ]; then
	_pass "node override"
else
	_fail "node override: expected /dev/vda, got '$out'"
fi

# Worker inherits global when no role/node set
unset disk_hint_worker disk_hint_node_worker1 2>/dev/null || true
out=$(_resolve_node_setting disk_hint worker1 worker)
if [ "$out" = "/dev/sda" ]; then
	_pass "worker inherits global"
else
	_fail "worker inherits global: expected /dev/sda, got '$out'"
fi

# Empty all → empty result
unset disk_hint disk_hint_master disk_hint_worker disk_hint_node_master1 2>/dev/null || true
out=$(_resolve_node_setting disk_hint master1 master)
if [ -z "$out" ]; then
	_pass "all empty → empty result"
else
	_fail "all empty: expected empty, got '$out'"
fi

# Clean up
unset disk_hint disk_hint_master disk_hint_worker disk_hint_node_master1 disk_hint_node_worker1 2>/dev/null || true

# ---------------------------------------------------------------------------
# Template rendering: standard (no bond, no VLAN)
# ---------------------------------------------------------------------------
echo ""
echo "--- Template rendering: standard template ---"

# Regression: no disk_hint → no rootDeviceHints in output
out=$(
	cluster_name=testcluster \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=2 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens160" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12 10.0.1.13 10.0.1.14" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03 00:50:56:01:04 00:50:56:01:05" \
	json_disk_hints='{}' \
	json_bond_modes='{}' \
	scripts/j2 templates/agent-config.yaml.j2
)

if echo "$out" | grep -q 'rootDeviceHints'; then
	_fail "regression: rootDeviceHints present when disk_hint empty"
else
	_pass "regression: no rootDeviceHints when disk_hint empty"
fi

# With global disk_hint
out=$(
	cluster_name=testcluster \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens160" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03" \
	json_disk_hints='{"master1": {"deviceName": "/dev/sda"}, "master2": {"deviceName": "/dev/sda"}, "master3": {"deviceName": "/dev/sda"}}' \
	json_bond_modes='{}' \
	scripts/j2 templates/agent-config.yaml.j2
)

n_hints=$(printf '%s\n' "$out" | grep -c 'rootDeviceHints' || true)
n_dev=$(printf '%s\n' "$out" | grep -c 'deviceName: /dev/sda' || true)
if [ "$n_hints" -eq 3 ] && [ "$n_dev" -eq 3 ]; then
	_pass "3-master compact: rootDeviceHints on all nodes"
else
	_fail "3-master compact: expected 3 hints+devices, got hints=$n_hints devices=$n_dev"
fi

# Mixed per-node hints
out=$(
	cluster_name=testcluster \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=2 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens160" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12 10.0.1.13 10.0.1.14" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03 00:50:56:01:04 00:50:56:01:05" \
	json_disk_hints='{"master1": {"deviceName": "/dev/sda"}, "worker2": {"minSizeGigabytes": 200}}' \
	json_bond_modes='{}' \
	scripts/j2 templates/agent-config.yaml.j2
)

n_hints=$(printf '%s\n' "$out" | grep -c 'rootDeviceHints' || true)
if [ "$n_hints" -eq 2 ]; then
	_pass "mixed per-node: only 2 nodes get rootDeviceHints"
else
	_fail "mixed per-node: expected 2 hints, got $n_hints"
fi
if echo "$out" | grep -q 'minSizeGigabytes: 200'; then
	_pass "mixed per-node: worker2 has minSizeGigabytes"
else
	_fail "mixed per-node: missing minSizeGigabytes in output"
fi

# ---------------------------------------------------------------------------
# Template rendering: SNO uses cluster_name as hostname
# ---------------------------------------------------------------------------
echo ""
echo "--- Template rendering: SNO ---"

out=$(
	cluster_name=mysno \
	rendezvous_ip=10.0.1.10 \
	num_masters=1 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens160" \
	arr_ips="10.0.1.10" \
	arr_macs="00:50:56:01:01" \
	json_disk_hints='{"mysno": {"deviceName": "/dev/nvme0n1"}}' \
	json_bond_modes='{}' \
	scripts/j2 templates/agent-config.yaml.j2
)

if echo "$out" | grep -q 'hostname: mysno' && echo "$out" | grep -q 'deviceName: /dev/nvme0n1'; then
	_pass "SNO: cluster_name used as hostname key"
else
	_fail "SNO: hostname or deviceName mismatch"
	printf '%s\n' "$out" | grep -E 'hostname:|deviceName:|rootDeviceHints' || true
fi

# ---------------------------------------------------------------------------
# Template rendering: bond template with custom bond_mode
# ---------------------------------------------------------------------------
echo ""
echo "--- Template rendering: bond template ---"

# Default bond mode (empty json_bond_modes) → active-backup
out=$(
	cluster_name=bondtest \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens1f0 ens2f0" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03 00:50:56:01:04 00:50:56:01:05 00:50:56:01:06" \
	json_disk_hints='{}' \
	json_bond_modes='{}' \
	scripts/j2 templates/agent-config-bond.yaml.j2
)

n_ab=$(printf '%s\n' "$out" | grep -c 'mode: active-backup' || true)
if [ "$n_ab" -eq 3 ]; then
	_pass "bond default: all 3 nodes use active-backup"
else
	_fail "bond default: expected 3 active-backup, got $n_ab"
fi

# Custom bond mode for all nodes
out=$(
	cluster_name=bondtest \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens1f0 ens2f0" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03 00:50:56:01:04 00:50:56:01:05 00:50:56:01:06" \
	json_disk_hints='{}' \
	json_bond_modes='{"master1": "802.3ad", "master2": "802.3ad", "master3": "802.3ad"}' \
	scripts/j2 templates/agent-config-bond.yaml.j2
)

n_lacp=$(printf '%s\n' "$out" | grep -c 'mode: 802.3ad' || true)
if [ "$n_lacp" -eq 3 ]; then
	_pass "bond custom: all 3 nodes use 802.3ad"
else
	_fail "bond custom: expected 3 802.3ad, got $n_lacp"
fi

# Mixed bond modes (master1=802.3ad, rest default)
out=$(
	cluster_name=bondtest \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens1f0 ens2f0" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03 00:50:56:01:04 00:50:56:01:05 00:50:56:01:06" \
	json_disk_hints='{}' \
	json_bond_modes='{"master1": "802.3ad"}' \
	scripts/j2 templates/agent-config-bond.yaml.j2
)

n_lacp=$(printf '%s\n' "$out" | grep -c 'mode: 802.3ad' || true)
n_ab=$(printf '%s\n' "$out" | grep -c 'mode: active-backup' || true)
if [ "$n_lacp" -eq 1 ] && [ "$n_ab" -eq 2 ]; then
	_pass "bond mixed: 1 802.3ad + 2 active-backup"
else
	_fail "bond mixed: expected 1 lacp + 2 ab, got lacp=$n_lacp ab=$n_ab"
fi

# ---------------------------------------------------------------------------
# Template rendering: VLAN-bond template with bond_mode + disk_hint
# ---------------------------------------------------------------------------
echo ""
echo "--- Template rendering: VLAN-bond template ---"

out=$(
	cluster_name=vbtest \
	rendezvous_ip=10.0.1.10 \
	num_masters=3 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	vlan=100 \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens1f0 ens2f0" \
	arr_ips="10.0.1.10 10.0.1.11 10.0.1.12" \
	arr_macs="00:50:56:01:01 00:50:56:01:02 00:50:56:01:03 00:50:56:01:04 00:50:56:01:05 00:50:56:01:06" \
	json_disk_hints='{"master1": {"deviceName": "/dev/sda"}, "master2": {"model": "Samsung", "minSizeGigabytes": 500}}' \
	json_bond_modes='{"master1": "balance-xor", "master2": "balance-xor", "master3": "balance-xor"}' \
	scripts/j2 templates/agent-config-vlan-bond.yaml.j2
)

n_bx=$(printf '%s\n' "$out" | grep -c 'mode: balance-xor' || true)
n_hints=$(printf '%s\n' "$out" | grep -c 'rootDeviceHints' || true)
if [ "$n_bx" -eq 3 ]; then
	_pass "vlan-bond: all 3 use balance-xor"
else
	_fail "vlan-bond: expected 3 balance-xor, got $n_bx"
fi
if [ "$n_hints" -eq 2 ]; then
	_pass "vlan-bond: 2 nodes have rootDeviceHints"
else
	_fail "vlan-bond: expected 2 hints, got $n_hints"
fi

# ---------------------------------------------------------------------------
# Template rendering: VLAN template (no bond)
# ---------------------------------------------------------------------------
echo ""
echo "--- Template rendering: VLAN template ---"

out=$(
	cluster_name=vlantest \
	rendezvous_ip=10.0.1.10 \
	num_masters=1 \
	num_workers=0 \
	master_prefix=master \
	worker_prefix=worker \
	vlan=200 \
	prefix_length=24 \
	next_hop_address=10.0.0.1 \
	arr_ports="ens160" \
	arr_ips="10.0.1.10" \
	arr_macs="00:50:56:01:01" \
	json_disk_hints='{"vlantest": {"wwn": "0x5000c500deadbeef"}}' \
	json_bond_modes='{}' \
	scripts/j2 templates/agent-config-vlan.yaml.j2
)

if echo "$out" | grep -q 'hostname: vlantest' && echo "$out" | grep -q 'wwn: 0x5000c500deadbeef'; then
	_pass "vlan SNO: wwn hint rendered"
else
	_fail "vlan SNO: expected wwn hint"
	printf '%s\n' "$out" | grep -E 'hostname:|wwn:|rootDeviceHints' || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
