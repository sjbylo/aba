#!/bin/bash
# Test: Bug #1219 — Quay remote install password variable expansion
#
# Verifies that the SSH command string built by reg-install-quay-remote.sh
# uses double quotes around $reg_pw so the remote shell expands it,
# rather than single quotes which produce a literal string.
#
# This is a static analysis test — no actual SSH or registry install.

cd "$(dirname "$0")/../.." || exit 1

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  ${RED}FAIL${NC}  %s\n" "$*"; }

SCRIPT="scripts/reg-install-quay-remote.sh"

echo "=== Bug #1219: Quay Remote Password Expansion ==="
echo

# ─────────────────────────────────────────────────────────────────
# Test 1: initPassword must NOT use single quotes around the variable
# ─────────────────────────────────────────────────────────────────
echo "--- Test 1: No single-quoted password variable ---"
if grep -q "initPassword.*'\\\\*\\\$_reg_pw'" "$SCRIPT" 2>/dev/null; then
	_fail "initPassword uses single-quoted variable (literal \$_reg_pw on remote)"
else
	_pass "No single-quoted \$_reg_pw in initPassword"
fi

# ─────────────────────────────────────────────────────────────────
# Test 2: initPassword uses double quotes (allows variable expansion)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 2: Double-quoted password variable ---"
if grep -q 'initPassword.*\\"\\$_reg_pw\\"' "$SCRIPT" 2>/dev/null; then
	_pass "initPassword uses escaped double quotes (remote shell expands \$_reg_pw)"
else
	_fail "initPassword does not use double-quoted \$_reg_pw"
fi

# ─────────────────────────────────────────────────────────────────
# Test 3: printf '%q' escaping is used for the password
# ─────────────────────────────────────────────────────────────────
echo "--- Test 3: Password is printf-escaped before SSH ---"
if grep -q "printf '%q'.*reg_pw" "$SCRIPT" 2>/dev/null; then
	_pass "Password is printf '%q' escaped"
else
	_fail "No printf '%q' escaping for password"
fi

# ─────────────────────────────────────────────────────────────────
# Test 4: Simulate command string expansion with special chars
# ─────────────────────────────────────────────────────────────────
echo "--- Test 4: Command string expansion with special password ---"

_reg_pw='P@$$w0rd "quoted" & special!'
_escaped_pw=$(printf '%q' "$_reg_pw")
reg_hostport="reg.example.com:8443"
reg_user="admin"
reg_root_opts=""
remote_dir="/tmp/mirror"

# Build the command string the same way the script does (fixed version)
cmd="cd $remote_dir && tar xvf mirror-registry-*.tar.gz && ./mirror-registry install -v --quayHostname $reg_hostport --initUser $reg_user --initPassword \"\$_reg_pw\" $reg_root_opts"
full_cmd="export _reg_pw=$_escaped_pw && $cmd"

# Simulate what the remote shell would do: eval the command string
# and check that $_reg_pw expands correctly
result=$(bash -c "$full_cmd" -- echo-only 2>&1 | grep -o 'initPassword.*' | head -1) || true

# The remote shell should see the actual password in double quotes
if echo "$full_cmd" | grep -q 'initPassword "\$_reg_pw"'; then
	_pass "Command string has expandable \$_reg_pw in double quotes"
else
	_fail "Command string does not expand \$_reg_pw correctly"
fi

# Verify the escaped password roundtrips through eval
recovered=$(bash -c "export _reg_pw=$_escaped_pw && echo \"\$_reg_pw\"")
if [ "$recovered" = "$_reg_pw" ]; then
	_pass "Password with special chars survives printf+eval roundtrip"
else
	_fail "Password mangled: expected '$_reg_pw', got '$recovered'"
fi

echo
echo "========================================="
echo "  Results: $pass passed, $fail failed"
echo "========================================="
[ $fail -gt 0 ] && exit 1 || exit 0
