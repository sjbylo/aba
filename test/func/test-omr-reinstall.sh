#!/bin/bash
# Test: omr reinstall on existing data dir
# =============================================================================
# Verifies the mirror-registry 3.x (omr) "uninstall → reinstall" workflow:
#   1. Fresh install with -init-password-stdin
#   2. Uninstall (keep data dir)
#   3. Reinstall WITH -init-password-stdin  → must FAIL (already initialized)
#   4. Reinstall WITHOUT -init-password-stdin → must SUCCEED
#   5. Auth with original password must work after reinstall
#
# This matches the air-gap transfer workflow:
#   connected host: install → push images → uninstall (keep data)
#   disconnected host: transfer data dir → reinstall on top
#
# Upstream ref: the omr binary rejects -init-password-stdin when it
# detects an existing database. ABA handles this in reg-install-omr.sh
# by omitting init flags when auth/admin-password exists.
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
	echo y | $BIN uninstall -data-dir "$DATA_DIR" 2>/dev/null || true
	rm -rf "$DATA_DIR"
}
trap cleanup EXIT

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

echo y | $BIN uninstall -data-dir "$DATA_DIR" 2>&1

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

# ---- Test 4: Reinstall WITH -init-password-stdin → must FAIL ----------------

echo ""
echo "--- Test 4: Reinstall WITH -init-password-stdin (should fail) ---"

if echo "$PW" | $BIN install \
	-data-dir "$DATA_DIR" \
	-hostname "$HOST" \
	-port "$PORT" \
	-init-user "$USER" \
	-init-password-stdin \
	-image-archive "$IMAGE" 2>&1; then
	_fail "reinstall with -init-password-stdin should have failed"
else
	_pass "reinstall with -init-password-stdin correctly rejected"
fi

# ---- Test 5: Reinstall WITHOUT -init-password-stdin → must SUCCEED ----------

echo ""
echo "--- Test 5: Reinstall WITHOUT -init-password-stdin (should work) ---"

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

# ---- Test 6: Auth works with original password after reinstall --------------

echo ""
echo "--- Test 6: Auth works with original password after reinstall ---"

if echo "$PW" | podman login --tls-verify=false -u "$USER" --password-stdin "$HOST:$PORT" 2>&1; then
	_pass "auth works after reinstall"
else
	_fail "auth failed after reinstall"
fi

# ---- Summary ----------------------------------------------------------------

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [ "$fail" -gt 0 ]; then
	exit 1
fi
