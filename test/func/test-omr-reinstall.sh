#!/bin/bash
# Test: omr reinstall on existing data dir
# =============================================================================
# Verifies the mirror-registry 3.x (omr) "uninstall → reinstall" workflow:
#   1. Fresh install with -init-password-stdin
#   2. Uninstall (keep data dir) via -auto-approve (no purge)
#   3. Reinstall WITH -init-password-stdin → SUCCEEDS; WARN that password
#      was ignored; original credentials preserved (quay/quay#7636)
#   4. Auth with original password still works
#   5. Uninstall again (keep data)
#   6. Reinstall WITHOUT -init-password-stdin → SUCCEEDS (ABA's path)
#   7. Auth with original password must work after reinstall
#
# This matches the air-gap transfer workflow:
#   connected host: install → push images → uninstall (keep data)
#   disconnected host: transfer data dir → reinstall on top
#
# Upstream (quay/quay#7636 / PROJQUAY-13563):
#   - -auto-approve only skips the prompt; -purge deletes data
#   - install on a pre-initialized data dir succeeds even if
#     -init-password-stdin is passed (warns, keeps existing creds)
# ABA still omits init flags when auth/admin-password exists, but must
# tolerate the upstream "password ignored" path too.
#
# Usage:
#   ./test/func/test-omr-reinstall.sh
#
# Prerequisites:
#   - ABA installed, omr image available (mirror/omr-image.tgz)
#   - Port 5298 free on localhost
# =============================================================================

set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/aba")" || exit 1

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  ${RED}FAIL${NC}  %s\n" "$*"; }

# ---- Configuration ---------------------------------------------------------

DATA_DIR="/tmp/test-omr-reinstall-$$"
PORT=5298
HOST=$(hostname -f)
USER=testuser
PW=TestReinstall2026
BIN=./mirror/omr/mirror-registry
IMAGE=./mirror/omr-image.tgz

# ---- Helpers ----------------------------------------------------------------

cleanup() {
	echo ""
	echo "--- Cleanup ---"
	$BIN uninstall -auto-approve -purge -data-dir "$DATA_DIR" -log-level error 2>/dev/null || true
	rm -rf "$DATA_DIR"
}
trap cleanup EXIT

_uninstall_keep_data() {
	$BIN uninstall -auto-approve -data-dir "$DATA_DIR" 2>&1
}

# ---- Preflight --------------------------------------------------------------

echo "=== OMR Reinstall Test ==="
echo ""

if [ ! -x "$BIN" ]; then
	echo "ERROR: omr binary not found at $BIN"
	echo "Run: aba -d mirror install --vendor omr  (to extract the binary)"
	exit 2
fi

if [ ! -f "$IMAGE" ]; then
	echo "ERROR: omr image archive not found at $IMAGE"
	exit 2
fi

if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
	echo "ERROR: port $PORT already in use"
	exit 2
fi

# ---- Test 1: Fresh install --------------------------------------------------

echo "--- Test 1: Fresh install with -init-password-stdin ---"

if echo "$PW" | $BIN install \
	-data-dir "$DATA_DIR" \
	-hostname "$HOST" \
	-port "$PORT" \
	-init-user "$USER" \
	-init-password-stdin \
	-image-archive "$IMAGE" 2>&1; then
	_pass "fresh install succeeded"
else
	_fail "fresh install failed"
	exit 1
fi

# ---- Test 2: Verify auth works after fresh install --------------------------

echo ""
echo "--- Test 2: Auth works after fresh install ---"

if echo "$PW" | podman login --tls-verify=false -u "$USER" --password-stdin "$HOST:$PORT" 2>&1; then
	_pass "auth works after fresh install"
else
	_fail "auth failed after fresh install"
fi

# ---- Test 3: Uninstall (keep data) ------------------------------------------

echo ""
echo "--- Test 3: Uninstall keeps data dir ---"

_uninstall_keep_data

if [ -f "$DATA_DIR/auth/admin-password" ] && [ -f "$DATA_DIR/quay.db" ]; then
	_pass "data dir preserved after uninstall"
else
	_fail "data dir missing after uninstall"
	exit 1
fi

if [ ! -f "$HOME/.config/containers/systemd/quay.container" ]; then
	_pass "quadlet removed after uninstall"
else
	_fail "quadlet still exists after uninstall"
fi

# ---- Test 4: Reinstall WITH -init-password-stdin → SUCCEEDS (quay#7636) -----

echo ""
echo "--- Test 4: Reinstall WITH -init-password-stdin (succeeds; password ignored) ---"

_out4=$(mktemp)
if echo "$PW" | $BIN install \
	-data-dir "$DATA_DIR" \
	-hostname "$HOST" \
	-port "$PORT" \
	-init-user "$USER" \
	-init-password-stdin \
	-image-archive "$IMAGE" >"$_out4" 2>&1; then
	cat "$_out4"
	_pass "reinstall with -init-password-stdin succeeded"
	if grep -qiE 'init-password-stdin was ignored|already initialized|credentials are unchanged' "$_out4"; then
		_pass "warned that -init-password-stdin was ignored"
	else
		_fail "expected WARN that -init-password-stdin was ignored"
	fi
else
	cat "$_out4"
	_fail "reinstall with -init-password-stdin should succeed (quay/quay#7636)"
	rm -f "$_out4"
	exit 1
fi
rm -f "$_out4"

# ---- Test 5: Original password still works after password-ignored reinstall -

echo ""
echo "--- Test 5: Auth still works with original password ---"

if echo "$PW" | podman login --tls-verify=false -u "$USER" --password-stdin "$HOST:$PORT" 2>&1; then
	_pass "original password still works after password-ignored reinstall"
else
	_fail "original password rejected after password-ignored reinstall"
fi

# ---- Test 6: Uninstall again, then reinstall WITHOUT init flags (ABA path) --

echo ""
echo "--- Test 6: Uninstall again (keep data) ---"

_uninstall_keep_data

if [ -f "$DATA_DIR/auth/admin-password" ] && [ ! -f "$HOME/.config/containers/systemd/quay.container" ]; then
	_pass "data kept and quadlet removed before ABA-style reinstall"
else
	_fail "unexpected state before ABA-style reinstall"
	exit 1
fi

echo ""
echo "--- Test 7: Reinstall WITHOUT -init-password-stdin (ABA path) ---"

if $BIN install \
	-data-dir "$DATA_DIR" \
	-hostname "$HOST" \
	-port "$PORT" \
	-image-archive "$IMAGE" 2>&1; then
	_pass "reinstall without init flags succeeded"
else
	_fail "reinstall without init flags failed"
	exit 1
fi

# ---- Test 8: Auth works with original password after ABA-style reinstall ----

echo ""
echo "--- Test 8: Auth works with original password after ABA-style reinstall ---"

if echo "$PW" | podman login --tls-verify=false -u "$USER" --password-stdin "$HOST:$PORT" 2>&1; then
	_pass "auth works after ABA-style reinstall"
else
	_fail "auth failed after ABA-style reinstall"
fi

# ---- Summary ----------------------------------------------------------------

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -gt 0 ]; then
	exit 1
fi
