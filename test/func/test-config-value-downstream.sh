#!/bin/bash
# Tests for how config values behave in DOWNSTREAM command patterns.
# Simulates the actual shell patterns found in ABA scripts to verify
# which special characters break when values flow into commands.
#
# This does NOT run real govc/oc/podman — it uses mock commands to capture
# what arguments the tool would actually receive.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass=0
fail=0
info=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }
test_info() { echo -e "${YELLOW}  INFO${NC}: $1"; info=$(( info + 1 )); }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Create a mock command that logs its argv to a file
_mock="$_tmp/mock-cmd"
_mock_log="$_tmp/mock-cmd.log"
cat > "$_mock" <<'MOCK'
#!/bin/bash
for arg in "$@"; do echo "$arg"; done
MOCK
chmod +x "$_mock"

echo
echo "=== Testing: downstream command patterns with special characters ==="
echo

# =========================================================================
echo "--- Pattern 1: eval \$cmd --initPassword \$reg_pw (reg-install-quay.sh:88) ---"
# This is the MOST dangerous pattern in the codebase.
# =========================================================================

_test_eval_unquoted() {
	local test_name="$1" password="$2" expect_fail="$3"

	# Simulate: cmd="./mirror-registry install --initUser admin"
	#           eval $cmd --initPassword $reg_pw
	local cmd="$_mock install --initUser admin"
	local reg_pw="$password"

	> "$_mock_log"
	local actual_pw=""
	local rc=0
	actual_pw=$(eval $cmd --initPassword $reg_pw 2>/dev/null | tail -1) || rc=$?

	if [ "$actual_pw" = "$password" ]; then
		if [ "$expect_fail" = "yes" ]; then
			test_fail "$test_name" "expected BROKEN but password survived eval: [$actual_pw]"
		else
			test_pass "$test_name"
		fi
	else
		if [ "$expect_fail" = "yes" ]; then
			test_pass "$test_name (confirmed broken: got [$actual_pw], rc=$rc)"
		else
			test_fail "$test_name" "expected [$password], got [$actual_pw]"
		fi
	fi
}

_test_eval_unquoted "eval: simple password" "s3cure123" "no"
_test_eval_unquoted "eval: password with space BREAKS" "pass word" "yes"
_test_eval_unquoted "eval: password with ; BREAKS (cmd injection)" "pass;echo INJECTED" "yes"
_test_eval_unquoted "eval: password with | BREAKS (pipe)" "pass|cat" "yes"
_test_eval_unquoted "eval: password with & BREAKS (background)" "pass&echo BG" "yes"
_test_eval_unquoted "eval: password with \$ BREAKS (expansion)" 'pass$HOME' "yes"
_test_eval_unquoted "eval: password with backtick BREAKS" 'pass`echo x`end' "yes"
_test_eval_unquoted "eval: password with # is OK (comment after)" "pass#word" "no"
_test_eval_unquoted "eval: password with ! is OK" "pass!word" "no"
_test_eval_unquoted "eval: password with @ is OK" "pass@word" "no"
_test_eval_unquoted "eval: password with % is OK" "pass%word" "no"

# =========================================================================
echo "--- Pattern 1b: \$cmd --initPassword \"\$reg_pw\" (proposed fix: no eval) ---"
# =========================================================================

_test_no_eval_quoted() {
	local test_name="$1" password="$2"

	local cmd="$_mock install --initUser admin"
	local reg_pw="$password"

	local actual_pw=""
	actual_pw=$($cmd --initPassword "$reg_pw" 2>/dev/null | tail -1) || true

	if [ "$actual_pw" = "$password" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$password], got [$actual_pw]"
	fi
}

_test_no_eval_quoted "no-eval: password with space" "pass word"
_test_no_eval_quoted "no-eval: password with ;" "pass;word"
_test_no_eval_quoted "no-eval: password with |" "pass|word"
_test_no_eval_quoted "no-eval: password with &" "pass&word"
_test_no_eval_quoted "no-eval: password with \$" 'pass$word'
_test_no_eval_quoted "no-eval: password with backtick" 'pass`word'
_test_no_eval_quoted "no-eval: password with #" "pass#word"
_test_no_eval_quoted "no-eval: password with %" "pass%word"
_test_no_eval_quoted "no-eval: password with !" "pass!word"
_test_no_eval_quoted "no-eval: password with @" "pass@word"

# =========================================================================
echo "--- Pattern 2: remote SSH export _reg_pw='\$reg_pw' (reg-install-remote.sh:119) ---"
# Simulates: ssh host "export _reg_pw='PASSWORD' && echo \$_reg_pw"
# =========================================================================

_test_ssh_export() {
	local test_name="$1" password="$2" expect_fail="$3"

	# Simulate what the remote shell sees
	local remote_script="export _reg_pw='$password' && echo \"\$_reg_pw\""
	local actual=""
	local rc=0
	actual=$(bash -c "$remote_script" 2>/dev/null) || rc=$?

	if [ "$actual" = "$password" ]; then
		if [ "$expect_fail" = "yes" ]; then
			test_fail "$test_name" "expected BROKEN but survived: [$actual]"
		else
			test_pass "$test_name"
		fi
	else
		if [ "$expect_fail" = "yes" ]; then
			test_pass "$test_name (confirmed broken: got [$actual], rc=$rc)"
		else
			test_fail "$test_name" "expected [$password], got [$actual]"
		fi
	fi
}

_test_ssh_export "ssh export: simple password" "s3cure123" "no"
_test_ssh_export "ssh export: password with single-quote BREAKS" "pass'word" "yes"
_test_ssh_export "ssh export: password with #" "pass#word" "no"
_test_ssh_export "ssh export: password with !" "pass!word" "no"
_test_ssh_export "ssh export: password with @" "pass@word" "no"
_test_ssh_export "ssh export: password with space" "pass word" "no"
_test_ssh_export "ssh export: password with %" "pass%word" "no"
_test_ssh_export "ssh export: password with \$" 'pass$word' "no"
_test_ssh_export "ssh export: password with backtick" 'pass`word' "no"
_test_ssh_export "ssh export: password with &" "pass&word" "no"

# =========================================================================
echo "--- Pattern 3: eval \"\$vars\" for vmware.conf (include_all.sh:1015) ---"
# Simulates: vars=$(sed ... vmware.conf); eval "$vars"
# Tests what happens when GOVC_PASSWORD contains special chars.
# =========================================================================

_test_vmware_eval() {
	local test_name="$1" password="$2" expect_fail="$3"

	local conf="$_tmp/vmware-$RANDOM.conf"
	cat > "$conf" <<-EOF
	GOVC_USERNAME=admin@vsphere.local
	GOVC_PASSWORD='$password'
	GOVC_URL=vcenter.example.com
	EOF

	# Simulate the actual normalize-vmware-conf sed pipeline + eval
	local vars
	vars=$(cat "$conf" | \
		sed -E \
			-e "s/^\s*#.*//g" \
			-e '/^[ \t]*$/d' -e "s/^[ \t]*//g" -e "s/[ \t]*$//g" \
			-e "s/^(([^']*'[^']*')*[^']*)#.*$/\1/" | \
		sed -e "s/^/export /g")

	local actual=""
	local rc=0
	actual=$(bash -c "$vars"$'\n'"echo \"\$GOVC_PASSWORD\"" 2>/dev/null) || rc=$?

	if [ "$actual" = "$password" ]; then
		if [ "$expect_fail" = "yes" ]; then
			test_fail "$test_name" "expected BROKEN but survived: [$actual]"
		else
			test_pass "$test_name"
		fi
	else
		if [ "$expect_fail" = "yes" ]; then
			test_pass "$test_name (confirmed broken: got [$actual], rc=$rc)"
		else
			test_fail "$test_name" "expected [$password], got [$actual]"
		fi
	fi
}

_test_vmware_eval "vmware eval: simple password" "s3cure123" "no"
_test_vmware_eval "vmware eval: password with # (outside quotes)" "pass#word" "no"
_test_vmware_eval "vmware eval: password with !" "pass!word" "no"
_test_vmware_eval "vmware eval: password with @" "pass@word" "no"
_test_vmware_eval "vmware eval: password with %" "pass%word" "no"
_test_vmware_eval "vmware eval: password with space" "pass word" "no"
_test_vmware_eval "vmware eval: password with single-quote BREAKS" "pass'word" "yes"
_test_vmware_eval "vmware eval: password with \$ safe (single-quoted in conf)" 'pass$HOMEword' "no"
_test_vmware_eval "vmware eval: password with backtick safe (single-quoted in conf)" 'pass`echo x`word' "no"

# =========================================================================
echo "--- Pattern 4: htpasswd -Bbn \"\$reg_user\" \"\$reg_pw\" (reg-install-docker.sh:71) ---"
# =========================================================================

_test_htpasswd_pattern() {
	local test_name="$1" password="$2"

	# Simulate: htpasswd receives the password as an argument
	# We just test that bash delivers it correctly (htpasswd itself handles all bytes)
	local actual
	actual=$("$_mock" -Bbn "admin" "$password" | tail -1)

	if [ "$actual" = "$password" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$password], got [$actual]"
	fi
}

_test_htpasswd_pattern "htpasswd: password with space" "pass word"
_test_htpasswd_pattern "htpasswd: password with #" "pass#word"
_test_htpasswd_pattern "htpasswd: password with !" "pass!word"
_test_htpasswd_pattern "htpasswd: password with @%^&*()" "p@ss%w^rd&*()"
_test_htpasswd_pattern "htpasswd: password with single-quote" "pass'word"
_test_htpasswd_pattern "htpasswd: password with double-quote" 'pass"word'

# =========================================================================
echo "--- Pattern 5: curl -u \"\$reg_user:\$reg_pw\" (reg-install-docker.sh:127) ---"
# =========================================================================

_test_curl_pattern() {
	local test_name="$1" password="$2"

	# Simulate: curl receives -u "user:password" as a single arg
	local actual
	actual=$("$_mock" -u "$reg_user:$password" | tail -1)

	# Just check the password part after the colon
	local pw_part="${actual#*:}"

	if [ "$pw_part" = "$password" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$password], got pw_part=[$pw_part]"
	fi
}

reg_user="admin"
_test_curl_pattern "curl -u: password with space" "pass word"
_test_curl_pattern "curl -u: password with #" "pass#word"
_test_curl_pattern "curl -u: password with @" "pass@word"
_test_curl_pattern "curl -u: password with %" "pass%word"
_test_curl_pattern "curl -u: password with single-quote" "pass'word"

# =========================================================================
echo "--- Pattern 6: unquoted \$ssh_key_file in commands ---"
# Simulates: ssh -i $ssh_key_file (unquoted, as in create-install-config.sh)
# =========================================================================

_test_unquoted_path() {
	local test_name="$1" path="$2" expect_fail="$3"

	local ssh_key_file="$path"

	# Simulate unquoted expansion: the -i flag gets split if path has spaces
	local actual
	actual=$("$_mock" -i $ssh_key_file 2>/dev/null | tail -1)

	if [ "$actual" = "$path" ]; then
		if [ "$expect_fail" = "yes" ]; then
			test_fail "$test_name" "expected BROKEN but path survived unquoted: [$actual]"
		else
			test_pass "$test_name"
		fi
	else
		if [ "$expect_fail" = "yes" ]; then
			test_pass "$test_name (confirmed broken: got [$actual])"
		else
			test_fail "$test_name" "expected [$path], got [$actual]"
		fi
	fi
}

_test_unquoted_path "unquoted path: simple" "/home/user/.ssh/id_rsa" "no"
_test_unquoted_path "unquoted path: with tilde" "~/.ssh/id_rsa" "no"
_test_unquoted_path "unquoted path: with space BREAKS" "/home/my user/.ssh/id_rsa" "yes"

# =========================================================================
echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
