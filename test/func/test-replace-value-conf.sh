#!/bin/bash
# Unit tests for replace-value-conf() function.
# Exercises quoting, spaces, hash chars, commented-out keys, edge cases,
# rewriting between value types, bogus inputs, and caller-pre-quoted passwords.

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

echo
echo "=== Testing: replace-value-conf() ==="
echo

# ---- Helpers ----

# Test that: after replacement, sourcing the file yields expected value
# Args: test_name initial_content name new_value expected_value
_test_replace() {
	local test_name="$1" initial="$2" name="$3" new_value="$4" expected="$5"
	local conf="$_tmp/test-$RANDOM.conf"

	echo "$initial" > "$conf"

	replace-value-conf -q -n "$name" -v "$new_value" -f "$conf" 2>/dev/null

	# Source in a subshell — capture the value AND any errors
	local output
	output=$(bash -c "set -e; . '$conf' 2>&1; echo \"\$$name\"" 2>&1)
	local rc=$?

	# Value is the last line; preceding lines are errors
	local actual
	actual=$(echo "$output" | tail -1)

	if [ "$actual" = "$expected" ] && [ $rc -eq 0 ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$expected], got [$actual] (rc=$rc, file: $(cat "$conf"))"
	fi
}

# Test the exact file content after replacement
# Args: test_name initial_content name new_value expected_file_content
_test_replace_raw() {
	local test_name="$1" initial="$2" name="$3" new_value="$4" expected_file_content="$5"
	local conf="$_tmp/test-$RANDOM.conf"

	echo "$initial" > "$conf"

	replace-value-conf -q -n "$name" -v "$new_value" -f "$conf" 2>/dev/null

	local actual_content
	actual_content=$(cat "$conf")

	if [ "$actual_content" = "$expected_file_content" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected file [$expected_file_content], got [$actual_content]"
	fi
}

# Test return code only
# Args: test_name expected_rc initial_content name new_value files...
_test_rc() {
	local test_name="$1" expected_rc="$2" initial="$3" name="$4" new_value="$5"
	shift 5
	local conf="$_tmp/test-$RANDOM.conf"

	if [ "$initial" != "__nofile__" ]; then
		echo "$initial" > "$conf"
	fi

	local _files="${*:-$conf}"

	local rc=0
	replace-value-conf -q -n "$name" -v "$new_value" -f $_files 2>/dev/null || rc=$?

	if [ "$rc" -eq "$expected_rc" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected rc=$expected_rc, got rc=$rc"
	fi
}

# =========================================================================
echo "--- Basic replacements ---"
# =========================================================================

_test_replace "simple value" \
	"a=xxx" "a" "yyy" "yyy"

_test_replace "numeric value" \
	"port=8080" "port" "9090" "9090"

_test_replace "empty old value to new value" \
	"a=" "a" "hello" "hello"

_test_replace "value to empty (undefine)" \
	"a=xxx" "a" "" ""

# =========================================================================
echo "--- Values with common config characters ---"
# =========================================================================

_test_replace "dots and dashes (hostname)" \
	"host=old.example.com" "host" "new-host.example.com" "new-host.example.com"

_test_replace "colons and slashes (URL)" \
	"url=https://old:8443" "url" "https://new:9443" "https://new:9443"

_test_replace "underscores" \
	"my_var=old_val" "my_var" "new_val" "new_val"

_test_replace "forward slashes (path)" \
	"path=/old/path" "path" "/new/path" "/new/path"

_test_replace "IP address" \
	"machine_network=10.0.0.0" "machine_network" "192.168.1.0" "192.168.1.0"

_test_replace "value with equals sign" \
	"opts=--flag=old" "opts" "--flag=new" "--flag=new"

_test_replace "libvirt URI with plus sign" \
	"LIBVIRT_URI=qemu+ssh://user@host/system" "LIBVIRT_URI" "qemu+ssh://other@host2/system" "qemu+ssh://other@host2/system"

# =========================================================================
echo "--- Commented-out keys ---"
# =========================================================================

_test_replace "uncomment key (# prefix)" \
	"#a=xxx" "a" "yyy" "yyy"

_test_replace "uncomment key (# space prefix)" \
	"# a=xxx" "a" "yyy" "yyy"

_test_replace "uncomment key with empty old value" \
	"#a=" "a" "yyy" "yyy"

# =========================================================================
echo "--- Trailing comments (must be preserved exactly) ---"
# =========================================================================

_test_replace_raw "trailing comment after space preserved" \
	"a=xxx  # some comment" "a" "yyy" "a=yyy  # some comment"

_test_replace_raw "trailing comment after tab preserved" \
	"$(printf 'a=xxx\t# some comment')" "a" "yyy" "$(printf 'a=yyy\t# some comment')"

_test_replace_raw "trailing comment with multiple spaces preserved" \
	"a=xxx    # trailing with 4 spaces" "a" "yyy" "a=yyy    # trailing with 4 spaces"

_test_replace_raw "trailing comment after empty value preserved" \
	"a=  # set this" "a" "yyy" "a=yyy  # set this"

# =========================================================================
echo "--- Single-quoted OLD values ---"
# =========================================================================

_test_replace "replace single-quoted simple value" \
	"a='xxx'" "a" "yyy" "yyy"

_test_replace "replace single-quoted value with spaces" \
	"a='x y'" "a" "yyy" "yyy"

_test_replace "replace single-quoted value with hash" \
	"a='x#y'" "a" "yyy" "yyy"

_test_replace "replace single-quoted value with spaces and hash" \
	"a='hello world #tag'" "a" "simple" "simple"

_test_replace_raw "replace single-quoted value preserves trailing comment" \
	"a='old val'  # important comment" "a" "new" "a=new  # important comment"

# =========================================================================
echo "--- NEW values with spaces (must be quoted on write) ---"
# =========================================================================

_test_replace "new value with spaces is sourceable" \
	"a=xxx" "a" "x y z" "x y z"

_test_replace "new value with single space" \
	"a=xxx" "a" "hello world" "hello world"

_test_replace "new value with hash is sourceable" \
	"a=xxx" "a" "abc#def" "abc#def"

_test_replace "new value with space and hash" \
	"a=xxx" "a" "hello #world" "hello #world"

# =========================================================================
echo "--- Rewriting between value types ---"
# =========================================================================

_test_replace "simple -> value with spaces" \
	"a=xxx" "a" "x y z" "x y z"

_test_replace "value with spaces -> simple" \
	"a='x y z'" "a" "simple" "simple"

_test_replace "value with spaces -> different value with spaces" \
	"a='old val'" "a" "new val" "new val"

_test_replace "value with hash -> simple" \
	"a='x#y'" "a" "simple" "simple"

_test_replace "simple -> value with hash" \
	"a=xxx" "a" "a#b" "a#b"

_test_replace "single-quoted -> value with spaces" \
	"a='old'" "a" "new value here" "new value here"

_test_replace "value with spaces -> value with hash" \
	"a='hello world'" "a" "x#y" "x#y"

_test_replace "empty -> value with spaces" \
	"a=" "a" "hello world" "hello world"

_test_replace "value with spaces -> empty (undefine)" \
	"a='hello world'" "a" "" ""

# =========================================================================
echo "--- Password patterns (caller pre-quotes, template uses single quotes) ---"
# =========================================================================

# The real caller does: replace-value-conf -n reg_pw -v "'$pw'" -f mirror.conf
# So the value passed to the function is literally 'password' with quotes

_test_replace "caller-pre-quoted password (simple)" \
	"reg_pw='p4ssw0rd'" "reg_pw" "'newpass'" "newpass"

_test_replace "caller-pre-quoted password with hash" \
	"reg_pw='p4ss#w0rd'" "reg_pw" "'n3w#pass'" "n3w#pass"

_test_replace "caller-pre-quoted password replaces template default" \
	"reg_pw='p4ssw0rd'			# Registry password." "reg_pw" "'s3cure!'" "s3cure!"

_test_replace "password with special chars: @!^&*()+" \
	"reg_pw='old'" "reg_pw" "'p@ss!w^rd&*()+'" "p@ss!w^rd&*()+'"

# =========================================================================
echo "--- Idempotency ---"
# =========================================================================

_test_idem() {
	local test_name="$1" content="$2" name="$3" value="$4"
	local conf="$_tmp/test-$RANDOM.conf"
	echo "$content" > "$conf"
	local before after
	before=$(md5sum "$conf" | awk '{print $1}')

	replace-value-conf -q -n "$name" -v "$value" -f "$conf" 2>/dev/null

	after=$(md5sum "$conf" | awk '{print $1}')
	if [ "$before" = "$after" ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "file was modified (before=$before, after=$after, content: $(cat "$conf"))"
	fi
}

_test_idem "idempotent: simple value already set" \
	"a=yyy" "a" "yyy"

_test_idem "idempotent: value with trailing comment" \
	"a=yyy  # comment" "a" "yyy"

_test_idem "idempotent: empty value already commented out" \
	"#a=oldval" "a" ""

# =========================================================================
echo "--- Multi-key file (only target key changes) ---"
# =========================================================================

_test_multi_key() {
	local conf="$_tmp/multi-$RANDOM.conf"
	cat > "$conf" <<-'MEOF'
	name=cluster1
	domain=example.com
	port=8443
	MEOF

	replace-value-conf -q -n "domain" -v "new.example.com" -f "$conf" 2>/dev/null

	local r_name r_domain r_port
	r_name=$(bash -c ". '$conf' && echo \$name" 2>/dev/null)
	r_domain=$(bash -c ". '$conf' && echo \$domain" 2>/dev/null)
	r_port=$(bash -c ". '$conf' && echo \$port" 2>/dev/null)

	if [ "$r_name" = "cluster1" ] && [ "$r_domain" = "new.example.com" ] && [ "$r_port" = "8443" ]; then
		test_pass "multi-key: only target key changes"
	else
		test_fail "multi-key: only target key changes" "name=$r_name domain=$r_domain port=$r_port"
	fi
}
_test_multi_key

# =========================================================================
echo "--- Multiple files (first match wins) ---"
# =========================================================================

_test_multi_file() {
	local conf1="$_tmp/first-$RANDOM.conf" conf2="$_tmp/second-$RANDOM.conf"
	echo "a=old1" > "$conf1"
	echo "a=old2" > "$conf2"

	replace-value-conf -q -n "a" -v "new" -f "$conf1" "$conf2" 2>/dev/null

	local val1 val2
	val1=$(bash -c ". '$conf1' && echo \$a" 2>/dev/null)
	val2=$(bash -c ". '$conf2' && echo \$a" 2>/dev/null)

	if [ "$val1" = "new" ] && [ "$val2" = "old2" ]; then
		test_pass "multiple files: first match wins, second untouched"
	else
		test_fail "multiple files: first match wins" "val1=$val1 val2=$val2"
	fi
}
_test_multi_file

_test_multi_file_skip() {
	local conf1="$_tmp/skip1-$RANDOM.conf" conf2="$_tmp/skip2-$RANDOM.conf"
	echo "b=only_in_first" > "$conf1"
	echo "a=in_second" > "$conf2"

	replace-value-conf -q -n "a" -v "new" -f "$conf1" "$conf2" 2>/dev/null

	local val_b val_a
	val_b=$(bash -c ". '$conf1' && echo \$b" 2>/dev/null)
	val_a=$(bash -c ". '$conf2' && echo \$a" 2>/dev/null)

	if [ "$val_b" = "only_in_first" ] && [ "$val_a" = "new" ]; then
		test_pass "multiple files: skip file without key, change second"
	else
		test_fail "multiple files: skip first" "b=$val_b a=$val_a"
	fi
}
_test_multi_file_skip

# =========================================================================
echo "--- Error cases (return code 1) ---"
# =========================================================================

_test_rc "key not found in file" 1 \
	"a=xxx" "nonexistent" "val"

_test_rc "missing file" 1 \
	"__nofile__" "a" "val" "$_tmp/does_not_exist_$RANDOM.conf"

_test_empty_file() {
	local conf="$_tmp/empty-$RANDOM.conf"
	touch "$conf"
	local rc=0
	replace-value-conf -q -n "a" -v "val" -f "$conf" 2>/dev/null || rc=$?
	if [ "$rc" -eq 1 ]; then
		test_pass "empty file returns 1"
	else
		test_fail "empty file returns 1" "got rc=$rc"
	fi
}
_test_empty_file

# =========================================================================
echo "--- Edge cases ---"
# =========================================================================

_test_replace "value that looks like a flag: --something" \
	"opts=--old" "opts" "--new-flag" "--new-flag"

_test_replace "very long value (200 chars)" \
	"a=short" "a" "$(printf 'x%.0s' {1..200})" "$(printf 'x%.0s' {1..200})"

_test_replace "value with pipe char (sed delimiter)" \
	"a=old" "a" "x|y" "x|y"

_test_replace_raw "pipe in value does not corrupt file" \
	"a=old" "a" "x|y" "a=x|y"

_test_replace "consecutive replacements" \
	"a=first" "a" "second" "second"

_test_consecutive() {
	local conf="$_tmp/consec-$RANDOM.conf"
	echo "a=first" > "$conf"

	replace-value-conf -q -n "a" -v "second" -f "$conf" 2>/dev/null
	replace-value-conf -q -n "a" -v "third" -f "$conf" 2>/dev/null

	local actual
	actual=$(bash -c ". '$conf' && echo \$a" 2>/dev/null)
	if [ "$actual" = "third" ]; then
		test_pass "two consecutive replacements: first->second->third"
	else
		test_fail "two consecutive replacements" "expected [third], got [$actual]"
	fi
}
_test_consecutive

_test_consecutive_quoted() {
	local conf="$_tmp/consec-q-$RANDOM.conf"
	echo "a='hello world'" > "$conf"

	replace-value-conf -q -n "a" -v "simple" -f "$conf" 2>/dev/null
	replace-value-conf -q -n "a" -v "another value" -f "$conf" 2>/dev/null

	local actual
	actual=$(bash -c ". '$conf' && echo \$a" 2>/dev/null)
	if [ "$actual" = "another value" ]; then
		test_pass "consecutive: quoted->simple->spaces"
	else
		test_fail "consecutive: quoted->simple->spaces" "expected [another value], got [$actual] (file: $(cat "$conf"))"
	fi
}
_test_consecutive_quoted

# =========================================================================
echo "--- Dangerous characters (verify they DO break things) ---"
# =========================================================================
# These chars are documented as forbidden in config passwords: "'\`$
# Additional chars that break sed or bash: & \ %
# Each test verifies the char actually causes corruption or wrong values.

_test_dangerous_char() {
	local test_name="$1" initial="$2" name="$3" new_value="$4"
	local conf="$_tmp/test-$RANDOM.conf"

	echo "$initial" > "$conf"

	replace-value-conf -q -n "$name" -v "$new_value" -f "$conf" 2>/dev/null || true

	# Try to source — if it errors or the value is wrong, the char IS dangerous
	local actual
	actual=$(bash -c "set +H; . '$conf' 2>/dev/null && echo \"\$$name\"" 2>&1)
	local rc=$?
	local file_content
	file_content=$(cat "$conf")

	# We EXPECT these to fail — the char should cause corruption
	# The test PASSES if the result is wrong (proves the char is dangerous)
	if [ "$actual" != "$new_value" ] || [ $rc -ne 0 ]; then
		test_pass "$test_name (confirmed dangerous: got [$actual], file: [$file_content])"
	else
		test_fail "$test_name" "char was NOT dangerous — value [$actual] written and sourced OK (file: [$file_content])"
	fi
}

# For pre-quoted values (caller convention: -v "'password'")
_test_dangerous_char_prequoted() {
	local test_name="$1" initial="$2" name="$3" raw_password="$4"
	local conf="$_tmp/test-$RANDOM.conf"

	echo "$initial" > "$conf"

	# Caller pre-quotes: -v "'$raw_password'"
	replace-value-conf -q -n "$name" -v "'$raw_password'" -f "$conf" 2>/dev/null || true

	local actual
	actual=$(bash -c "set +H; . '$conf' 2>/dev/null && echo \"\$$name\"" 2>&1)
	local rc=$?
	local file_content
	file_content=$(cat "$conf")

	if [ "$actual" != "$raw_password" ] || [ $rc -ne 0 ]; then
		test_pass "$test_name (confirmed dangerous: got [$actual], file: [$file_content])"
	else
		test_fail "$test_name" "char was NOT dangerous — value [$actual] sourced OK (file: [$file_content])"
	fi
}

# -- Documented forbidden chars for passwords: "'\`$ --

_test_dangerous_char_prequoted 'password with double-quote "' \
	"reg_pw='old'" "reg_pw" 'pass"word'

_test_dangerous_char_prequoted "password with single-quote '" \
	"reg_pw='old'" "reg_pw" "pass'word"

_test_dangerous_char_prequoted 'password with backtick `' \
	"reg_pw='old'" "reg_pw" 'pass`word'

_test_dangerous_char_prequoted 'password with dollar $' \
	"reg_pw='old'" "reg_pw" 'pass$word'

# -- Additional chars that break sed --

_test_dangerous_char_prequoted 'password with ampersand &' \
	"reg_pw='old'" "reg_pw" 'pass&word'

_test_dangerous_char_prequoted 'password with backslash \' \
	"reg_pw='old'" "reg_pw" 'pass\word'

_test_dangerous_char_prequoted 'password with percent % (sed delimiter)' \
	"reg_pw='old'" "reg_pw" 'pass%word'

# -- Chars that are SAFE inside single quotes (should NOT be dangerous) --

_test_safe_char() {
	local test_name="$1" initial="$2" name="$3" raw_password="$4"
	local conf="$_tmp/test-$RANDOM.conf"

	echo "$initial" > "$conf"

	replace-value-conf -q -n "$name" -v "'$raw_password'" -f "$conf" 2>/dev/null || true

	local actual
	actual=$(bash -c "set +H; . '$conf' 2>/dev/null && echo \"\$$name\"" 2>&1)
	local rc=$?

	if [ "$actual" = "$raw_password" ] && [ $rc -eq 0 ]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "expected [$raw_password], got [$actual] (rc=$rc, file: $(cat "$conf"))"
	fi
}

_test_safe_char "password with # is safe" \
	"reg_pw='old'" "reg_pw" "PQa5iSjbbq#bfE8!"

_test_safe_char "password with ! is safe" \
	"reg_pw='old'" "reg_pw" "p4ss!w0rd"

_test_safe_char "password with @ is safe" \
	"reg_pw='old'" "reg_pw" "p4ss@w0rd"

_test_safe_char "password with ^ is safe" \
	"reg_pw='old'" "reg_pw" "p4ss^w0rd"

_test_safe_char "password with () is safe" \
	"reg_pw='old'" "reg_pw" "p4ss(w0r)d"

_test_safe_char "password with + is safe" \
	"reg_pw='old'" "reg_pw" "p4ss+w0rd"

_test_safe_char "password with = is safe" \
	"reg_pw='old'" "reg_pw" "p4ss=w0rd"

_test_safe_char "GOVC_PASSWORD with # and !" \
	"GOVC_PASSWORD='oldpass'" "GOVC_PASSWORD" "PQa5iSjbbq#bfE8!"

# =========================================================================
echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
