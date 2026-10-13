#!/bin/bash
# Replica counts and MAC lists: full layouts, short lists, empty lists, and a count of 0.
# Runs cluster-config.sh on temp yaml only.

set -eo pipefail

cd "$(dirname "$0")/../.."
root=$(pwd)
unset ABA_TRACE_FILE

fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

newdir() {
	local d=$1
	mkdir -p "$d"
	ln -s "$root/scripts" "$d/scripts"
}

write_install() {
	local dir=$1 cp=$2 wkr=$3
	{
		echo "metadata:"
		echo "  name: testcluster"
		echo "baseDomain: example.com"
		if [ "$cp" = missing ]; then
			echo "controlPlane: {}"
		else
			echo "controlPlane:"
			echo "  replicas: $cp"
		fi
		if [ "$wkr" = missing ]; then
			echo "compute: []"
		else
			echo "compute:"
			echo "- replicas: $wkr"
		fi
	} > "$dir/install-config.yaml"
}

start_agent() {
	local dir=$1
	cat > "$dir/agent-config.yaml" <<'EOF'
rendezvousIP: 10.0.1.10
hosts:
EOF
}

add_host() {
	local dir=$1 role=$2 host=$3 ip=$4
	shift 4
	{
		printf -- '- hostname: %s\n' "$host"
		printf '  role: %s\n' "$role"
		if [ $# -eq 0 ]; then
			printf '  interfaces: []\n'
		else
			printf '  interfaces:\n'
			local mac
			for mac in "$@"; do
				printf '  - macAddress: %s\n' "$mac"
			done
		fi
		printf '  networkConfig:\n'
		printf '    interfaces:\n'
		printf '    - ipv4:\n'
		printf '        address:\n'
		printf '        - ip: %s\n' "$ip"
	} >> "$dir/agent-config.yaml"
}

run_dir() {
	local d=$1
	rc=0
	out=$(cd "$d" && ./scripts/cluster-config.sh 2>&1) || rc=$?
}

has_line() { printf '%s\n' "$out" | grep -Fxq "$1"; }
has_text() { printf '%s\n' "$out" | grep -Fq "$1"; }

expect_ok() {
	local name=$1
	shift
	run_dir "$d/$name"
	if [ "$rc" != 0 ]; then
		bad "$name (rc=$rc)"
		printf '%s\n' "$out"
		return
	fi
	local line
	for line in "$@"; do
		if ! has_line "$line"; then
			bad "$name missing [$line]"
			printf '%s\n' "$out"
			return
		fi
	done
	pass "$name"
}

expect_abort() {
	local name=$1 needle=$2
	shift 2
	run_dir "$d/$name"
	if [ "$rc" = 0 ] || ! has_text "$needle"; then
		bad "$name (rc=$rc)"
		printf '%s\n' "$out"
		return
	fi
	local line
	for line in "$@"; do
		if ! has_text "$line"; then
			bad "$name missing [$line]"
			printf '%s\n' "$out"
			return
		fi
	done
	pass "$name"
}

# Three masters, one address each. Extra args are more macs for master 1, 2, 3.
masters_1nic() {
	local dir=$1
	shift
	start_agent "$dir"
	add_host "$dir" master m1 10.0.1.11 ${1:-a1}
	add_host "$dir" master m2 10.0.1.12 ${2:-b1}
	add_host "$dir" master m3 10.0.1.13 ${3:-c1}
}

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT

# --- control plane, no workers ---

newdir "$d/cp-2nic"
write_install "$d/cp-2nic" 3 0
start_agent "$d/cp-2nic"
add_host "$d/cp-2nic" master m1 10.0.1.11 a1 a2
add_host "$d/cp-2nic" master m2 10.0.1.12 b1 b2
add_host "$d/cp-2nic" master m3 10.0.1.13 c1 c2
expect_ok cp-2nic \
	'export PORTS_PER_NODE="2"' \
	'export CP_MAC_ADDR1="a1 b1 c1"' \
	'export CP_MAC_ADDR2="a2 b2 c2"'

newdir "$d/cp-1nic"
write_install "$d/cp-1nic" 3 0
masters_1nic "$d/cp-1nic"
expect_ok cp-1nic \
	'export PORTS_PER_NODE="1"' \
	'export CP_MAC_ADDR1="a1 b1 c1"'
run_dir "$d/cp-1nic"
if has_text 'CP_MAC_ADDR2'; then
	bad "cp-1nic emitted a second port"
	fail=1
else
	pass "cp-1nic has one port"
fi

newdir "$d/sno-1nic"
write_install "$d/sno-1nic" 1 0
start_agent "$d/sno-1nic"
add_host "$d/sno-1nic" master m1 10.0.1.11 a1
expect_ok sno-1nic \
	'export PORTS_PER_NODE="1"' \
	'export CP_MAC_ADDR1="a1"'

newdir "$d/sno-2nic"
write_install "$d/sno-2nic" 1 0
start_agent "$d/sno-2nic"
add_host "$d/sno-2nic" master m1 10.0.1.11 a1 a2
expect_ok sno-2nic \
	'export PORTS_PER_NODE="2"' \
	'export CP_MAC_ADDR1="a1"' \
	'export CP_MAC_ADDR2="a2"'

newdir "$d/cp-short-2"
write_install "$d/cp-short-2" 3 0
start_agent "$d/cp-short-2"
add_host "$d/cp-short-2" master m1 10.0.1.11 a1
add_host "$d/cp-short-2" master m2 10.0.1.12 b1
add_host "$d/cp-short-2" master m3 10.0.1.13
expect_abort cp-short-2 "[ABA] Error: Too few MAC addresses (2) for 3 nodes"

newdir "$d/cp-short-1"
write_install "$d/cp-short-1" 3 0
start_agent "$d/cp-short-1"
add_host "$d/cp-short-1" master m1 10.0.1.11 a1
add_host "$d/cp-short-1" master m2 10.0.1.12
add_host "$d/cp-short-1" master m3 10.0.1.13
expect_abort cp-short-1 "[ABA] Error: Too few MAC addresses (1) for 3 nodes"

newdir "$d/cp-nomac"
write_install "$d/cp-nomac" 3 0
start_agent "$d/cp-nomac"
add_host "$d/cp-nomac" master m1 10.0.1.11
expect_abort cp-nomac "Control Plane mac addresses" \
	"[ABA] Error:"
run_dir "$d/cp-nomac"
if has_text "Too few MAC addresses"; then
	bad "cp-nomac reported too few"
else
	pass "cp-nomac is the missing-field message"
fi

newdir "$d/cp-missing"
write_install "$d/cp-missing" missing 0
masters_1nic "$d/cp-missing"
expect_abort cp-missing "Control Plane replica count" \
	"[ABA] Error:"
run_dir "$d/cp-missing"
if has_text "syntax error"; then
	bad "cp-missing hit expr"
else
	pass "cp-missing does not hit expr"
fi

newdir "$d/cp-zero"
write_install "$d/cp-zero" 0 0
masters_1nic "$d/cp-zero"
expect_abort cp-zero "[ABA] Error: Control Plane replica count .controlPlane.replicas must be at least 1"
run_dir "$d/cp-zero"
if has_text "division by zero"; then
	bad "cp-zero divided by zero"
else
	pass "cp-zero does not divide"
fi

# --- workers ---

newdir "$d/wkr-missing"
write_install "$d/wkr-missing" 3 missing
masters_1nic "$d/wkr-missing"
expect_abort wkr-missing "Worker replica count" \
	"[ABA] Error:"
run_dir "$d/wkr-missing"
if has_text "unary operator"; then
	bad "wkr-missing printed unary operator"
else
	pass "wkr-missing does not print unary operator"
fi

# Worker hosts are present, but the count is 0, so they are not read.
newdir "$d/wkr-count-0"
write_install "$d/wkr-count-0" 3 0
masters_1nic "$d/wkr-count-0"
add_host "$d/wkr-count-0" worker w1 10.0.1.21 w1
expect_ok wkr-count-0 'export CP_MAC_ADDR1="a1 b1 c1"'
run_dir "$d/wkr-count-0"
if has_text 'WKR_'; then
	bad "wkr-count-0 read worker hosts"
else
	pass "wkr-count-0 ignores worker hosts"
fi

newdir "$d/wkr-1nic"
write_install "$d/wkr-1nic" 3 2
masters_1nic "$d/wkr-1nic"
add_host "$d/wkr-1nic" worker w1 10.0.1.21 w1
add_host "$d/wkr-1nic" worker w2 10.0.1.22 w2
expect_ok wkr-1nic \
	'export CP_MAC_ADDR1="a1 b1 c1"' \
	'export WKR_MAC_ADDR1="w1 w2"'

newdir "$d/wkr-2nic"
write_install "$d/wkr-2nic" 3 2
masters_1nic "$d/wkr-2nic"
add_host "$d/wkr-2nic" worker w1 10.0.1.21 w1 x1
add_host "$d/wkr-2nic" worker w2 10.0.1.22 w2 x2
expect_ok wkr-2nic \
	'export WKR_MAC_ADDR1="w1 w2"' \
	'export WKR_MAC_ADDR2="x1 x2"'

# Short worker list is the call that reaches distribute_macs. Control plane is valid.
newdir "$d/wkr-short"
write_install "$d/wkr-short" 3 3
masters_1nic "$d/wkr-short"
add_host "$d/wkr-short" worker w1 10.0.1.21 w1
add_host "$d/wkr-short" worker w2 10.0.1.22 w2
add_host "$d/wkr-short" worker w3 10.0.1.23
expect_abort wkr-short "[ABA] Error: Too few MAC addresses (2) for 3 nodes" \
	'export CP_MAC_ADDR1="a1 b1 c1"'

newdir "$d/wkr-nomac"
write_install "$d/wkr-nomac" 3 2
masters_1nic "$d/wkr-nomac"
add_host "$d/wkr-nomac" worker w1 10.0.1.21
add_host "$d/wkr-nomac" worker w2 10.0.1.22
expect_abort wkr-nomac ".hosts[].role.worker.interfaces[].macAddress missing" \
	"[ABA] Error:"
run_dir "$d/wkr-nomac"
if has_text "Too few MAC addresses"; then
	bad "wkr-nomac reported too few"
else
	pass "wkr-nomac is the missing-field message"
fi

exit "$fail"
