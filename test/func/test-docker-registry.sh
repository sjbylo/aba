#!/usr/bin/env bash
# =============================================================================
# Docker Registry Install/Verify/Uninstall Tests
# =============================================================================
# Exercises Docker registry installation with various non-default config values:
#   1. Localhost with custom port, data-dir, user, password
#   2. Remote install (conN -> disN) with custom config
#   3. Localhost with defaults (only vendor + port overridden)
#
# Each test: install -> verify config -> verify runtime -> uninstall -> verify gone.
# Pool Quay on 8443 is never touched.
#
# Usage:
#   test/func/test-docker-registry.sh [POOL]     (default: 3)
#
# Prerequisites:
#   - conN and disN must be reachable via SSH
#   - No suite running on the target pool
#   - Pool Quay registry on 8443 (untouched)
# =============================================================================

set -uo pipefail

POOL="${1:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/../e2e" && pwd)"

source "$E2E_DIR/lib/constants.sh"
source "$E2E_DIR/config.env" 2>/dev/null || true

_USER="${CON_SSH_USER:-steve}"
_DOMAIN="${VM_BASE_DOMAIN:-example.com}"
_CON="con${POOL}.${_DOMAIN}"
_DIS="dis${POOL}.${_DOMAIN}"
_CON_TARGET="${_USER}@${_CON}"
_DIS_TARGET="${_USER}@${_DIS}"
_SSH="ssh -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

_pass=0
_fail=0
_total=0
_log()  { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
_ok()   { (( _pass++ )); (( _total++ )); printf "  \033[1;32mPASS\033[0m  %s\n" "$*"; }
_fail() { (( _fail++ )); (( _total++ )); printf "  \033[1;31mFAIL\033[0m  %s\n" "$*"; }
_con()  { $_SSH "$_CON_TARGET" "$@"; }
_dis()  { $_SSH "$_DIS_TARGET" "$@"; }

_assert() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then _ok "$desc"; else _fail "$desc"; fi
}

_assert_not() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then _fail "$desc"; else _ok "$desc"; fi
}

# Verify a value in state.sh on the conN host
_assert_state() {
	local desc="$1" key="$2" expected="$3"
	local actual
	actual=$(_con "grep '^[[:space:]]*${key}=' ~/.aba/mirror/mirror/state.sh 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' | cut -d= -f2-") || true
	if [ "$actual" = "$expected" ]; then
		_ok "$desc ($key=$actual)"
	else
		_fail "$desc (expected $key=$expected, got '$actual')"
	fi
}

# =============================================================================
# Preflight
# =============================================================================

_log "Preflight: pool $POOL (con=$_CON, dis=$_DIS)"

_assert "SSH to $_CON" _con "echo ok"
_assert "SSH to $_DIS" _dis "echo ok"
_assert "Pool Quay running on 8443" \
	_con "curl -sf -o /dev/null https://${_CON}:8443/health/instance"

# Configure aba (needed for all tests)
echo "  Setting up aba.conf ..."
_con "cd ~/aba && aba reset -f 2>/dev/null; true"
_con "cd ~/aba && aba --noask --platform vmw --channel stable --version p --base-domain p${POOL}.example.com" 2>&1 | tail -1
_con "cd ~/aba && aba -d mirror mirror.conf" 2>&1 | tail -1

_assert "mirror.conf exists" _con "test -f ~/aba/mirror/mirror.conf"

# =============================================================================
# TEST 1: Docker localhost -- custom port, data-dir, user, password
# =============================================================================

_log "TEST 1: Docker localhost with custom config"

T1_PORT=5000
T1_DATADIR="~/my-docker-test"
T1_USER="testuser"
T1_PW="MyT3stPw"

echo "  Installing Docker registry: port=$T1_PORT data-dir=$T1_DATADIR user=$T1_USER ..."
if _con "cd ~/aba && aba -d mirror install \
	--vendor docker \
	-H ${_CON} \
	--reg-port $T1_PORT \
	--data-dir '$T1_DATADIR' \
	--reg-user $T1_USER \
	--reg-password '$T1_PW'" 2>&1; then

	_ok "Docker registry installed (custom config)"

	echo "  Verifying state.sh values ..."
	_assert_state "vendor" "REG_VENDOR" "docker"
	_assert_state "port" "REG_PORT" "$T1_PORT"
	_assert_state "user" "REG_USER" "$T1_USER"
	_assert_state "password" "REG_PW" "$T1_PW"
	_assert_state "host" "REG_HOST" "${_CON}"

	# REG_ROOT should be the expanded data_dir + /docker-reg
	_assert "data dir exists on conN" \
		_con "test -d ~/my-docker-test/docker-reg/data"

	_assert "registry container running" \
		_con "podman ps --format '{{.Names}}' | grep -q '^registry$'"

	_assert "registry port $T1_PORT reachable" \
		_con "curl -k -sf -u $T1_USER:$T1_PW https://${_CON}:${T1_PORT}/v2/"

	_assert "aba mirror verify succeeds" \
		_con "cd ~/aba && aba -d mirror verify"

	echo "  Uninstalling ..."
	_con "cd ~/aba && aba -d mirror uninstall" 2>&1 | tail -3

	_assert_not "registry container gone" \
		_con "podman ps --format '{{.Names}}' | grep -q '^registry$'"

	_assert_not "data dir removed" \
		_con "test -d ~/my-docker-test/docker-reg"

else
	_fail "Docker registry install (custom config)"
fi

_assert "Pool Quay still running on 8443" \
	_con "curl -sf -o /dev/null https://${_CON}:8443/health/instance"

# =============================================================================
# TEST 2: Docker remote install (conN -> disN) with custom config
# =============================================================================

_log "TEST 2: Docker remote install (${_CON} -> ${_DIS}) with custom config"

T2_PORT=5000
T2_DATADIR="~/my-docker-test2"
T2_USER="remoteuser"
T2_PW="R3m0tePw"

# Remote install needs docker-reg-image.tgz; ensure it exists
echo "  Ensuring docker-reg-image.tgz exists ..."
_con "cd ~/aba/mirror && make -s docker-reg-image.tgz" 2>&1 | tail -3
_assert "docker-reg-image.tgz exists" \
	_con "test -f ~/aba/mirror/docker-reg-image.tgz"

echo "  Installing Docker registry on ${_DIS} from ${_CON} ..."
if _con "cd ~/aba && aba -d mirror install \
	--vendor docker \
	-H ${_DIS} \
	-k ~/.ssh/id_rsa \
	--reg-port $T2_PORT \
	--data-dir '$T2_DATADIR' \
	--reg-user $T2_USER \
	--reg-password '$T2_PW'" 2>&1; then

	_ok "Docker registry installed on remote (custom config)"

	echo "  Verifying state.sh values ..."
	_assert_state "vendor" "REG_VENDOR" "docker"
	_assert_state "port" "REG_PORT" "$T2_PORT"
	_assert_state "user" "REG_USER" "$T2_USER"
	_assert_state "password" "REG_PW" "$T2_PW"
	_assert_state "host" "REG_HOST" "${_DIS}"
	_assert "state.sh has SSH key" \
		_con "grep -q 'REG_SSH_KEY=.*id_rsa' ~/.aba/mirror/mirror/state.sh"

	_assert "registry container running on disN" \
		_dis "podman ps --format '{{.Names}}' | grep -q '^registry$'"

	_assert "registry port $T2_PORT reachable on disN" \
		_con "curl -k -sf -u $T2_USER:$T2_PW https://${_DIS}:${T2_PORT}/v2/"

	_assert "data dir exists on disN" \
		_dis "test -d ~/my-docker-test2/docker-reg/data"

	_assert "aba mirror verify succeeds" \
		_con "cd ~/aba && aba -d mirror verify"

	echo "  Uninstalling ..."
	_con "cd ~/aba && aba -d mirror uninstall" 2>&1 | tail -3

	_assert_not "registry container gone on disN" \
		_dis "podman ps --format '{{.Names}}' | grep -q '^registry$'"

	_assert_not "data dir removed on disN" \
		_dis "test -d ~/my-docker-test2/docker-reg"

else
	_fail "Docker registry install on remote (custom config)"
fi

# =============================================================================
# TEST 3: Docker localhost -- default values (only vendor + port overridden)
# =============================================================================

_log "TEST 3: Docker localhost with defaults"

T3_PORT=5000

echo "  Installing Docker registry with defaults (port=$T3_PORT) ..."
# Delete and recreate mirror.conf for a clean slate (Test 2 left reg_user, data_dir, etc.)
_con "rm -f ~/aba/mirror/mirror.conf"
_con "cd ~/aba && aba -d mirror mirror.conf" 2>&1 | tail -1

if _con "cd ~/aba && aba -d mirror install \
	--vendor docker \
	-H ${_CON} \
	--reg-port $T3_PORT" 2>&1; then

	_ok "Docker registry installed (defaults)"

	echo "  Verifying default values in state.sh ..."
	_assert_state "vendor" "REG_VENDOR" "docker"
	_assert_state "port" "REG_PORT" "$T3_PORT"
	_assert_state "user (default)" "REG_USER" "init"
	_assert_state "password (default)" "REG_PW" "p4ssw0rd"

	_assert "default data dir ~/docker-reg exists" \
		_con "test -d ~/docker-reg/data"

	_assert "aba mirror verify succeeds" \
		_con "cd ~/aba && aba -d mirror verify"

	echo "  Uninstalling ..."
	_con "cd ~/aba && aba -d mirror uninstall" 2>&1 | tail -3

	_assert_not "registry container gone" \
		_con "podman ps --format '{{.Names}}' | grep -q '^registry$'"

	_assert_not "default data dir removed" \
		_con "test -d ~/docker-reg"

else
	_fail "Docker registry install (defaults)"
fi

_assert "Pool Quay still running on 8443" \
	_con "curl -sf -o /dev/null https://${_CON}:8443/health/instance"

# =============================================================================
# Final cleanup
# =============================================================================

_log "Final cleanup"
_con "rm -rf ~/my-docker-test ~/my-docker-test2 ~/docker-reg" 2>/dev/null || true
_dis "rm -rf ~/my-docker-test2 ~/docker-reg" 2>/dev/null || true
# Reset mirror state via ABA (only ABA should manage .available)
_con "cd ~/aba && aba -y -d mirror uninstall" 2>/dev/null || true
echo "  Done."

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "========================================"
if [ $_fail -eq 0 ]; then
	printf "  \033[1;32mALL %d TESTS PASSED\033[0m\n" "$_total"
else
	printf "  \033[1;31m%d/%d FAILED\033[0m\n" "$_fail" "$_total"
fi
echo "========================================"
echo ""

exit "$_fail"
