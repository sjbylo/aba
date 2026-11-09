#!/usr/bin/env bash
# Test: Leading-zero stripping for integer / IPv4 / CIDR input
# Covers: normalize_uint, normalize_ipv4, normalize_cidr, TUI wrappers,
#         and aba CLI flags writing canonical values into cluster.conf.
# Tier: unit (no network)

cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=/dev/null
source scripts/include_all.sh noerr
# shellcheck source=/dev/null
source tui/v2/tui-lib.sh

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_expect() {
	local desc="$1" fn="$2" input="$3" want="$4"
	local got rc=0
	got=$("$fn" "$input") || rc=$?
	if [ "$want" = "FAIL" ]; then
		if [ "$rc" -ne 0 ]; then
			_pass "$desc"
		else
			_fail "$desc (expected fail, got '$got')"
		fi
		return
	fi
	if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
		_pass "$desc"
	else
		_fail "$desc (input='$input' want='$want' got='$got' rc=$rc)"
	fi
}

assert_conf() {
	local file="$1" key="$2" expected="$3"
	local actual
	actual=$(grep -E "^${key}=" "$file" | head -1 | sed 's/[[:space:]]*#.*//' | cut -d= -f2-)
	if [ "$actual" = "$expected" ]; then
		_pass "cluster.conf $key=$expected"
	else
		_fail "cluster.conf $key expected [$expected] got [$actual]"
	fi
}

echo "=== normalize_uint ==="
_expect "08 → 8" normalize_uint "08" "8"
_expect "008 → 8" normalize_uint "008" "8"
_expect "00 → 0" normalize_uint "00" "0"
_expect "0 → 0" normalize_uint "0" "0"
_expect "empty → empty" normalize_uint "" ""
_expect "plain 42" normalize_uint "42" "42"
_expect "reject 8a" normalize_uint "8a" "FAIL"
_expect "reject 8.0" normalize_uint "8.0" "FAIL"
_expect "reject -1" normalize_uint "-1" "FAIL"
_expect "long leading zeros" normalize_uint "00000000000000000008" "8"

echo
echo "=== normalize_ipv4 ==="
_expect "API VIP style .08" normalize_ipv4 "10.0.0.08" "10.0.0.8"
_expect "multi-octet zeros" normalize_ipv4 "010.00.01.008" "10.0.1.8"
_expect "already canonical" normalize_ipv4 "10.0.0.8" "10.0.0.8"
_expect "all zero" normalize_ipv4 "0.0.0.0" "0.0.0.0"
_expect "08.08.08.08" normalize_ipv4 "08.08.08.08" "8.8.8.8"
_expect "reject 256" normalize_ipv4 "10.0.0.256" "FAIL"
_expect "reject 3 octets" normalize_ipv4 "10.0.08" "FAIL"
_expect "reject empty" normalize_ipv4 "" "FAIL"
_expect "reject 4-digit octet" normalize_ipv4 "10.0.0.0255" "FAIL"
_expect "reject spaces" normalize_ipv4 "10.0.0.8 " "FAIL"

echo
echo "=== normalize_cidr ==="
_expect "addr+prefix zeros" normalize_cidr "010.0.0.0/08" "10.0.0.0/8"
_expect "canonical /24" normalize_cidr "10.0.0.0/24" "10.0.0.0/24"
_expect "VIP-in-network style" normalize_cidr "10.0.0.08/24" "10.0.0.8/24"
_expect "prefix /00 → /0" normalize_cidr "10.0.0.0/00" "10.0.0.0/0"
_expect "reject /33" normalize_cidr "10.0.0.0/33" "FAIL"
_expect "reject empty" normalize_cidr "" "FAIL"
_expect "reject no slash" normalize_cidr "10.0.0.0" "FAIL"

echo
echo "=== TUI wrappers ==="
_expect "_normalize_uint empty" _normalize_uint "" ""
_expect "_normalize_uint 08" _normalize_uint "08" "8"
_expect "_normalize_ip empty" _normalize_ip "" ""
_expect "_normalize_ip .08" _normalize_ip "10.0.0.08" "10.0.0.8"
_expect "_normalize_cidr empty" _normalize_cidr "" ""
_expect "_normalize_cidr zeros" _normalize_cidr "010.0.0.0/08" "10.0.0.0/8"
_expect "_normalize_ip_list" _normalize_ip_list "10.0.0.08, 010.0.1.09" "10.0.0.8,10.0.1.9"
_expect "_normalize_ip_or_host_list mixed" _normalize_ip_or_host_list "10.0.0.08,ntp.lab.local" "10.0.0.8,ntp.lab.local"
_expect "_normalize_ip_list reject host" _normalize_ip_list "ntp.lab.local" "FAIL"

echo
echo "=== validate_* accept leading zeros (normalize underneath) ==="
if validate_ip "10.0.0.08"; then _pass "validate_ip allows 10.0.0.08"; else _fail "validate_ip should allow 10.0.0.08"; fi
if validate_cidr "010.0.0.0/08"; then _pass "validate_cidr allows 010.0.0.0/08"; else _fail "validate_cidr should allow leading zeros"; fi
if _valid_ipv4 "10.0.0.08"; then _pass "_valid_ipv4 allows 10.0.0.08"; else _fail "_valid_ipv4 should allow 10.0.0.08"; fi

# ─── CLI: aba cluster flags must store canonical values ───────────────────────
echo
echo "=== CLI flag round-trip (aba cluster) ==="

CLUSTER_DIR="test-leadzero-$$"
cp -a aba.conf aba.conf.test-leadzero-bak
cleanup() {
	rm -rf "$CLUSTER_DIR"
	[ -f aba.conf.test-leadzero-bak ] && mv aba.conf.test-leadzero-bak aba.conf
}
trap cleanup EXIT

sed -i -E 's/^ask=.*/ask=false/' aba.conf

# Octets are at most 3 digits (IPv4); e.g. 0200 is rejected as a 4-digit octet.
if ! ./aba cluster -n "$CLUSTER_DIR" -t standard \
	--num-workers 08 \
	--vlan 0100 \
	--starting-ip 10.0.0.08 \
	--api-vip 010.000.000.200 \
	--ingress-vip 010.000.000.201 \
	--mcpu 08 \
	--mmem 016 \
	--wcpu 04 \
	--wmem 08 \
	--machine-network 010.0.0.0/024 \
	--dns 08.08.08.08 010.0.1.08 \
	--gateway 10.0.0.01 \
	--ntp 10.0.0.08 ntp.example.com \
	--step cluster.conf >/tmp/aba-leadzero-out.$$ 2>&1; then
	_fail "aba cluster with leading-zero flags failed: $(tail -5 /tmp/aba-leadzero-out.$$)"
else
	_pass "aba cluster accepted leading-zero flags"
fi
rm -f /tmp/aba-leadzero-out.$$

CONF="$CLUSTER_DIR/cluster.conf"
[ -f "$CONF" ] && _pass "cluster.conf created" || _fail "cluster.conf not created"

assert_conf "$CONF" num_workers "8"
assert_conf "$CONF" vlan "100"
assert_conf "$CONF" starting_ip "10.0.0.8"
assert_conf "$CONF" api_vip "10.0.0.200"
assert_conf "$CONF" ingress_vip "10.0.0.201"
assert_conf "$CONF" master_cpu_count "8"
assert_conf "$CONF" master_mem "16"
assert_conf "$CONF" worker_cpu_count "4"
assert_conf "$CONF" worker_mem "8"
assert_conf "$CONF" machine_network "10.0.0.0/24"
assert_conf "$CONF" dns_servers "8.8.8.8,10.0.1.8"
assert_conf "$CONF" next_hop_address "10.0.0.1"
assert_conf "$CONF" ntp_servers "10.0.0.8,ntp.example.com"

# Override path: re-run with more leading zeros
./aba cluster -n "$CLUSTER_DIR" \
	--num-workers 002 \
	--vlan 0050 \
	--api-vip 10.00.00.008 \
	--step cluster.conf >/dev/null 2>&1

assert_conf "$CONF" num_workers "2"
assert_conf "$CONF" vlan "50"
assert_conf "$CONF" api_vip "10.0.0.8"

# Reject invalid after normalize attempt
echo
echo "=== CLI rejects invalid numeric input ==="
if ./aba cluster -n "$CLUSTER_DIR" --api-vip 10.0.0.256 --step cluster.conf >/dev/null 2>&1; then
	_fail "should reject api_vip 10.0.0.256"
else
	_pass "rejects api_vip 10.0.0.256"
fi
# 4-digit octet is not valid IPv4 dotted notation
if ./aba cluster -n "$CLUSTER_DIR" --api-vip 10.0.0.0200 --step cluster.conf >/dev/null 2>&1; then
	_fail "should reject api_vip 10.0.0.0200 (4-digit octet)"
else
	_pass "rejects api_vip 10.0.0.0200 (4-digit octet)"
fi
if ./aba cluster -n "$CLUSTER_DIR" --vlan 9999 --step cluster.conf >/dev/null 2>&1; then
	_fail "should reject vlan 9999"
else
	_pass "rejects vlan 9999"
fi
if ./aba cluster -n "$CLUSTER_DIR" --machine-network 10.0.0.0/33 --step cluster.conf >/dev/null 2>&1; then
	_fail "should reject CIDR /33"
else
	_pass "rejects CIDR /33"
fi
if ./aba cluster -n "$CLUSTER_DIR" --num-workers abc --step cluster.conf >/dev/null 2>&1; then
	_fail "should reject num-workers abc"
else
	_pass "rejects num-workers abc"
fi

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
