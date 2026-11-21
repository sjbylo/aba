#!/usr/bin/env bash
# Test: starting_ip as a comma list of node IPs
# Covers: normalize_starting_ip, expand_starting_ips, and agent-config.yaml from
#         the real create-agent-config.sh (all 4 templates) for a list with a
#         prefix switch.
# Tier: unit (no network; uses its own scratch aba.conf, not the repo one)

cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=/dev/null
source scripts/include_all.sh noerr

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

# _expect DESC WANT CMD... -- WANT=FAIL expects a non-zero return
_expect() {
	local desc="$1" want="$2"
	shift 2
	local got rc=0
	got=$("$@" 2>/dev/null) || rc=$?
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
		_fail "$desc (want='$want' got='$got' rc=$rc)"
	fi
}

# _expect_err DESC TEXT CMD... -- command must fail and say TEXT on stderr
_expect_err() {
	local desc="$1" text="$2"
	shift 2
	local err rc=0
	err=$("$@" 2>&1 >/dev/null) || rc=$?
	if [ "$rc" -ne 0 ] && [[ "$err" == *"$text"* ]]; then
		_pass "$desc"
	else
		_fail "$desc (rc=$rc stderr='$err')"
	fi
}

echo "=== normalize_starting_ip ==="
_expect "list strips spaces" "10.0.0.10,11,12" normalize_starting_ip "10.0.0.10, 11 ,12"
_expect "trims spaces at the ends" "10.0.0.10,11" normalize_starting_ip "  10.0.0.10,11 "
_expect "reject space inside the first IP" FAIL normalize_starting_ip "10.0.0.1 2,13"
_expect "reject space inside a list item" FAIL normalize_starting_ip "10.0.0.10,1 1,12"
_expect "reject a second line" FAIL normalize_starting_ip $'10.0.0.10,11\n12'
_expect "list strips leading zeros" "10.0.0.10,11,10.0.1.6" normalize_starting_ip "10.0.0.010,011,10.0.1.06"
_expect "reject empty" FAIL normalize_starting_ip ""
_expect "reject bare octet first" FAIL normalize_starting_ip "10,11,12"
_expect "reject octet > 255" FAIL normalize_starting_ip "10.0.0.10,256"
_expect "reject trailing comma" FAIL normalize_starting_ip "10.0.0.10,11,"
_expect "reject leading comma" FAIL normalize_starting_ip ",10.0.0.10,11"
_expect "reject empty item" FAIL normalize_starting_ip "10.0.0.10,,12"
_expect "reject text item" FAIL normalize_starting_ip "10.0.0.10,abc"
_expect "reject 3-octet item" FAIL normalize_starting_ip "10.0.0.10,0.1.5"

echo
echo "=== expand_starting_ips ==="
_expect "full list" "10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.50 10.0.0.51 10.0.0.52" \
	expand_starting_ips "10.0.0.10,10.0.0.11,10.0.0.12,10.0.0.50,10.0.0.51,10.0.0.52" 6
_expect "short form" "10.0.0.10 10.0.0.11 10.0.0.12 10.0.0.50 10.0.0.51 10.0.0.52" \
	expand_starting_ips "10.0.0.10,11,12,10.0.0.50,51,52" 6
_expect "prefix switch" "10.0.0.10 10.0.0.11 10.0.0.12 10.0.1.60 10.0.1.61 10.0.1.62 10.0.1.63" \
	expand_starting_ips "10.0.0.10,11,12,10.0.1.60,61,62,63" 7
_expect "spaces in list" "10.0.0.10 10.0.0.11 10.0.0.12" \
	expand_starting_ips "10.0.0.10, 11, 12" 3
_expect "bad first item" FAIL expand_starting_ips "10,11,12" 3
_expect "octet > 255" FAIL expand_starting_ips "10.0.0.10,256,12" 3
_expect_err "count mismatch (5 for 6)" "lists 5 address(es) but the cluster has 6 node(s)" \
	expand_starting_ips "10.0.0.10,11,12,10.0.1.60,61" 6
_expect_err "count mismatch (7 for 6)" "lists 7 address(es) but the cluster has 6 node(s)" \
	expand_starting_ips "10.0.0.10,11,12,10.0.1.60,61,62,63" 6
_expect_err "duplicate address" "lists 10.0.0.11 more than once" \
	expand_starting_ips "10.0.0.10,11,10.0.0.11" 3
_expect_err "invalid syntax names the value" "starting_ip is invalid: [10.0.0.10,x]" \
	expand_starting_ips "10.0.0.10,x" 2

echo
echo "=== create-agent-config.sh writes listed IPs (all templates) ==="

# Runs the real scripts/create-agent-config.sh in a scratch cluster dir with its
# own minimal aba.conf.  verify_conf=conf keeps it offline; bare metal without
# macs.conf uses placeholder MACs, so nothing else needs a stub.
_want="master1=10.0.0.10 master2=10.0.0.11 master3=10.0.0.12 worker1=10.0.1.60 worker2=10.0.1.61 worker3=10.0.1.62"
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# _agent_config DIR PORTS VLAN -- print agent-config.yaml made by the real script
_agent_config() {
	local d="$1" ports="$2" vlan="$3"
	mkdir -p "$d"
	ln -s "$PWD/scripts" "$d/scripts"
	ln -s "$PWD/templates" "$d/templates"
	echo '{}' > "$d/pull-secret.json"
	printf 'verify_conf=conf\nplatform=bm\nocp_version=4.20.15\nocp_channel=stable\npull_secret_file=%s\n' \
		"$d/pull-secret.json" > "$d/aba.conf"
	touch "$d/mirror.conf"
	cat > "$d/cluster.conf" <<-EOF
	cluster_name=iplist
	base_domain=example.com
	machine_network=10.0.0.0/22
	starting_ip=10.0.0.10,11,12,10.0.1.60,61,62
	num_masters=3
	num_workers=3
	api_vip=10.0.0.20
	ingress_vip=10.0.0.21
	next_hop_address=10.0.0.1
	dns_servers=10.0.0.2
	hostPrefix=23
	master_prefix=master
	worker_prefix=worker
	ports=$ports
	vlan=$vlan
	EOF
	(cd "$d" && scripts/create-agent-config.sh </dev/null) > "$d/out.log" 2>&1 || return 1
	cat "$d/agent-config.yaml"
}

# Print "hostname=ip" for each host in the rendered agent-config
_host_ips() {
	awk '/- hostname:/ { h=$3 } /- ip:/ && h { printf "%s%s=%s", sep, h, $3; sep=" "; h="" }'
}

for _t in "agent-config.yaml.j2|ens160|" "agent-config-bond.yaml.j2|ens1f0,ens1f1|" \
	"agent-config-vlan.yaml.j2|ens160|100" "agent-config-vlan-bond.yaml.j2|ens1f0,ens1f1|100"; do
	IFS='|' read -r _tpl _ports _vlan <<< "$_t"
	_d="$_tmp/${_tpl%%.*}"
	if ! _out=$(_agent_config "$_d" "$_ports" "$_vlan"); then
		_fail "$_tpl: create-agent-config.sh failed: $(tail -3 "$_d/out.log")"
		continue
	fi
	# The script picks the template from ports/vlan; check the output has the
	# matching bond/vlan shape, so each variant really ran
	_shape=""
	echo "$_out" | grep -q 'type: bond' && _shape+="bond"
	echo "$_out" | grep -q 'type: vlan' && _shape+="vlan"
	case "$_tpl" in
		agent-config.yaml.j2)           _want_shape="" ;;
		agent-config-bond.yaml.j2)      _want_shape="bond" ;;
		agent-config-vlan.yaml.j2)      _want_shape="vlan" ;;
		agent-config-vlan-bond.yaml.j2) _want_shape="bondvlan" ;;
	esac
	if [ "$_shape" != "$_want_shape" ]; then
		_fail "$_tpl: output shape [$_shape], want [$_want_shape]"
		continue
	fi
	_got=$(echo "$_out" | _host_ips)
	_rv=$(echo "$_out" | awk '/^rendezvousIP:/ { print $2 }')
	if [ "$_got" = "$_want" ] && [ "$_rv" = "10.0.0.10" ]; then
		_pass "$_tpl: $_got, rendezvousIP $_rv"
	else
		_fail "$_tpl: want [$_want] rendezvous 10.0.0.10, got [$_got] rendezvous $_rv"
	fi
done

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
