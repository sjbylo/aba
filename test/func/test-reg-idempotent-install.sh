#!/bin/bash
# test-reg-idempotent-install.sh — Test the reg_detect_existing state machine
# Tests: reg_mark_installing, reg_detect_existing with various state.sh scenarios
# This is a standalone functional test.

set -u

_repo="$(cd "$(dirname "$0")/../.." && pwd)"
_pass=0
_fail=0
_test_num=0

pass() {
	_pass=$(( _pass + 1 ))
	_test_num=$(( _test_num + 1 ))
	echo "  PASS [$_test_num] $1"
}

fail() {
	_fail=$(( _fail + 1 ))
	_test_num=$(( _test_num + 1 ))
	echo "  FAIL [$_test_num] $1"
}

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		pass "$desc"
	else
		fail "$desc (expected='$expected' actual='$actual')"
	fi
}

assert_contains() {
	local desc="$1" expected="$2" actual="$3"
	if echo "$actual" | grep -q "$expected"; then
		pass "$desc"
	else
		fail "$desc (expected to contain '$expected', got: '$actual')"
	fi
}

assert_not_exists() {
	local desc="$1" path="$2"
	if [ ! -e "$path" ]; then
		pass "$desc"
	else
		fail "$desc (file '$path' should not exist)"
	fi
}

assert_exists() {
	local desc="$1" path="$2"
	if [ -e "$path" ]; then
		pass "$desc"
	else
		fail "$desc (file '$path' should exist)"
	fi
}

# --- Setup ---
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Minimal environment needed by reg-common.sh functions
export regcreds_dir="$_tmp/regcreds"
export reg_host="localhost"
export reg_port="59999"
export reg_url="https://localhost:59999"
export reg_user="testuser"
export reg_pw="testpw123"
export reg_root="$_tmp/data"
export reg_path="testpath"
export reg_ssh_key=""
export reg_ssh_user=""

# Source include_all.sh for aba_info, aba_debug, probe_host etc.
cd "$_repo"
source scripts/include_all.sh 2>/dev/null

# Source reg-common.sh for the functions under test
source scripts/reg-common.sh

echo "=== Test: REG_RC_COMPLETING constant ==="
assert_eq "REG_RC_COMPLETING is defined and numeric" "90" "$REG_RC_COMPLETING"

echo ""
echo "=== Test: reg_mark_installing ==="
rm -rf "$regcreds_dir"
reg_mark_installing "omr" 2>/dev/null

assert_exists "state.sh created" "$regcreds_dir/state.sh"

_content=$(cat "$regcreds_dir/state.sh")
assert_contains "state.sh has reg_status=installing" "reg_status=installing" "$_content"
assert_contains "state.sh has reg_vendor=omr" "reg_vendor=omr" "$_content"
assert_contains "state.sh has reg_host=localhost" "reg_host=localhost" "$_content"
assert_contains "state.sh has reg_port=59999" "reg_port=59999" "$_content"
assert_contains "state.sh has reg_user=testuser" "reg_user=testuser" "$_content"
assert_contains "state.sh has reg_pw" "reg_pw=" "$_content"
assert_contains "state.sh has last_action_at" "last_action_at=" "$_content"

# Verify state.sh is sourceable
(source "$regcreds_dir/state.sh" && [ "$reg_status" = "installing" ])
assert_eq "state.sh is sourceable and reg_status=installing" "0" "$?"

echo ""
echo "=== Test: reg_detect_existing — no state.sh, no service ==="
rm -rf "$regcreds_dir"
mkdir -p "$regcreds_dir"
# No state.sh, nothing listening on port 59999 — should return 0 (proceed with install)
_rc=0
reg_detect_existing 2>/dev/null || _rc=$?
assert_eq "returns 0 (proceed with install)" "0" "$_rc"

echo ""
echo "=== Test: reg_detect_existing — installing + NOT healthy ==="
rm -rf "$regcreds_dir"
reg_mark_installing "docker" 2>/dev/null
# Port 59999 not listening, so probe_host will fail
_rc=0
reg_detect_existing 2>/dev/null || _rc=$?
assert_eq "returns 0 (retry install)" "0" "$_rc"
assert_not_exists "state.sh removed (clean retry)" "$regcreds_dir/state.sh"

echo ""
echo "=== Test: reg_detect_existing — installing + service healthy ==="
# Start a simple HTTPS listener on port 59999 to simulate a healthy registry
_cert_dir="$_tmp/certs"
mkdir -p "$_cert_dir"
openssl req -x509 -newkey rsa:2048 -keyout "$_cert_dir/key.pem" \
	-out "$_cert_dir/cert.pem" -days 1 -nodes -subj "/CN=localhost" 2>/dev/null

# Use openssl s_server as a fake registry that returns 200 on /v2/
# Run in background
(
	cd "$_cert_dir"
	while true; do
		echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}" | \
			openssl s_server -key key.pem -cert cert.pem -accept 59999 \
			-quiet -naccept 1 2>/dev/null || break
	done
) &
_server_pid=$!
sleep 1

# Verify the server is listening
if curl -k -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 "https://localhost:59999/v2/" 2>/dev/null | grep -q "200"; then
	echo "  (test server listening on :59999)"
else
	echo "  WARNING: test server may not be ready"
fi

rm -rf "$regcreds_dir"
reg_mark_installing "omr" 2>/dev/null
_rc=0
reg_detect_existing 2>/dev/null || _rc=$?
assert_eq "returns REG_RC_COMPLETING ($REG_RC_COMPLETING) when installing+healthy" "$REG_RC_COMPLETING" "$_rc"
assert_exists "state.sh preserved (will be overwritten by post_install)" "$regcreds_dir/state.sh"

echo ""
echo "=== Test: reg_detect_existing — installed + healthy (existing) ==="
# Write a state.sh with reg_status=installed
cat > "$regcreds_dir/state.sh" <<-EOF
reg_status=installed
reg_vendor=omr
reg_host=localhost
reg_port=59999
EOF
# The function calls exit 0 (not return 0) when installed+healthy,
# so run in a subshell to catch it
_rc=0
(reg_detect_existing 2>/dev/null)
_rc=$?
assert_eq "exit 0 (already installed, skip)" "0" "$_rc"

echo ""
echo "=== Test: reg_detect_existing — legacy state.sh (no reg_status) + healthy ==="
# Legacy state.sh that doesn't have reg_status field
cat > "$regcreds_dir/state.sh" <<-EOF
reg_vendor=docker
reg_host=localhost
reg_port=59999
EOF
_rc=0
(reg_detect_existing 2>/dev/null)
_rc=$?
assert_eq "exit 0 (legacy installed, skip)" "0" "$_rc"

# Cleanup server
kill "$_server_pid" 2>/dev/null
wait "$_server_pid" 2>/dev/null

echo ""
echo "=== Test: reg_detect_existing — installed + NOT healthy ==="
# Use a port that is definitely not listening
export reg_port="59998"
export reg_url="https://localhost:59998"
cat > "$regcreds_dir/state.sh" <<-EOF
reg_status=installed
reg_vendor=omr
reg_host=localhost
reg_port=59998
EOF
# This calls aba_abort which calls exit, so run in subshell
_output=""
_rc=0
_output=$( (reg_detect_existing) 2>&1 ) || _rc=$?
assert_eq "exits non-zero (abort — installed but unreachable)" "1" "$_rc"
assert_contains "error mentions state.sh" "state.sh" "$_output"
# Restore port
export reg_port="59999"
export reg_url="https://localhost:59999"

echo ""
echo "========================================="
echo "Results: $_pass passed, $_fail failed"
echo "========================================="

[ "$_fail" -eq 0 ] && exit 0 || exit 1
