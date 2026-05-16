#!/bin/bash
# Test: Approach C password handling — sed-escape + input validation + round-trip.
# Verifies passwords survive write→read→use cycle with special characters.
#
# Tests:
#   1. _sed_escape_replacement() correctly escapes sed-special chars
#   2. _validate_password() rejects dangerous/invalid passwords
#   3. replace-value-conf round-trip with escaped passwords
#   4. Sourced password matches original (shell round-trip)
#   5. htpasswd authentication with special-char passwords
#   6. Password output/display is not corrupted

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { printf "${GREEN}✓ PASS${NC}: %s\n" "$1"; pass=$(( pass + 1 )); }
test_fail() { printf "${RED}✗ FAIL${NC}: %s -- %s\n" "$1" "$2"; fail=$(( fail + 1 )); }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

source scripts/include_all.sh dummy_arg 2>/dev/null

echo
echo "============================================================"
echo " Approach C: Password Handling Tests"
echo "============================================================"
echo

# _sed_escape_replacement() and replace-value-conf() are now sourced from
# scripts/include_all.sh — no local overrides.  Tests use the REAL functions.

# =====================================================================
# 1. _sed_escape_replacement() — unit tests for the helper in include_all.sh
# =====================================================================

echo "--- _sed_escape_replacement() ---"

_test_escape() {
	local test_name="$1" input="$2" expected="$3"
	local actual
	actual=$(_sed_escape_replacement "$input")
	if [[ "$actual" == "$expected" ]]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "input [$input] → [$actual], expected [$expected]"
	fi
}

_test_escape "no special chars"          "p4ssw0rd"         "p4ssw0rd"
_test_escape "ampersand escaped"         "pass&word"        "pass\&word"
_test_escape "backslash escaped"         'pass\word'        'pass\\word'
_test_escape "pipe escaped"              "pass|word"        'pass\|word'
_test_escape "multiple specials"         'a&b\c|d'          'a\&b\\c\|d'
_test_escape "ampersand at start"        "&hello"           '\&hello'
_test_escape "backslash at end"          'hello\'           'hello\\'
_test_escape "all three adjacent"        '&|\&|'            '\&\|\\\&\|'
_test_escape "dollar sign unchanged"     'pass$word'        'pass$word'
_test_escape "hash unchanged"            'pass#word'        'pass#word'
_test_escape "exclamation unchanged"     'pass!word'        'pass!word'
_test_escape "parens unchanged"          'pass(w)ord'       'pass(w)ord'
_test_escape "brackets unchanged"        'pass[w]ord'       'pass[w]ord'
_test_escape "double-quote unchanged"    'pass"word'        'pass"word'
_test_escape "backtick unchanged"        'pass`word'        'pass`word'

echo

# =====================================================================
# 2. _validate_password() — reject dangerous/invalid input
# =====================================================================
# This is the proposed fix for Bug #49 and Bug #66.

_validate_password() {
	local pw="$1"
	# Single quote breaks single-quoted config values — reject
	if [[ "$pw" == *"'"* ]]; then
		echo "REJECT:single-quote"
		return 1
	fi
	# Quay installer rejects whitespace
	if [[ "$pw" =~ [[:space:]] ]]; then
		echo "REJECT:whitespace"
		return 1
	fi
	# Minimum length (Quay requires >= 8)
	if [[ ${#pw} -lt 8 ]]; then
		echo "REJECT:too-short"
		return 1
	fi
	echo "OK"
	return 0
}

echo "--- _validate_password() ---"

_test_validate() {
	local test_name="$1" pw="$2" expected_result="$3"
	local actual
	actual=$(_validate_password "$pw")
	if [[ "$actual" == "$expected_result" ]]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "password [$pw] → [$actual], expected [$expected_result]"
	fi
}

_test_validate "simple password accepted"         "p4ssw0rd"       "OK"
_test_validate "complex password accepted"         'P@ss!w0rd#42'  "OK"
_test_validate "ampersand accepted"                "pass&w0rd"      "OK"
_test_validate "backslash accepted"                'pass\w0rd'      "OK"
_test_validate "pipe accepted"                     "pass|w0rd"      "OK"
_test_validate "dollar accepted"                   'pass$w0rd'      "OK"
_test_validate "double-quote accepted"             'pass"w0rd'      "OK"
_test_validate "backtick accepted"                 'pass`w0rd'      "OK"
_test_validate "hash accepted"                     "pass#w0rd"      "OK"
_test_validate "excl/at/caret accepted"            'P!@^w0rd'       "OK"
_test_validate "single-quote REJECTED"             "pass'w0rd"      "REJECT:single-quote"
_test_validate "space REJECTED"                    "pass w0rd"      "REJECT:whitespace"
_test_validate "tab REJECTED"                      $'pass\tw0rd'    "REJECT:whitespace"
_test_validate "too short REJECTED"                "abc"            "REJECT:too-short"
_test_validate "exactly 8 chars accepted"          "12345678"       "OK"
_test_validate "7 chars REJECTED"                  "1234567"        "REJECT:too-short"
_test_validate "empty REJECTED"                    ""               "REJECT:too-short"

echo

# =====================================================================
# 3. Full round-trip: validate → write → read → verify
# =====================================================================
# Simulates the real flow: TUI validates → replace-value-conf writes →
# normalize sources → script uses the value.

echo "--- Full round-trip: write → source → verify ---"

_test_roundtrip() {
	local test_name="$1" password="$2"
	local conf="$_tmp/rt-$RANDOM.conf"

	# Start with a template config (like mirror.conf)
	cat > "$conf" <<-'TMPL'
	reg_host=registry4.example.com
	reg_port=8443
	reg_user=admin
	reg_pw='p4ssw0rd'
	TMPL

	# Step 1: Validate
	local vresult
	vresult=$(_validate_password "$password")
	if [[ "$vresult" != "OK" ]]; then
		test_fail "$test_name" "validation unexpectedly failed: $vresult"
		return
	fi

	# Step 2: Write to config file using replace-value-conf
	# Caller pre-quotes with single quotes (as the real TUI does).
	# The fixed replace-value-conf handles sed escaping internally.
	replace-value-conf -q -n reg_pw -v "'${password}'" -f "$conf" 2>/dev/null

	# Step 4: Source the config file (as normalize functions do)
	local readback
	readback=$(
		unset reg_pw
		source "$conf" 2>/dev/null
		printf '%s' "$reg_pw"
	)

	# Step 5: Verify the sourced value matches the original
	if [[ "$readback" == "$password" ]]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "wrote [$password], read back [$readback] (file: $(grep reg_pw "$conf"))"
	fi
}

_test_roundtrip "simple password"                   "p4ssw0rd"
_test_roundtrip "password with hash"                "p4ss#w0rd"
_test_roundtrip "password with ampersand"           "p4ss&w0rd"
_test_roundtrip "password with backslash"           'p4ss\w0rd'
_test_roundtrip "password with pipe"                "p4ss|w0rd"
_test_roundtrip "password with dollar"              'p4ss$w0rd'
_test_roundtrip "password with double-quote"        'p4ss"w0rd'
_test_roundtrip "password with backtick"            'p4ss`w0rd'
_test_roundtrip "password with exclamation"         "p4ss!w0rd"
_test_roundtrip "password with at-sign"             "p4ss@w0rd"
_test_roundtrip "password with caret"               "p4ss^w0rd"
_test_roundtrip "password with equals"              "p4ss=w0rd"

# These FAIL due to a separate bug: replace-value-conf line 1679 uses grep -E
# with the raw value as regex.  ( ) [ ] + are ERE metacharacters, so the
# "already exists" check falsely matches the template value and skips the write.
# E.g., grep -E "^reg_pw='p4ss(w)0rd'" matches reg_pw='p4ssw0rd' because
# (w) is a capture group matching w.  Fix: use grep -F for that check.
_test_roundtrip_grep_bug() {
	local test_name="$1" password="$2"
	local conf="$_tmp/rt-$RANDOM.conf"

	cat > "$conf" <<-'TMPL'
	reg_host=registry4.example.com
	reg_port=8443
	reg_user=admin
	reg_pw='p4ssw0rd'
	TMPL

	replace-value-conf -q -n reg_pw -v "'${password}'" -f "$conf" 2>/dev/null

	local readback
	readback=$(unset reg_pw; source "$conf" 2>/dev/null; printf '%s' "$reg_pw")

	if [[ "$readback" == "$password" ]]; then
		test_pass "$test_name (grep -E bug fixed!)"
	else
		test_fail "$test_name (KNOWN: grep -E bug in replace-value-conf)" \
			"wrote [$password], read [$readback] — grep -E treats ()[]+ as regex"
	fi
}

_test_roundtrip_grep_bug "password with parens (grep -E bug)"      "p4ss(w)0rd"
_test_roundtrip_grep_bug "password with brackets (grep -E bug)"    "p4ss[w]0rd"
_test_roundtrip_grep_bug "password with plus (grep -E bug)"        "p4ss+w0rd"
_test_roundtrip "password with tilde"               "p4ss~w0rd"
_test_roundtrip "password with percent"             "p4ss%w0rd"
_test_roundtrip "all safe specials combined"        'P@$$!#^&|=+~%w'
_test_roundtrip "realistic complex password"        'Kd8#f&2|xQ!@^z'

echo

# =====================================================================
# 4. htpasswd authentication — password actually works for auth
# =====================================================================

echo "--- htpasswd authentication with special-char passwords ---"

_test_htpasswd() {
	local test_name="$1" password="$2"
	local htfile="$_tmp/htpasswd-$RANDOM"
	local user="testuser"

	# Create htpasswd entry (bcrypt)
	if ! htpasswd -bBc "$htfile" "$user" "$password" 2>/dev/null; then
		test_fail "$test_name (create)" "htpasswd -bBc failed for password [$password]"
		return
	fi

	# Verify authentication succeeds
	if htpasswd -bv "$htfile" "$user" "$password" 2>/dev/null; then
		test_pass "$test_name"
	else
		test_fail "$test_name (verify)" "htpasswd -bv rejected password [$password]"
	fi
}

_test_htpasswd "simple password auth"               "p4ssw0rd"
_test_htpasswd "hash in password auth"              "p4ss#w0rd"
_test_htpasswd "ampersand in password auth"         "p4ss&w0rd"
_test_htpasswd "backslash in password auth"         'p4ss\w0rd'
_test_htpasswd "pipe in password auth"              "p4ss|w0rd"
_test_htpasswd "dollar in password auth"            'p4ss$w0rd'
_test_htpasswd "double-quote in password auth"      'p4ss"w0rd'
_test_htpasswd "backtick in password auth"          'p4ss`w0rd'
_test_htpasswd "realistic complex auth"             'Kd8#f&2|xQ!@^z'

echo

# =====================================================================
# 5. Full pipeline: write → read → authenticate
# =====================================================================
# End-to-end: password goes into config, comes back out, authenticates.

echo "--- End-to-end: config file → htpasswd auth ---"

_test_e2e() {
	local test_name="$1" password="$2"
	local conf="$_tmp/e2e-$RANDOM.conf"
	local htfile="$_tmp/e2e-ht-$RANDOM"
	local user="admin"

	# Template config
	cat > "$conf" <<-'TMPL'
	reg_user=admin
	reg_pw='template-default'
	TMPL

	# Write — fixed replace-value-conf handles escaping internally
	replace-value-conf -q -n reg_pw -v "'${password}'" -f "$conf" 2>/dev/null

	# Read back by sourcing
	local pw_from_conf
	pw_from_conf=$(
		unset reg_pw
		source "$conf" 2>/dev/null
		printf '%s' "$reg_pw"
	)

	# Create htpasswd with the ORIGINAL password
	htpasswd -bBc "$htfile" "$user" "$password" 2>/dev/null

	# Authenticate with the password READ FROM THE CONFIG FILE
	if htpasswd -bv "$htfile" "$user" "$pw_from_conf" 2>/dev/null; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "wrote [$password], read [$pw_from_conf], auth failed (file: $(grep reg_pw "$conf"))"
	fi
}

_test_e2e "e2e simple"                    "p4ssw0rd"
_test_e2e "e2e with hash"                 "p4ss#w0rd"
_test_e2e "e2e with ampersand"            "p4ss&w0rd"
_test_e2e "e2e with backslash"            'p4ss\w0rd'
_test_e2e "e2e with pipe"                 "p4ss|w0rd"
_test_e2e "e2e with dollar"              'p4ss$w0rd'
_test_e2e "e2e with double-quote"        'p4ss"w0rd'
_test_e2e "e2e complex"                  'Kd8#f&2|xQ!@^z'

echo

# =====================================================================
# 6. printf output — password displayed without corruption
# =====================================================================

echo "--- Password output correctness ---"

_test_output() {
	local test_name="$1" password="$2"
	local conf="$_tmp/out-$RANDOM.conf"

	cat > "$conf" <<-'TMPL'
	reg_pw='placeholder'
	TMPL

	replace-value-conf -q -n reg_pw -v "'${password}'" -f "$conf" 2>/dev/null

	local pw_from_conf
	pw_from_conf=$(
		unset reg_pw
		source "$conf" 2>/dev/null
		printf '%s' "$reg_pw"
	)

	# Verify printf output matches byte-for-byte
	local printed
	printed=$(printf '%s' "$pw_from_conf")
	if [[ "$printed" == "$password" ]]; then
		test_pass "$test_name"
	else
		test_fail "$test_name" "printf output [$printed] != original [$password]"
	fi
}

_test_output "output simple"               "p4ssw0rd"
_test_output "output with ampersand"       "p4ss&w0rd"
_test_output "output with backslash"       'p4ss\w0rd'
_test_output "output with pipe"            "p4ss|w0rd"
_test_output "output with all specials"    'Kd8#f&2|xQ!@^z'

echo

# =====================================================================
# Summary
# =====================================================================

echo "============================================================"
echo -e " Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
echo "============================================================"

[[ $fail -eq 0 ]] && exit 0 || exit 1
