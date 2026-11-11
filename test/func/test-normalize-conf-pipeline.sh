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
_test_aba "aba: excl_platform=1 -> true" "excl_platform=1" "excl_platform" "true"
_test_aba "aba: excl_platform=true stays true" "excl_platform=true" "excl_platform" "true"
_test_aba "aba: excl_platform=vmw stays vmw" "excl_platform=vmw" "excl_platform" "vmw"
_test_aba "aba: excl_operators=0 -> empty" "excl_operators=0" "excl_operators" ""
_test_aba "aba: excl_operators=false -> empty" "excl_operators=false" "excl_operators" ""
_test_aba "aba: excl_operators=1 -> true" "excl_operators=1" "excl_operators" "true"
_test_aba "aba: excl_operators=true stays true" "excl_operators=true" "excl_operators" "true"
_test_aba "aba: excl_additional=0 -> empty" "excl_additional=0" "excl_additional" ""
_test_aba "aba: excl_additional=false -> empty" "excl_additional=false" "excl_additional" ""
_test_aba "aba: excl_additional=1 -> true" "excl_additional=1" "excl_additional" "true"
_test_aba "aba: excl_additional=true stays true" "excl_additional=true" "excl_additional" "true"

_test_aba "aba: verify_conf=0 -> off" "verify_conf=0" "verify_conf" "off"
_test_aba "aba: verify_conf=1 -> all" "verify_conf=1" "verify_conf" "all"
_test_aba "aba: verify_conf=false -> off" "verify_conf=false" "verify_conf" "off"
_test_aba "aba: verify_conf=true -> all" "verify_conf=true" "verify_conf" "all"
_test_aba "aba: verify_conf=off stays off" "verify_conf=off" "verify_conf" "off"
_test_aba "aba: verify_conf=all stays all" "verify_conf=all" "verify_conf" "all"
_test_aba "aba: verify_conf unset -> defaults to all" "" "verify_conf" "all"

# =========================================================================
echo
echo "--- normalize-aba-conf: CIDR left intact (split is apply_cidr_split) ---"
# =========================================================================

_test_aba "aba: machine_network CIDR stays a CIDR" \
	"machine_network=10.0.1.0/24" "machine_network" "10.0.1.0/24"

_test_aba "aba: machine_network CIDR does not set prefix_length" \
	"machine_network=10.0.1.0/24" "prefix_length" ""

_test_aba "aba: machine_network no CIDR -> as-is" \
	"machine_network=10.0.1.0" "machine_network" "10.0.1.0"

_test_aba "aba: ocp_version=4.21.14" \
	"ocp_version=4.21.14" "ocp_version" "4.21.14"

_test_aba "aba: ocp_major is not a normalize output" \
	"ocp_version=4.21.14" "ocp_major" ""

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
echo "--- resolved_reg_user: the registry user that reaches the install ---"
# =========================================================================

# reg_load_config() sources normalize-mirror-conf and then resolves reg_user, so
# the helper below mirrors those two steps. Resolving the value instead of the
# mirror.conf text is what makes the spelling of the assignment irrelevant.
_test_reg_user() {
	local test_name="$1" conf_line="$2" expected="$3"

	local d="$_tmp/reguser-$RANDOM"
	mkdir -p "$d"

	cat > "$d/mirror.conf" <<-EOF
	reg_host=bastion.example.com
	reg_port=8443
	reg_vendor=docker
	$conf_line
	EOF

	local actual
	actual=$(cd "$d" && unset reg_user && eval "$(normalize-mirror-conf 2>/dev/null)" 2>/dev/null; export reg_user=$(resolved_reg_user); printf '%s\n' "$reg_user")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

# A configured user is never replaced, however it is spelled.
_test_reg_user "reg_user: plain value"              "reg_user=myuser"                       "myuser"
_test_reg_user "reg_user: indented key"             "  reg_user=myuser"                     "myuser"
_test_reg_user "reg_user: export prefix"            "export reg_user=myuser"                "myuser"
_test_reg_user "reg_user: value with a comment"     "reg_user=myuser # comment"             "myuser"
_test_reg_user "reg_user: quoted, contains a space" 'reg_user="my user"'                    "my user"
_test_reg_user "reg_user: value that looks like a flag" "reg_user=-n"                            "-n"
_test_reg_user "reg_user: value -e survives"        "reg_user=-e"                           "-e"
_test_reg_user "reg_user: append is the only form"  "reg_user+=admin"                       "admin"
_test_reg_user "reg_user: empty then append"        "$(printf 'reg_user=\nreg_user+=admin')" "admin"
_test_reg_user "reg_user: last assignment wins"     "$(printf 'reg_user=\nreg_user=myuser')" "myuser"

# Every way of leaving it empty ends up at the default.
_test_reg_user "reg_user: empty"                    "reg_user="                             "init"
_test_reg_user "reg_user: absent"                   "# no reg_user here"                    "init"
_test_reg_user "reg_user: double-quoted empty"      'reg_user=""'                           "init"
_test_reg_user "reg_user: single-quoted empty"      "reg_user=''"                           "init"
_test_reg_user "reg_user: tab after ="              "$(printf 'reg_user=\tmyuser')"         "init"
_test_reg_user "reg_user: empty with a comment"     "reg_user= # comment"                   "init"
_test_reg_user "reg_user: export prefix, empty"     "export reg_user="                      "init"
_test_reg_user "reg_user: export prefix, quoted"    'export reg_user=""'                    "init"
_test_reg_user "reg_user: append with no value"     "reg_user+="                            "init"
_test_reg_user "reg_user: expands to nothing"       'reg_user="${nosuchvar:-}"'             "init"
_test_reg_user "reg_user: set then emptied"         "$(printf 'reg_user=myuser\nreg_user=')" "init"

# Installed state is resolved before this runs, so a recorded user still wins.
_test_reg_user_state() {
	local test_name="$1" conf_line="$2" state_line="$3" expected="$4"

	local name="reguser-state-$RANDOM"
	local d="$_tmp/$name"
	local h="$_tmp/home-$RANDOM"
	mkdir -p "$d" "$h/.aba/mirror/$name"

	cat > "$d/mirror.conf" <<-EOF
	reg_host=bastion.example.com
	reg_port=8443
	reg_vendor=docker
	$conf_line
	EOF

	echo "$state_line" > "$h/.aba/mirror/$name/state.sh"

	local actual
	actual=$(cd "$d" && export HOME="$h" && unset reg_user && eval "$(normalize-mirror-conf 2>/dev/null)" 2>/dev/null; export reg_user=$(resolved_reg_user); printf '%s\n' "$reg_user")

	if [ "$actual" = "$expected" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual]"
	fi
}

_test_reg_user_state "reg_user: installed user beats the default" \
	"reg_user=" "reg_user=stateuser" "stateuser"

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
echo "--- normalize-cluster-conf: CIDR left intact ---"
# =========================================================================

_test_cluster "cluster: machine_network CIDR stays a CIDR" \
	"machine_network=10.0.1.0/24" "machine_network" "10.0.1.0/24"

_test_cluster "cluster: machine_network CIDR does not set prefix_length" \
	"machine_network=10.0.1.0/24" "prefix_length" ""

_test_cluster "cluster: machine_network /16 stays a CIDR" \
	"machine_network=172.16.0.0/16" "machine_network" "172.16.0.0/16"

_test_cluster "cluster: machine_network no CIDR" \
	"machine_network=10.0.1.0" "machine_network" "10.0.1.0"

# =========================================================================
echo
echo "--- normalize-cluster-conf: image_source ---"
# =========================================================================

_test_cluster "cluster: image_source=mirror" \
	"image_source=mirror" "image_source" "mirror"

_test_cluster "cluster: image_source=direct" \
	"image_source=direct" "image_source" "direct"

_test_cluster "cluster: image_source=proxy" \
	"image_source=proxy" "image_source" "proxy"

_test_cluster "cluster: image_source=enclave1 (named mirror)" \
	"image_source=enclave1" "image_source" "enclave1"

# No backward compat for legacy int_connection or mirror_name — ABA does not
# support config migration.  Only image_source is tested.

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
_test_cluster_defaults "cluster: missing image_source -> mirror" "image_source" "mirror"

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
GOVC_PASSWORD='F4ke#Pass!w0rD'" \
	"GOVC_PASSWORD" "F4ke#Pass!w0rD"

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
echo "--- helpers: fetch_value, ocp_major_of, apply_cidr_split, cluster_type ---"
# =========================================================================

d="$_tmp/helpers"
mkdir -p "$d"
cat > "$d/aba.conf" <<'EOF'
# comment
ocp_version=5.0.3   # tip
ask=true
EOF
cat > "$d/cluster.conf" <<'EOF'
cluster_name=ocp   # name
num_masters=1
EOF

got=$(fetch_value ocp_version "$d/aba.conf") || got=FAIL
[ "$got" = "5.0.3" ] && test_pass "fetch_value strips comment" || test_fail "fetch_value strips comment" "got [$got]"

if ! fetch_value num_masters "$d/aba.conf" >/dev/null 2>&1; then
	test_pass "fetch_value missing key returns 1"
else
	test_fail "fetch_value missing key returns 1" "returned 0"
fi

got=$(fetch_value num_masters "$d/cluster.conf") || got=FAIL
[ "$got" = "1" ] && test_pass "fetch_value cluster.conf" || test_fail "fetch_value cluster.conf" "got [$got]"

got=$(ocp_major_of 4.21.14)
[ "$got" = "4" ] && test_pass "ocp_major_of 4.21.14" || test_fail "ocp_major_of 4.21.14" "got [$got]"
got=$(ocp_major_of 5.0.3)
[ "$got" = "5" ] && test_pass "ocp_major_of 5.0.3" || test_fail "ocp_major_of 5.0.3" "got [$got]"

machine_network=10.0.1.0/24
prefix_length=
apply_cidr_split
if [ "$machine_network" = "10.0.1.0" ] && [ "$prefix_length" = "24" ]; then
	test_pass "apply_cidr_split /24"
else
	test_fail "apply_cidr_split /24" "net=[$machine_network] prefix=[$prefix_length]"
fi

[ "$(cluster_type 1 0)" = "sno" ] && test_pass "cluster_type sno" || test_fail "cluster_type sno" "$(cluster_type 1 0)"
[ "$(cluster_type 3 0)" = "compact" ] && test_pass "cluster_type compact" || test_fail "cluster_type compact" "$(cluster_type 3 0)"
[ "$(cluster_type 3 2)" = "standard" ] && test_pass "cluster_type standard" || test_fail "cluster_type standard" "$(cluster_type 3 2)"

ask=true
unset ASK_OVERRIDE
if ask_is_on; then test_pass "ask_is_on when ask=true"; else test_fail "ask_is_on when ask=true" "off"; fi
ASK_OVERRIDE=1
if ask_is_on; then test_fail "ask_is_on with -y" "still on"; else test_pass "ask_is_on off under ASK_OVERRIDE"; fi
unset ASK_OVERRIDE

# =========================================================================
echo
echo "--- distribution key: template, normalize default, verify enum ---"
# =========================================================================

# Template: one line, same pattern as 'platform', placed with the other global keys
_n=$(grep -c -P '^distribution=ocp\t+# ' templates/aba.conf.j2 || true)
[ "$_n" = "1" ] && test_pass "template: one 'distribution=ocp' line with a comment" || test_fail "template: one 'distribution=ocp' line with a comment" "found [$_n]"
_pl=$(grep -n '^platform=' templates/aba.conf.j2 | head -1 | cut -d: -f1)
_dl=$(grep -n '^distribution=' templates/aba.conf.j2 | head -1 | cut -d: -f1)
_ol=$(grep -n '^op_sets=' templates/aba.conf.j2 | head -1 | cut -d: -f1)
if [ -n "$_pl" ] && [ -n "$_dl" ] && [ "$_dl" -gt "$_pl" ] && [ "$_dl" -lt "$_ol" ]; then
	test_pass "template: distribution sits after platform, before the optional keys"
else
	test_fail "template: distribution sits after platform, before the optional keys" "platform=$_pl distribution=$_dl op_sets=$_ol"
fi

# normalize-aba-conf emits only what the file holds: a missing / commented key adds no line (the
# output for an aba.conf from before this key existed is byte-identical to the previous release),
# every reader treats "no value" as ocp.
_n_expect_old=$'export ocp_version=4.22.1\nexport platform=bm\nexport ask=\nexport verify_conf=all'
_n_chk() {   # <label> <conf content> <expected stdout>
	local d="$_tmp/nout-$RANDOM" got
	mkdir -p "$d"; printf '%s\n' "$2" > "$d/aba.conf"
	got=$(cd "$d" && normalize-aba-conf 2>/dev/null)
	if [ "$got" = "$3" ]; then test_pass "$1"; else test_fail "$1" "got [$got]"; fi
}
_n_chk "distribution: absent -> output has no distribution line (unchanged)" $'ocp_version=4.22.1\nplatform=bm\nask=0' "$_n_expect_old"
_n_chk "distribution: commented key -> output unchanged"          $'ocp_version=4.22.1\nplatform=bm\nask=0\n#distribution=okd' "$_n_expect_old"
_n_chk "distribution: indented comment -> output unchanged"       $'ocp_version=4.22.1\nplatform=bm\nask=0\n   # distribution=okd' "$_n_expect_old"
_n_chk "distribution: okd present -> emitted as written"          $'ocp_version=4.22.1\nplatform=bm\nask=0\ndistribution=okd\t\t# x' "${_n_expect_old/export verify_conf=all/export distribution=okd
export verify_conf=all}"
_n_chk "distribution: empty value -> emitted as written (empty)"  $'ocp_version=4.22.1\nplatform=bm\nask=0\ndistribution=' "${_n_expect_old/export verify_conf=all/export distribution=
export verify_conf=all}"
# the "Existing values in aba.conf" table of the bundle message is fed by exactly this pipeline
_d="$_tmp/dist-table"; mkdir -p "$_d"; printf 'ocp_version=4.22.1\nplatform=bm\n' > "$_d/aba.conf"
_n=$(cd "$_d" && normalize-aba-conf 2>/dev/null | sed -e "s/^export //g" -e "/^pull_secret_file=.*/d" | grep -c 'distribution' || true)
[ "$_n" = "0" ] && test_pass "bundle value table: no distribution row for a conf without the key" || test_fail "bundle value table: no distribution row for a conf without the key" "got [$_n]"
# a conf with the key shows it
printf 'ocp_version=4.22.1\nplatform=bm\ndistribution=okd\n' > "$_d/aba.conf"
_n=$(cd "$_d" && normalize-aba-conf 2>/dev/null | sed -e "s/^export //g" | grep -c '^distribution=okd$' || true)
[ "$_n" = "1" ] && test_pass "bundle value table: distribution=okd row shown when set" || test_fail "bundle value table: distribution=okd row shown when set" "got [$_n]"

# variable after normalize: set only when the file sets it; the default is applied by the readers
_test_aba "distribution: absent -> variable not set by normalize"        "ocp_version=4.22.1" distribution ""
_test_aba "distribution: commented key -> variable not set by normalize" "#distribution=okd" distribution ""
_test_aba "distribution: ocp stays ocp"                "$(printf 'distribution=ocp\t\t# x')" distribution "ocp"
_test_aba "distribution: okd stays okd"                "$(printf 'distribution=okd\t\t# x')" distribution "okd"
_test_aba "distribution: unknown value passed through for verify" "distribution=foo" distribution "foo"
_test_dist() {   # <label> <conf content> <expected dist_of>
	local d="$_tmp/dof-$RANDOM" got
	mkdir -p "$d"; printf '%s\n' "$2" > "$d/aba.conf"
	got=$(cd "$d" && unset distribution && eval "$(normalize-aba-conf 2>/dev/null)" && dist_of)
	if [ "$got" = "$3" ]; then test_pass "$1"; else test_fail "$1" "dist_of=[$got] want [$3]"; fi
}
_test_dist "dist_of after normalize: key absent -> ocp"        "ocp_version=4.22.1" ocp
_test_dist "dist_of after normalize: commented key -> ocp"     "#distribution=okd" ocp
_test_dist "dist_of after normalize: indented comment -> ocp"  "   # distribution=okd" ocp
_test_dist "dist_of after normalize: empty value -> ocp"       "distribution=" ocp
_test_dist "dist_of after normalize: okd -> okd"               "distribution=okd" okd
_test_dist "dist_of after normalize: ocp -> ocp"               "distribution=ocp" ocp

# Exactly one export line for the key (no duplicate when present), none when absent
_d="$_tmp/dist-count"; mkdir -p "$_d"
printf 'ocp_version=4.22.1\ndistribution=okd\n' > "$_d/aba.conf"
_n=$(cd "$_d" && normalize-aba-conf 2>/dev/null | grep -c '^export distribution=' || true)
[ "$_n" = "1" ] && test_pass "distribution present: exactly one export line" || test_fail "distribution present: exactly one export line" "got [$_n]"
printf 'ocp_version=4.22.1\n' > "$_d/aba.conf"
_n=$(cd "$_d" && normalize-aba-conf 2>/dev/null | grep -c 'distribution' || true)
[ "$_n" = "0" ] && test_pass "distribution absent: no line mentions it" || test_fail "distribution absent: no line mentions it" "got [$_n]"
# Missing / empty aba.conf: the safe default output is unchanged
_got=$(cd "$_tmp" && mkdir -p noconf && cd noconf && normalize-aba-conf 2>/dev/null)
[ "$_got" = "ask=true" ] && test_pass "missing aba.conf: output still just ask=true" || test_fail "missing aba.conf: output still just ask=true" "got [$_got]"

# verify-aba-conf: enum next to platform; OKD version checked with the anchored predicate
_test_verify() {
	local test_name="$1" want_rc="$2" want_msg="$3" conf="$4"
	local d="$_tmp/verify-$RANDOM" rc out
	mkdir -p "$d"
	printf '%s\n' "$conf" > "$d/aba.conf"
	out=$(cd "$d" && eval "$(normalize-aba-conf 2>/dev/null)" && verify-aba-conf 2>&1 >/dev/null)
	rc=$?
	if [ "$rc" = "$want_rc" ] && { [ -z "$want_msg" ] || [[ "$out" == *"$want_msg"* ]]; }; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "rc=$rc (want $want_rc) msg=[$out]"
	fi
}
_base_conf="$(printf 'ocp_channel=stable\nocp_version=4.22.1\nplatform=bm\npull_secret_file=/x')"
_okd_conf_head="$(printf 'ocp_channel=stable\nplatform=bm\npull_secret_file=/x\ndistribution=okd')"
_test_verify "verify: no distribution key (default ocp) passes" 0 "" "$_base_conf"
_test_verify "verify: distribution=ocp passes"                  0 "" "$_base_conf"$'\n'"distribution=ocp"
_test_verify "verify: distribution given twice (okd then ocp) rejected" 1 "ambiguous" "$_base_conf"$'\n'"distribution=okd"$'\n'"distribution=ocp"
_test_verify "verify: distribution given twice (ocp then okd) rejected" 1 "ambiguous" "$_base_conf"$'\n'"distribution=ocp"$'\n'"distribution=okd"
_test_verify "verify: distribution given twice with the same value passes" 0 "" "$_base_conf"$'\n'"distribution=ocp"$'\n'"distribution=ocp"
_test_verify "verify: distribution with a leading space rejected" 1 "ambiguous" "$_base_conf"$'\n'"distribution= okd"
_test_verify "verify: distribution with trailing spaces passes" 0 "" "$_base_conf"$'\n'"distribution=ocp   "
_test_verify "verify: distribution that is only spaces counts as unset" 0 "" "$_base_conf"$'\n'"distribution=   "
_test_verify "verify: distribution=foo rejected"                1 "distribution incorrectly set" "$_base_conf"$'\n'"distribution=foo"
_test_verify "verify: distribution=OKD (case) rejected"         1 "distribution incorrectly set" "$_base_conf"$'\n'"distribution=OKD"
_test_verify "verify: distribution=okdx (suffix) rejected"      1 "distribution incorrectly set" "$_base_conf"$'\n'"distribution=okdx"
_test_verify "verify: distribution=xocp (prefix) rejected"      1 "distribution incorrectly set" "$_base_conf"$'\n'"distribution=xocp"
# verify-aba-conf called without normalize-aba-conf having set the variable: still ocp
_vd="$_tmp/verify-nonorm"; mkdir -p "$_vd"; printf 'ocp_channel=stable\nocp_version=4.22.1\nplatform=bm\npull_secret_file=/x\n' > "$_vd/aba.conf"
if (cd "$_vd" && unset distribution && ocp_channel=stable ocp_version=4.22.1 platform=bm pull_secret_file=/x verify_conf=all && verify-aba-conf >/dev/null 2>&1); then
	test_pass "verify: variable unset (no normalize) is treated as ocp"
else
	test_fail "verify: variable unset (no normalize) is treated as ocp"
fi
_test_verify "verify: distribution=okd + okd tag passes"        0 "" "$_okd_conf_head"$'\n'"ocp_version=4.21.0-okd-scos.11"
_test_verify "verify: distribution=okd + 5.x okd tag passes"    0 "" "$_okd_conf_head"$'\n'"ocp_version=5.0.0-okd-scos.5"
_test_verify "verify: okd + OCP-style version rejected"         1 "ocp_version" "$_okd_conf_head"$'\n'"ocp_version=4.22.1"
_test_verify "verify: okd + prefix-only match rejected (unanchored regex not used)" 1 "ocp_version" "$_okd_conf_head"$'\n'"ocp_version=4.21.0-okd-scos.11-extra"
_test_verify "verify: okd + channel fast rejected"              1 "ocp_channel" "$(printf 'ocp_channel=fast\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=4.21.0-okd-scos.11')"
_test_verify "verify: okd + channel eus rejected"               1 "ocp_channel" "$(printf 'ocp_channel=eus\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=4.21.0-okd-scos.11')"
_test_verify "verify: okd + channel candidate passes"           0 "" "$(printf 'ocp_channel=candidate\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=4.21.0-okd-scos.11')"
_test_verify "verify: okd + candidate + pre-release build passes"  0 "" "$(printf 'ocp_channel=candidate\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=5.1.0-okd-scos.ec.2')"
_test_verify "verify: okd + candidate + GA build passes"          0 "" "$(printf 'ocp_channel=candidate\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=5.0.0-okd-scos.5')"
_test_verify "verify: okd + stable + pre-release build rejected"   1 "ocp_version" "$(printf 'ocp_channel=stable\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=5.1.0-okd-scos.ec.2')"
_test_verify "verify: okd + candidate + malformed pre-release rejected" 1 "ocp_version" "$(printf 'ocp_channel=candidate\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=5.1.0-okd-scos.ec.2x')"
# OKD is installed on bm and kvm, x86_64 only: vmw and another architecture stop here with a clear message
_okd_plat() { printf 'ocp_channel=stable\nplatform=%s\npull_secret_file=/x\ndistribution=okd\nocp_version=4.21.0-okd-scos.11' "$1"; }
_test_verify "verify: okd + platform bm passes"                  0 "" "$(_okd_plat bm)"
_test_verify "verify: okd + platform kvm passes"                 0 "" "$(_okd_plat kvm)"
_test_verify "verify: okd + platform vmw rejected"               1 "platform [vmw] (VMware vSphere) is not supported for OKD" "$(_okd_plat vmw)"
_test_verify "verify: ocp + platform vmw unchanged (passes)"     0 "" "$(printf 'ocp_channel=stable\nplatform=vmw\npull_secret_file=/x\nocp_version=4.22.1')"
_test_verify "verify: ocp + platform vmw + distribution=ocp passes" 0 "" "$(printf 'ocp_channel=stable\nplatform=vmw\npull_secret_file=/x\nocp_version=4.22.1\ndistribution=ocp')"
_test_verify_arch() {   # <label> <ARCH> <want_rc> <want_msg> <conf>
	local d="$_tmp/verify-arch-$RANDOM" out rc; mkdir -p "$d"; printf '%s\n' "$5" > "$d/aba.conf"
	out=$(cd "$d" && eval "$(normalize-aba-conf 2>/dev/null)" && ARCH="$2" verify-aba-conf 2>&1 >/dev/null); rc=$?
	if [ "$rc" = "$3" ] && [[ "$out" == *"$4"* ]]; then test_pass "$1"; else test_fail "$1" "rc=$rc (want $3) msg=[$out]"; fi
}
_test_verify_arch "verify: okd on amd64 passes"                  amd64 0 "" "$(_okd_plat bm)"
_test_verify_arch "verify: okd on arm64 rejected"                arm64 1 "architecture [arm64] is not supported for OKD in ABA (x86_64 only)" "$(_okd_plat bm)"
_test_verify_arch "verify: okd on s390x rejected"                s390x 1 "architecture [s390x] is not supported for OKD" "$(_okd_plat kvm)"
_test_verify_arch "verify: okd on ppc64le rejected"              ppc64le 1 "architecture [ppc64le] is not supported for OKD" "$(_okd_plat bm)"
_test_verify_arch "verify: ocp on arm64 unchanged (passes)"      arm64 0 "" "$(printf 'ocp_channel=stable\nplatform=bm\npull_secret_file=/x\nocp_version=4.22.1')"
_test_verify "verify: okd + candidate + OCP pre-release rejected"  1 "ocp_version" "$(printf 'ocp_channel=candidate\nplatform=bm\npull_secret_file=/x\ndistribution=okd\nocp_version=5.1.0-ec.2')"
_test_verify "verify: ocp + fast channel still passes"          0 "" "$(printf 'ocp_channel=fast\nocp_version=4.22.1\nplatform=bm\npull_secret_file=/x')"
_test_verify "verify: ocp + 5.0.0-ec.2 still passes"            0 "" "$(printf 'ocp_channel=candidate\nocp_version=5.0.0-ec.2\nplatform=bm\npull_secret_file=/x')"

# =========================================================================
echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
