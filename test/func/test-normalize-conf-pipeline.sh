#!/bin/bash
# Tests for the normalize-*-conf() functions.
#
# Verifies:
#   - _normalize_export() sanitizer: comment stripping, whitespace, quoting
#   - normalize-aba-conf:    boolean flags, CIDR split, derived vars
#   - normalize-mirror-conf: data_dir masking, reg_path prefix, defaults
#   - normalize-cluster-conf: CIDR split, int_connection compat, defaults
#   - normalize-vmware-conf: ESXi/vCenter detection, VC_FOLDER
#   - normalize-kvm-conf:    KVM_HOST extraction
#   - The awk '{print $1}' bug (regression guard)
#   - suggest_starting_ip() helper (IP math)

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

source scripts/include_all.sh dummy_arg 2>/dev/null

# =========================================================================
# Helper: test normalize-aba-conf
# =========================================================================
_test_aba() {
	local test_name="$1" conf_content="$2" var_name="$3" expected="$4"

	local d="$_tmp/aba-$RANDOM"
	mkdir -p "$d"
	echo "$conf_content" > "$d/aba.conf"

	local actual
	actual=$(cd "$d" && eval "$(normalize-aba-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

# =========================================================================
# Helper: test normalize-mirror-conf
# =========================================================================
_test_mirror() {
	local test_name="$1" conf_line="$2" var_name="$3" expected="$4"

	local d="$_tmp/mirror-$RANDOM"
	mkdir -p "$d"

	cat > "$d/mirror.conf" <<-EOF
	reg_host=bastion.example.com
	reg_port=8443
	reg_vendor=docker
	$conf_line
	EOF

	local actual
	actual=$(cd "$d" && eval "$(normalize-mirror-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

# =========================================================================
# Helper: test normalize-cluster-conf
# =========================================================================
_test_cluster() {
	local test_name="$1" conf_content="$2" var_name="$3" expected="$4"

	local d="$_tmp/cluster-$RANDOM"
	mkdir -p "$d"
	echo "$conf_content" > "$d/cluster.conf"

	local actual
	actual=$(cd "$d" && eval "$(normalize-cluster-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

# =========================================================================
# Helper: test normalize-vmware-conf (mocks govc)
# =========================================================================
_mock_govc_vcenter="$_tmp/govc-vcenter"
cat > "$_mock_govc_vcenter" <<-'MOCK'
#!/bin/bash
if [[ "$1" == "about" ]]; then echo "API type: VirtualCenter"; fi
MOCK
chmod +x "$_mock_govc_vcenter"

_mock_govc_esxi="$_tmp/govc-esxi"
cat > "$_mock_govc_esxi" <<-'MOCK'
#!/bin/bash
if [[ "$1" == "about" ]]; then echo "API type: HostAgent"; fi
MOCK
chmod +x "$_mock_govc_esxi"

_test_vmware() {
	local test_name="$1" conf_content="$2" var_name="$3" expected="$4" mock="${5:-$_mock_govc_vcenter}"

	local d="$_tmp/vmw-$RANDOM"
	mkdir -p "$d"
	echo "$conf_content" > "$d/vmware.conf"

	# Inject mock govc into PATH — must be exported so the subshell inside
	# normalize-vmware-conf can find it too.
	local mock_dir
	mock_dir=$(mktemp -d "$_tmp/govc-bin-XXXX")
	cp "$mock" "$mock_dir/govc"

	local actual
	actual=$(cd "$d" && export PATH="$mock_dir:$PATH" && eval "$(normalize-vmware-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

# =========================================================================
# Helper: test normalize-kvm-conf
# =========================================================================
_test_kvm() {
	local test_name="$1" conf_content="$2" var_name="$3" expected="$4"

	local d="$_tmp/kvm-$RANDOM"
	mkdir -p "$d"
	echo "$conf_content" > "$d/kvm.conf"

	local actual
	actual=$(cd "$d" && eval "$(normalize-kvm-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

echo
echo "=== Testing: normalize-*-conf() functions ==="

# =========================================================================
echo
echo "--- _normalize_export: comment stripping and quoting ---"
# =========================================================================

_test_mirror "sanitize: full-line comment removed" \
	"# this is a comment" "reg_host" "bastion.example.com"

_test_mirror "sanitize: indented comment removed" \
	"   # indented comment" "reg_host" "bastion.example.com"

_test_mirror "sanitize: trailing comment stripped" \
	"reg_pw=hello   # a comment" "reg_pw" "hello"

_test_mirror "sanitize: trailing tab-comment stripped" \
	"$(printf 'reg_pw=hello\t\t# a comment')" "reg_pw" "hello"

_test_mirror "sanitize: single-quoted value with hash preserved" \
	"reg_pw='pass#word'" "reg_pw" "pass#word"

_test_mirror "sanitize: single-quoted value with space preserved" \
	"reg_pw='pass word'" "reg_pw" "pass word"

_test_mirror "sanitize: single-quoted value with space and hash" \
	"reg_pw='hello world #tag'" "reg_pw" "hello world #tag"

_test_mirror "sanitize: quoted value with trailing comment" \
	"reg_pw='p4ssw0rd'  # Registry password." "reg_pw" "p4ssw0rd"

_test_mirror "sanitize: special chars !@%^" \
	"reg_pw='p@ss!w%rd^'" "reg_pw" "p@ss!w%rd^"

_test_mirror "sanitize: leading whitespace stripped" \
	"   reg_pw=hello" "reg_pw" "hello"

# =========================================================================
echo
echo "--- normalize-aba-conf: boolean flag normalization ---"
# =========================================================================

_test_aba "aba: ask=0 -> empty" "ask=0" "ask" ""
_test_aba "aba: ask=1 -> true" "ask=1" "ask" "true"
_test_aba "aba: ask=false -> empty" "ask=false" "ask" ""
_test_aba "aba: ask=true stays true" "ask=true" "ask" "true"
_test_aba "aba: ask= stays empty" "ask=" "ask" ""

_test_aba "aba: excl_platform=0 -> empty" "excl_platform=0" "excl_platform" ""
_test_aba "aba: excl_platform=false -> empty" "excl_platform=false" "excl_platform" ""
_test_aba "aba: excl_platform=vmw stays vmw" "excl_platform=vmw" "excl_platform" "vmw"

_test_aba "aba: verify_conf=0 -> off" "verify_conf=0" "verify_conf" "off"
_test_aba "aba: verify_conf=1 -> all" "verify_conf=1" "verify_conf" "all"
_test_aba "aba: verify_conf=false -> off" "verify_conf=false" "verify_conf" "off"
_test_aba "aba: verify_conf=true -> all" "verify_conf=true" "verify_conf" "all"
_test_aba "aba: verify_conf=off stays off" "verify_conf=off" "verify_conf" "off"
_test_aba "aba: verify_conf=all stays all" "verify_conf=all" "verify_conf" "all"
_test_aba "aba: verify_conf unset -> defaults to all" "" "verify_conf" "all"

# =========================================================================
echo
echo "--- normalize-aba-conf: CIDR split and derived vars ---"
# =========================================================================

_test_aba "aba: machine_network CIDR -> IP" \
	"machine_network=10.0.1.0/24" "machine_network" "10.0.1.0"

_test_aba "aba: machine_network CIDR -> prefix_length" \
	"machine_network=10.0.1.0/24" "prefix_length" "24"

_test_aba "aba: machine_network no CIDR -> as-is" \
	"machine_network=10.0.1.0" "machine_network" "10.0.1.0"

_test_aba "aba: ocp_version=4.21.14" \
	"ocp_version=4.21.14" "ocp_version" "4.21.14"

_test_aba "aba: ocp_major derived from 4.21.14" \
	"ocp_version=4.21.14" "ocp_major" "4"

_test_aba "aba: ocp_major derived from 5.0.3" \
	"ocp_version=5.0.3" "ocp_major" "5"

_test_aba "aba: trailing comment on ocp_version" \
	"ocp_version=4.21.14		# OCP version" "ocp_version" "4.21.14"

_test_aba "aba: domain with dots" \
	"domain=example.com" "domain" "example.com"

# =========================================================================
echo
echo "--- normalize-aba-conf: empty/missing aba.conf ---"
# =========================================================================

_test_aba_missing() {
	local test_name="$1" var_name="$2" expected="$3"

	local d="$_tmp/aba-miss-$RANDOM"
	mkdir -p "$d"
	# No aba.conf at all

	local actual
	actual=$(cd "$d" && eval "$(normalize-aba-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

_test_aba_missing "aba: missing aba.conf -> ask=true" "ask" "true"

# =========================================================================
echo
echo "--- normalize-mirror-conf: data_dir masking ---"
# =========================================================================

_test_mirror "mirror: data_dir=~ -> literal tilde (not expanded)" \
	"data_dir=~" "data_dir" '~'

_test_mirror "mirror: data_dir= (empty) -> literal tilde" \
	"data_dir=" "data_dir" '~'

_test_mirror "mirror: data_dir=/custom/path stays" \
	"data_dir=/custom/path" "data_dir" "/custom/path"

_test_mirror "mirror: data_dir=~/mydata stays (has content after ~)" \
	"data_dir=~/mydata" "data_dir" "~/mydata"

# =========================================================================
echo
echo "--- normalize-mirror-conf: reg_path prefix ---"
# =========================================================================

_test_mirror "mirror: reg_path=mypath -> /mypath" \
	"reg_path=mypath" "reg_path" "/mypath"

_test_mirror "mirror: reg_path=/mypath stays" \
	"reg_path=/mypath" "reg_path" "/mypath"

_test_mirror "mirror: reg_path=/deep/path/here stays" \
	"reg_path=/deep/path/here" "reg_path" "/deep/path/here"

# =========================================================================
echo
echo "--- normalize-mirror-conf: defaults ---"
# =========================================================================

_test_mirror_default() {
	local test_name="$1" var_name="$2" expected="$3"

	local d="$_tmp/mirror-def-$RANDOM"
	mkdir -p "$d"
	# mirror.conf without reg_vendor
	cat > "$d/mirror.conf" <<-EOF
	reg_host=bastion.example.com
	reg_port=8443
	EOF

	local actual
	actual=$(cd "$d" && eval "$(normalize-mirror-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

_test_mirror_default "mirror: missing reg_vendor -> auto" "reg_vendor" "auto"

# =========================================================================
echo
echo "--- normalize-cluster-conf: CIDR split ---"
# =========================================================================

_test_cluster "cluster: machine_network CIDR -> IP" \
	"machine_network=10.0.1.0/24" "machine_network" "10.0.1.0"

_test_cluster "cluster: machine_network CIDR -> prefix_length" \
	"machine_network=10.0.1.0/24" "prefix_length" "24"

_test_cluster "cluster: machine_network /16 prefix" \
	"machine_network=172.16.0.0/16" "prefix_length" "16"

_test_cluster "cluster: machine_network no CIDR" \
	"machine_network=10.0.1.0" "machine_network" "10.0.1.0"

# =========================================================================
echo
echo "--- normalize-cluster-conf: int_connection backward compat ---"
# =========================================================================

_test_cluster "cluster: int_connection=none -> empty" \
	"int_connection=none" "int_connection" ""

_test_cluster "cluster: int_connection=proxy stays proxy" \
	"int_connection=proxy" "int_connection" "proxy"

_test_cluster "cluster: int_connection= stays empty" \
	"int_connection=" "int_connection" ""

# =========================================================================
echo
echo "--- normalize-cluster-conf: defaults ---"
# =========================================================================

_test_cluster_defaults() {
	local test_name="$1" var_name="$2" expected="$3"

	local d="$_tmp/cluster-def-$RANDOM"
	mkdir -p "$d"
	# Minimal cluster.conf — missing hostPrefix, port0, mirror_name
	echo "cluster_name=sno1" > "$d/cluster.conf"

	local actual
	actual=$(cd "$d" && eval "$(normalize-cluster-conf 2>/dev/null)" && eval "echo \$$var_name")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

_test_cluster_defaults "cluster: missing hostPrefix -> 23" "hostPrefix" "23"
_test_cluster_defaults "cluster: missing port0 -> eth0" "port0" "eth0"
_test_cluster_defaults "cluster: missing mirror_name -> mirror" "mirror_name" "mirror"

# =========================================================================
echo
echo "--- normalize-cluster-conf: simple values ---"
# =========================================================================

_test_cluster "cluster: simple cluster_name" \
	"cluster_name=sno1" "cluster_name" "sno1"

_test_cluster "cluster: trailing comment" \
	"cluster_name=sno1			# Set the cluster name." "cluster_name" "sno1"

_test_cluster "cluster: numworker numeric" \
	"numworker=3" "numworker" "3"

# =========================================================================
echo
echo "--- normalize-vmware-conf: vCenter mode ---"
# =========================================================================

_test_vmware "vmware: GOVC_URL simple" \
	"GOVC_URL=vcenter.example.com
GOVC_USERNAME=admin@vsphere.local
GOVC_PASSWORD=secret123" \
	"GOVC_URL" "vcenter.example.com"

_test_vmware "vmware: password with space" \
	"GOVC_URL=vcenter.example.com
GOVC_USERNAME=admin@vsphere.local
GOVC_PASSWORD='hello world'" \
	"GOVC_PASSWORD" "hello world"

_test_vmware "vmware: password with hash" \
	"GOVC_URL=vcenter.example.com
GOVC_USERNAME=admin@vsphere.local
GOVC_PASSWORD='PQa5iSjbbq#bfE8!'" \
	"GOVC_PASSWORD" "PQa5iSjbbq#bfE8!"

_test_vmware "vmware: password with trailing comment" \
	"GOVC_URL=vcenter.example.com
GOVC_USERNAME=admin@vsphere.local
GOVC_PASSWORD=secret123  # vCenter password" \
	"GOVC_PASSWORD" "secret123"

_test_vmware "vmware: VC_FOLDER preserved in vCenter mode" \
	"GOVC_URL=vcenter.example.com
GOVC_USERNAME=admin@vsphere.local
GOVC_PASSWORD=secret123
VC_FOLDER=/my-dc/vm/my-folder" \
	"VC_FOLDER" "/my-dc/vm/my-folder"

_test_vmware "vmware: VC=1 in vCenter mode" \
	"GOVC_URL=vcenter.example.com
GOVC_USERNAME=admin@vsphere.local
GOVC_PASSWORD=secret123" \
	"VC" "1"

# =========================================================================
echo
echo "--- normalize-vmware-conf: ESXi mode ---"
# =========================================================================

_test_vmware "vmware: ESXi -> VC_FOLDER=/ha-datacenter/vm" \
	"GOVC_URL=esxi1.example.com
GOVC_USERNAME=root
GOVC_PASSWORD=secret123" \
	"VC_FOLDER" "/ha-datacenter/vm" "$_mock_govc_esxi"

_test_vmware "vmware: ESXi -> VC is empty" \
	"GOVC_URL=esxi1.example.com
GOVC_USERNAME=root
GOVC_PASSWORD=secret123" \
	"VC" "" "$_mock_govc_esxi"

# =========================================================================
echo
echo "--- normalize-kvm-conf: KVM_HOST extraction ---"
# =========================================================================

_test_kvm "kvm: extract KVM_HOST from qemu+ssh URI" \
	"LIBVIRT_URI=qemu+ssh://user@kvm-host.example.com/system" \
	"KVM_HOST" "user@kvm-host.example.com"

_test_kvm "kvm: extract KVM_HOST from qemu+ssh IP" \
	"LIBVIRT_URI=qemu+ssh://root@192.168.1.100/system" \
	"KVM_HOST" "root@192.168.1.100"

_test_kvm "kvm: simple value preserved" \
	"LIBVIRT_URI=qemu+ssh://root@host/system
KVM_NETWORK=default" \
	"KVM_NETWORK" "default"

_test_kvm "kvm: value with trailing comment" \
	"LIBVIRT_URI=qemu+ssh://root@host/system
KVM_NETWORK=br0   # bridge network" \
	"KVM_NETWORK" "br0"

# =========================================================================
echo
echo "--- Trailing whitespace: no residue in output ---"
# =========================================================================

_test_no_trailing_ws() {
	local test_name="$1" conf_line="$2"

	local d="$_tmp/ws-$RANDOM"
	mkdir -p "$d"
	cat > "$d/mirror.conf" <<-EOF
	reg_host=bastion.example.com
	reg_port=8443
	reg_vendor=docker
	$conf_line
	EOF

	local output
	output=$(cd "$d" && normalize-mirror-conf 2>/dev/null)

	if echo "$output" | grep -qP '[ \t]$'; then
		test_fail "$test_name" "trailing whitespace found in normalize output"
	else
		test_pass "$test_name"
	fi
}

_test_no_trailing_ws "no trailing ws: tab-comment" \
	"$(printf 'reg_pw=hello\t\t# comment')"

_test_no_trailing_ws "no trailing ws: space-comment" \
	"reg_pw=hello   # comment"

_test_no_trailing_ws "no trailing ws: quoted value with comment" \
	"reg_pw='hello world'   # comment"

# =========================================================================
echo
echo "--- Regression: awk '{print \$1}' truncation bug (isolated proof) ---"
# =========================================================================

echo "  With awk (demonstrates the bug):"

actual_awk=$(echo "reg_pw='pass word'" | sed -E "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" | awk '{print $1}')
if [ "$actual_awk" = "reg_pw='pass" ]; then
	test_pass "awk: quoted value with space TRUNCATES (expected — this is the bug)"
else
	test_fail "awk: quoted value with space" "expected awk to truncate to [reg_pw='pass] but got [$actual_awk]"
fi

echo "  Without awk (the fix):"

actual_noawk=$(echo "reg_pw='pass word'" | sed -E "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" | sed "s/^/export /")
expected_noawk="export reg_pw='pass word'"
if [ "$actual_noawk" = "$expected_noawk" ]; then
	test_pass "no-awk: quoted value with space preserved"
else
	test_fail "no-awk: quoted value with space" "expected [$expected_noawk], got [$actual_noawk]"
fi

# =========================================================================
# suggest_starting_ip() tests
# =========================================================================
echo
echo "--- suggest_starting_ip() ---"

# Normal /20 network — offset 100 fits easily
result_sip=$(suggest_starting_ip 10.0.0.0 20)
expected_sip="10.0.0.100"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: /20 => .100"
else
	test_fail "suggest_starting_ip: /20 => .100" "expected [$expected_sip], got [$result_sip]"
fi

# Normal /24 network — offset 100 fits
result_sip=$(suggest_starting_ip 192.168.1.0 24)
expected_sip="192.168.1.100"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: /24 => .100"
else
	test_fail "suggest_starting_ip: /24 => .100" "expected [$expected_sip], got [$result_sip]"
fi

# /30 network — only 2 usable hosts, offset clamped to 75% => 1
result_sip=$(suggest_starting_ip 10.0.0.0 30)
expected_sip="10.0.0.1"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: /30 (tiny) => .1"
else
	test_fail "suggest_starting_ip: /30 (tiny) => .1" "expected [$expected_sip], got [$result_sip]"
fi

# /25 network — 126 usable hosts, offset 100 fits
result_sip=$(suggest_starting_ip 172.16.0.0 25)
expected_sip="172.16.0.100"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: /25 => .100"
else
	test_fail "suggest_starting_ip: /25 => .100" "expected [$expected_sip], got [$result_sip]"
fi

# /26 network — 62 usable hosts, offset clamped to 46 (62*3/4)
result_sip=$(suggest_starting_ip 10.0.0.0 26)
expected_sip="10.0.0.46"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: /26 (62 hosts) => .46"
else
	test_fail "suggest_starting_ip: /26 (62 hosts) => .46" "expected [$expected_sip], got [$result_sip]"
fi

# /16 network — 65534 hosts, offset 100 is fine
result_sip=$(suggest_starting_ip 10.1.0.0 16)
expected_sip="10.1.0.100"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: /16 => .100"
else
	test_fail "suggest_starting_ip: /16 => .100" "expected [$expected_sip], got [$result_sip]"
fi

# /31 and /32 — no usable hosts, should return error (exit 1)
if ! suggest_starting_ip 10.0.0.0 31 >/dev/null 2>&1; then
	test_pass "suggest_starting_ip: /31 returns error"
else
	test_fail "suggest_starting_ip: /31 returns error" "expected failure, got success"
fi

if ! suggest_starting_ip 10.0.0.0 32 >/dev/null 2>&1; then
	test_pass "suggest_starting_ip: /32 returns error"
else
	test_fail "suggest_starting_ip: /32 returns error" "expected failure, got success"
fi

# Non-zero base — verify offset is relative to network address
result_sip=$(suggest_starting_ip 10.10.5.0 24)
expected_sip="10.10.5.100"
if [ "$result_sip" = "$expected_sip" ]; then
	test_pass "suggest_starting_ip: non-zero base /24"
else
	test_fail "suggest_starting_ip: non-zero base /24" "expected [$expected_sip], got [$result_sip]"
fi

# =========================================================================
echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
