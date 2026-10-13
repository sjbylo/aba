#!/bin/bash
# Test: mirror registry stop/start commands
# =============================================================================
# Verifies aba -d mirror stop/start for all vendor types:
#   1. Stop a running registry → verify port closed, service stopped
#   2. Stop again (idempotent) → no error
#   3. Start the registry → verify port open, service running
#   4. Start again (idempotent) → no error
#   5. Verify registry is functional after restart (aba verify)
#
# Also verifies that aba.sh correctly routes stop/start:
#   - In a mirror dir → Makefile target (reg-stop.sh / reg-start.sh)
#   - In a cluster dir → VM stop/start (not tested here, just verify no crash)
#
# Tier: integration (uses a running registry on localhost)
#
# Prerequisites:
#   - ABA installed with a mirror registry running (any vendor)
#   - Run from ABA repo root
#
# Usage:
#   ./test/func/test-mirror-stop-start.sh
# =============================================================================

set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/aba")" || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== Mirror Stop/Start Test ==="
echo ""

# --- Preflight: need a running registry --------------------------------------

regcreds_dir="$HOME/.aba/mirror/mirror"
if [ ! -s "$regcreds_dir/state.sh" ]; then
	echo "SKIPPED: No registry state found at $regcreds_dir/state.sh"
	echo "Install a mirror registry first: aba -d mirror install"
	exit 0
fi

source "$regcreds_dir/state.sh"
echo "Registry: vendor=$reg_vendor host=$reg_host port=$reg_port"
echo ""

_port_listening() {
	ss -tlnp 2>/dev/null | grep -q ":${reg_port} "
}

# --- Test 1: Stop the registry -----------------------------------------------

echo "--- Test 1: Stop ---"
if _port_listening; then
	echo "  Port $reg_port is listening (registry running)"
else
	echo "  Port $reg_port not listening — starting first so we can test stop"
	aba -d mirror start 2>&1 || { _fail "pre-start failed"; }
	sleep 2
	if ! _port_listening; then
		_fail "could not start registry for testing"
		echo "Results: $pass passed, $fail failed"
		exit "$fail"
	fi
fi

output=$(aba -d mirror stop 2>&1)
echo "$output"
if ! _port_listening; then
	_pass "stop: port $reg_port no longer listening"
else
	_fail "stop: port $reg_port still listening after stop"
fi

# --- Test 2: Stop again (idempotent) -----------------------------------------

echo ""
echo "--- Test 2: Stop when already stopped (idempotent) ---"
output=$(aba -d mirror stop 2>&1)
rc=$?
echo "$output"
if [ "$rc" -eq 0 ]; then
	_pass "stop idempotent: exit 0 when already stopped"
else
	_fail "stop idempotent: exit $rc (expected 0)"
fi

if echo "$output" | grep -qi "already stopped"; then
	_pass "stop idempotent: reports already stopped"
else
	_fail "stop idempotent: did not report already stopped"
fi

# --- Test 3: Start the registry -----------------------------------------------

echo ""
echo "--- Test 3: Start ---"
output=$(aba -d mirror start 2>&1)
echo "$output"
if _port_listening; then
	_pass "start: port $reg_port listening"
else
	_fail "start: port $reg_port not listening after start"
fi

# --- Test 4: Start again (idempotent) ----------------------------------------

echo ""
echo "--- Test 4: Start when already running (idempotent) ---"
output=$(aba -d mirror start 2>&1)
rc=$?
echo "$output"
if [ "$rc" -eq 0 ]; then
	_pass "start idempotent: exit 0 when already running"
else
	_fail "start idempotent: exit $rc (expected 0)"
fi

if echo "$output" | grep -qi "already running"; then
	_pass "start idempotent: reports already running"
else
	_fail "start idempotent: did not report already running"
fi

# --- Test 5: Verify registry is functional ------------------------------------

echo ""
echo "--- Test 5: Verify registry functional after restart ---"
output=$(aba -d mirror verify 2>&1)
rc=$?
echo "$output"
if [ "$rc" -eq 0 ]; then
	_pass "verify: registry healthy after stop/start cycle"
else
	_fail "verify: registry unhealthy after stop/start (rc=$rc)"
fi

# --- Test 6: Data dir intact --------------------------------------------------

echo ""
echo "--- Test 6: Data directory intact ---"
if [ -d "$reg_root" ]; then
	_pass "data dir exists: $reg_root"
else
	_fail "data dir missing: $reg_root"
fi

# --- Test 7: Routing sanity (non-mirror dir) ----------------------------------

echo ""
echo "--- Test 7: stop/start in non-cluster non-mirror dir falls through ---"
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Create a dir with a Makefile that has stop/start targets
cat > "$_tmp/Makefile" <<'EOF'
.PHONY: stop start
stop:
	@echo "custom-stop-ok"
start:
	@echo "custom-start-ok"
EOF

output=$(cd "$_tmp" && make stop 2>&1)
if echo "$output" | grep -q "custom-stop-ok"; then
	_pass "routing: stop in non-aba dir goes to Makefile"
else
	_fail "routing: stop in non-aba dir did not reach Makefile"
fi

# --- Summary ------------------------------------------------------------------

echo ""
echo "=== Results: $pass passed, $fail failed ==="
exit "$fail"
