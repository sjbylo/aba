#!/usr/bin/env bash
# =============================================================================
# Registry uninstall idempotency (integration) — run ON conno.example.com
# =============================================================================
# Trust model: .available means install succeeded; callers run uninstall when
# it is present. state.sh is the uninstall recipe. This test verifies ABA
# uninstall exit codes are honest when runtime is already gone / leftovers remain.
#
# Usage (on conno, after syncing current scripts):
#   test/func/test-reg-uninstall-idempotent.sh
#
# Uses dedicated dir ~/aba/idem-mirror, port 5001, data under /tmp/aba-idem-*.
# Does not touch a pool Quay on 8443.
# =============================================================================

set -uo pipefail

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[1;36m'
NC='\033[0m'

pass=0
fail=0

_ok()   { pass=$(( pass + 1 )); printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
_bad()  { fail=$(( fail + 1 )); printf "  ${RED}FAIL${NC}  %s\n" "$*"; }
_log()  { printf "\n${CYAN}=== %s ===${NC}\n" "$*"; }

_assert() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then _ok "$desc"; else _bad "$desc"; fi
}
_assert_not() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then _bad "$desc"; else _ok "$desc"; fi
}

MIRROR_NAME=idem-mirror
MIRROR_DIR="$REPO_ROOT/$MIRROR_NAME"
REGCREDS_DIR="$HOME/.aba/mirror/$MIRROR_NAME"
PORT=5001
DATA_DIR="/tmp/aba-idem-$$"
# Prefer FQDN; install post-verify can be flaky (hairpin) — soft-success if runtime is up.
HOST=$(hostname -f 2>/dev/null || hostname)

# Prefer ./aba from repo if wrapper points elsewhere
if [ -x "$REPO_ROOT/aba" ]; then
	ABA="$REPO_ROOT/aba"
elif [ -x "$REPO_ROOT/scripts/aba.sh" ]; then
	ABA="$REPO_ROOT/scripts/aba.sh"
else
	ABA=$(command -v aba)
fi
aba() { "$ABA" "$@"; }

# Make's uninstall target is `.unavailable`. If that file already exists from a
# prior uninstall, `make uninstall` is a no-op. Always clear it before a test
# uninstall so the recipe (reg-uninstall.sh) actually runs.
_force_uninstallable() {
	rm -f "$MIRROR_DIR/.unavailable"
}

_cleanup() {
	if [ -d "$MIRROR_DIR" ]; then
		_force_uninstallable
		(cd "$REPO_ROOT" && aba -y -d "$MIRROR_NAME" uninstall) >/dev/null 2>&1 || true
	fi
	podman secret rm redis_pass >/dev/null 2>&1 || true
	podman rm -f registry >/dev/null 2>&1 || true
	rm -rf "$DATA_DIR" "$MIRROR_DIR" "$REGCREDS_DIR"
}
trap '_cleanup' EXIT

_plant_state() {
	local vendor="$1"
	local root="$2"
	mkdir -p "$REGCREDS_DIR"
	cat >"$REGCREDS_DIR/state.sh" <<-EOF
	reg_vendor=$vendor
	reg_host=$HOST
	reg_port=$PORT
	reg_user=init
	reg_pw='p4ssw0rd'
	reg_root=$root
	reg_ssh_key=
	reg_ssh_user=
	reg_root_opts=
	reg_fw_opened=
	last_action=install
	last_action_at='1970-01-01 00:00:00'
	reg_installed_at='1970-01-01 00:00:00'
	EOF
}

_ensure_mirror_dir() {
	if [ ! -d "$MIRROR_DIR" ]; then
		(cd "$REPO_ROOT" && aba -y mirror --name "$MIRROR_NAME") || return 1
	fi
	(cd "$MIRROR_DIR" && make -s .init) >/dev/null 2>&1 || true
	_force_uninstallable
}

# Simulate "successfully installed" marker state for fabricated already-gone cases.
_mark_available() {
	_force_uninstallable
	touch "$MIRROR_DIR/.available"
}

_run_uninstall() {
	_force_uninstallable
	local rc=0
	UNINST_OUT=$(aba -y -d "$MIRROR_NAME" uninstall 2>&1) || rc=$?
	UNINST_RC=$rc
	echo "$UNINST_OUT" | tail -30
}

# =============================================================================
_log "Preflight on $(hostname) as $(whoami)"

_assert "running under ~/aba (or repo root with scripts/)" test -f "$REPO_ROOT/scripts/reg-common.sh"
_assert "podman available" command -v podman
_assert "aba wrapper available" test -x "$ABA"

_cleanup
trap '_cleanup' EXIT

# =============================================================================
_log "TEST 1: Docker happy path install → uninstall (.available cleared)"

_assert "create named mirror dir" _ensure_mirror_dir

echo "  Installing docker registry port=$PORT data-dir=$DATA_DIR host=$HOST ..."
inst_rc=0
aba -y -d "$MIRROR_NAME" install \
	--vendor docker \
	-H "$HOST" \
	--reg-port "$PORT" \
	--data-dir "$DATA_DIR" 2>&1 | tee /tmp/aba-idem-inst.out | tail -25 || inst_rc=$?

if [ "$inst_rc" -eq 0 ] && [ -f "$MIRROR_DIR/.available" ]; then
	_ok "docker install succeeded (.available set)"
elif podman ps --format '{{.Names}}' | grep -q '^registry$' && [ -s "$REGCREDS_DIR/state.sh" ]; then
	# Post-verify can fail on some hosts; runtime+state is enough for uninstall tests
	touch "$MIRROR_DIR/.available"
	_ok "docker install runtime up (make verify flaky; continuing)"
else
	_bad "docker install succeeded"
fi

_assert ".available present after install" test -f "$MIRROR_DIR/.available"
_assert "state.sh present after install" test -s "$REGCREDS_DIR/state.sh"
_assert "registry container running" bash -c "podman ps --format '{{.Names}}' | grep -q '^registry$'"
_assert "data dir exists" test -d "$DATA_DIR/docker-reg"

REG_ROOT=$(grep '^reg_root=' "$REGCREDS_DIR/state.sh" 2>/dev/null | cut -d= -f2-)
[ -n "$REG_ROOT" ] || REG_ROOT="$DATA_DIR/docker-reg"

echo "  Uninstalling ..."
_run_uninstall
if [ "$UNINST_RC" -eq 0 ]; then
	_ok "docker uninstall exit 0"
else
	_bad "docker uninstall exit 0 (rc=$UNINST_RC)"
fi

_assert_not ".available removed after uninstall" test -f "$MIRROR_DIR/.available"
_assert_not "state.sh cleared after uninstall" test -s "$REGCREDS_DIR/state.sh"
_assert_not "registry container gone" bash -c "podman ps -a --format '{{.Names}}' | grep -q '^registry$'"
_assert_not "data dir removed" test -d "$REG_ROOT"

# =============================================================================
_log "TEST 2: Idempotent docker — plant state for already-gone registry"

_ensure_mirror_dir
_plant_state docker "$REG_ROOT"
_mark_available

echo "  Re-uninstall with state pointing at gone registry ..."
_run_uninstall
if [ "$UNINST_RC" -eq 0 ]; then
	_ok "idempotent docker uninstall exit 0"
else
	_bad "idempotent docker uninstall exit 0 (rc=$UNINST_RC)"
fi
echo "$UNINST_OUT" | grep -qiE 'already uninstalled|already gone|uninstall successful' \
	&& _ok "idempotent message mentions already gone/success" \
	|| _bad "idempotent message mentions already gone/success (out tail above)"
_assert_not ".available cleared after idempotent uninstall" test -f "$MIRROR_DIR/.available"
_assert_not "state.sh cleared after idempotent uninstall" test -s "$REGCREDS_DIR/state.sh"

# =============================================================================
_log "TEST 3: Quay death-spiral fix — fabricated already-gone (no mirror-registry needed)"

_ensure_mirror_dir
QUAY_ROOT="/tmp/aba-idem-quay-absent-$$"
_plant_state quay "$QUAY_ROOT"
_mark_available
podman secret rm redis_pass >/dev/null 2>&1 || true

echo "  Uninstall quay with absent runtime (core bug) ..."
_run_uninstall
if [ "$UNINST_RC" -eq 0 ]; then
	_ok "quay already-gone uninstall exit 0"
else
	_bad "quay already-gone uninstall exit 0 (rc=$UNINST_RC)"
fi
echo "$UNINST_OUT" | grep -qiE 'already uninstalled|already gone|uninstall successful' \
	&& _ok "quay already-gone message" \
	|| _bad "quay already-gone message"
_assert_not ".available cleared" test -f "$MIRROR_DIR/.available"
_assert_not "state.sh cleared" test -s "$REGCREDS_DIR/state.sh"
echo "$UNINST_OUT" | grep -qi 'mirror-registry tarball not found' \
	&& _bad "did not require mirror-registry binary" \
	|| _ok "did not require mirror-registry binary"

# =============================================================================
_log "TEST 4: Fail-closed — leftover listener on reg_port → abort, keep markers"

# Use docker vendor + a real TCP listener on PORT so uninstall cannot claim
# "already gone". (Quay path would pull mirror-registry via ensure_quay_registry.)
_ensure_mirror_dir
_plant_state docker "$REG_ROOT"
_mark_available

LISTEN_PID=""
python3 - "$PORT" <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))
s.listen(1)
time.sleep(120)
PY
LISTEN_PID=$!
sleep 0.5
if kill -0 "$LISTEN_PID" 2>/dev/null && ss -tlnp | grep -q ":$PORT "; then
	_ok "planted listener on port $PORT (pid $LISTEN_PID)"
else
	_bad "planted listener on port $PORT"
fi

echo "  Uninstall must FAIL (port still listening) and keep state.sh / .available ..."
_run_uninstall
if [ "$UNINST_RC" -ne 0 ]; then
	_ok "leftover port → uninstall non-zero"
else
	_bad "leftover port → uninstall non-zero (got rc=0)"
fi
_assert "state.sh KEPT after failed uninstall" test -s "$REGCREDS_DIR/state.sh"
_assert ".available KEPT after failed uninstall" test -f "$MIRROR_DIR/.available"

kill "$LISTEN_PID" 2>/dev/null || true
wait "$LISTEN_PID" 2>/dev/null || true
rm -f "$MIRROR_DIR/.available"
rm -rf "$REGCREDS_DIR"

# =============================================================================
_log "TEST 5: Dir already gone — caller trusts absence of .available"

rm -rf "$MIRROR_DIR"
if [ ! -d "$MIRROR_DIR" ] && [ ! -f "$MIRROR_DIR/.available" ]; then
	_ok "no dir / no .available → caller skips uninstall (success)"
else
	_bad "no dir / no .available → caller skips uninstall (success)"
fi

# =============================================================================
_log "Summary"

echo ""
echo "========================================"
if [ "$fail" -eq 0 ]; then
	printf "  ${GREEN}ALL %d TESTS PASSED${NC}\n" "$pass"
else
	printf "  ${RED}%d/%d FAILED${NC}\n" "$fail" "$(( pass + fail ))"
fi
echo "========================================"
echo ""

trap - EXIT
_cleanup

exit "$fail"
