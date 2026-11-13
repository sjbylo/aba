#!/bin/bash
# Test: _pick_install_iface prefers cluster/lab NIC over default-route mgmt NIC
# Regression for: dual-homed bastion add-mirror writing 192.168.x → ImagePullBackOff
#
# Unit tier: uses real host routes when dual-homed; skips dual-home asserts otherwise.
# No root, no dnsmasq mutation.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== _pick_install_iface (unit) ==="

if ! declare -F _pick_install_iface >/dev/null; then
	_fail "_pick_install_iface not defined"
	echo "Results: $pass passed, $fail failed"
	exit 1
fi
_pass "helper defined"

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Isolate from the developer's aba.conf (CWD + ABA_CONF + ABA_ROOT).
_empty="$_tmp/empty.conf"
: > "$_empty"
cd "$_tmp"
unset ABA_ROOT machine_network prefix_length next_hop_address ABA_INSTALL_IFACE
export ABA_CONF="$_empty"

_def_ifc=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
_def_ip=$(ip -o -4 addr show dev "$_def_ifc" 2>/dev/null | awk '{print $4; exit}')
_def_ip=${_def_ip%/*}

# --- Default: no cluster hints → default-route iface ---
unset machine_network prefix_length next_hop_address ABA_INSTALL_IFACE
_got=$(_pick_install_iface 2>/dev/null || true)
if [[ -n "$_def_ifc" && "$_got" == "$_def_ifc" ]]; then
	_pass "no hints → default-route iface ($_got)"
else
	_fail "no hints → expected '$_def_ifc', got '${_got:-empty}'"
fi

# --- Override wins ---
if [[ -n "$_def_ifc" ]]; then
	export ABA_INSTALL_IFACE="$_def_ifc"
	_got=$(_pick_install_iface 2>/dev/null || true)
	if [[ "$_got" == "$_def_ifc" ]]; then
		_pass "ABA_INSTALL_IFACE override ($_got)"
	else
		_fail "ABA_INSTALL_IFACE=$_def_ifc → got '${_got:-empty}'"
	fi
	unset ABA_INSTALL_IFACE
fi

# --- next_hop: prefer iface that routes to the gateway ---
# Pick a non-default on-link address as synthetic "cluster GW" when dual-homed.
_lab_ifc=
_lab_gw=
while read -r _ifc _cidr; do
	[[ -n "$_ifc" && "$_ifc" != "lo" && "$_ifc" != "$_def_ifc" ]] || continue
	_ip=${_cidr%/*}
	_pfx=${_cidr#*/}
	[[ "$_pfx" =~ ^[0-9]+$ ]] || continue
	# network+1 as a stand-in next_hop on that subnet
	_ip_int=$(ip_to_int "$_ip")
	_mask=$(( 0xFFFFFFFF << (32 - _pfx) & 0xFFFFFFFF ))
	_net=$(( _ip_int & _mask ))
	_lab_gw=$(int_to_ip $(( _net + 1 )))
	_lab_ifc=$_ifc
	break
done < <(ip -o -4 addr show 2>/dev/null | awk '$2!="lo" {print $2,$4}')

if [[ -n "$_lab_ifc" && -n "$_lab_gw" && "$_lab_ifc" != "$_def_ifc" ]]; then
	export next_hop_address="$_lab_gw"
	unset machine_network prefix_length ABA_INSTALL_IFACE
	_got=$(_pick_install_iface 2>/dev/null || true)
	if [[ "$_got" == "$_lab_ifc" ]]; then
		_pass "next_hop=$_lab_gw → lab iface $_got (not default $_def_ifc)"
	else
		_fail "next_hop=$_lab_gw → expected '$_lab_ifc', got '${_got:-empty}' (default=$_def_ifc)"
	fi
	unset next_hop_address

	# machine_network alone (no next_hop): iface IP must fall in CIDR
	_lab_cidr=$(ip -o -4 addr show dev "$_lab_ifc" 2>/dev/null | awk '{print $4; exit}')
	_lab_pfx=${_lab_cidr#*/}
	_lab_addr=${_lab_cidr%/*}
	_lab_int=$(ip_to_int "$_lab_addr")
	_mask=$(( 0xFFFFFFFF << (32 - _lab_pfx) & 0xFFFFFFFF ))
	_lab_net=$(int_to_ip $(( _lab_int & _mask )))
	export machine_network="$_lab_net"
	export prefix_length="$_lab_pfx"
	unset next_hop_address ABA_INSTALL_IFACE
	_got=$(_pick_install_iface 2>/dev/null || true)
	if [[ "$_got" == "$_lab_ifc" ]]; then
		_pass "machine_network=$_lab_net/$_lab_pfx → lab iface $_got"
	else
		_fail "machine_network → expected '$_lab_ifc', got '${_got:-empty}'"
	fi
	unset machine_network prefix_length
else
	echo "  SKIP dual-home next_hop/machine_network (single usable iface or no alt NIC)"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
