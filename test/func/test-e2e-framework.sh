#!/usr/bin/env bash
# =============================================================================
# E2E Framework Lifecycle Tests
# =============================================================================
# Exercises the REAL run.sh + runner.sh path using dummy suites on a single
# pool.  Tests deploy, status, stop, restart, --pool isolation, RC file
# generation, and suite completion detection.
#
# Usage:
#   test/func/test-e2e-framework.sh [POOL]     (default: 3)
#
# Prerequisites:
#   - conN VM must be running and reachable via SSH
#   - No important suite should be running on the target pool
# =============================================================================

set -uo pipefail

POOL="${1:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/../e2e" && pwd)"
RUN="$E2E_DIR/run.sh"

source "$E2E_DIR/lib/constants.sh"
source "$E2E_DIR/config.env" 2>/dev/null || true

_USER="${CON_SSH_USER:-steve}"
_DOMAIN="${VM_BASE_DOMAIN:-example.com}"
_HOST="con${POOL}.${_DOMAIN}"
_TARGET="${_USER}@${_HOST}"
_SSH_OPTS="-o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

_pass=0
_fail=0
_total=0

# --- Helpers -----------------------------------------------------------------

_log()  { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
_ok()   { (( _pass++ )); (( _total++ )); printf "  \033[1;32mPASS\033[0m  %s\n" "$*"; }
_fail() { (( _fail++ )); (( _total++ )); printf "  \033[1;31mFAIL\033[0m  %s\n" "$*"; }

_remote() { ssh $_SSH_OPTS "$_TARGET" "$@" 2>/dev/null; }

_assert() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then
		_ok "$desc"
	else
		_fail "$desc"
	fi
}

_assert_output() {
	local desc="$1" pattern="$2"; shift 2
	local out
	out=$("$@" 2>&1) || true
	if echo "$out" | grep -qE "$pattern"; then
		_ok "$desc"
	else
		_fail "$desc (expected /$pattern/ in output)"
		printf "    got: %s\n" "$(echo "$out" | head -5)"
	fi
}

_assert_no_output() {
	local desc="$1" pattern="$2"; shift 2
	local out
	out=$("$@" 2>&1) || true
	if echo "$out" | grep -qE "$pattern"; then
		_fail "$desc (unexpected /$pattern/ found)"
		printf "    got: %s\n" "$(echo "$out" | head -5)"
	else
		_ok "$desc"
	fi
}

_ensure_clean() {
	ssh $_SSH_OPTS "$_TARGET" \
		"tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null; rm -f ${E2E_RC_PREFIX}-*.rc ${E2E_RC_PREFIX}-*.lock /tmp/e2e-last-suites; true" \
		2>/dev/null || true
}

# Wait for an RC file to appear on the remote host (polls every 2s, up to timeout)
_wait_for_rc() {
	local suite="$1" timeout="${2:-120}"
	local rc_file="${E2E_RC_PREFIX}-${suite}.rc"
	local elapsed=0
	while [ $elapsed -lt $timeout ]; do
		local rc
		rc=$(ssh $_SSH_OPTS "$_TARGET" "cat $rc_file 2>/dev/null" 2>/dev/null || true)
		if [ -n "$rc" ]; then
			echo "$rc"
			return 0
		fi
		sleep 2
		elapsed=$(( elapsed + 2 ))
	done
	echo "TIMEOUT"
	return 1
}

# Dispatch a suite via run.sh (the real path: run.sh -> tmux -> runner.sh)
# Sets E2E_SKIP_SNAPSHOT_REVERT so dummy suites skip VMware infrastructure
_dispatch_suite() {
	local suite="$1"
	_ensure_clean
	# Deploy first
	"$RUN" deploy --pool "$POOL" >/dev/null 2>&1 || true
	# Set the env var on the remote host so runner.sh skips snapshot revert
	_remote "echo '$suite' > /tmp/e2e-last-suites"
	local runner_cmd="E2E_SKIP_SNAPSHOT_REVERT=1 bash ~/aba/test/e2e/runner.sh $POOL $suite"
	_remote "tmux new-session -d -s '$E2E_TMUX_SESSION' '$runner_cmd'" || return 1
}

# --- Preflight ---------------------------------------------------------------

_log "Preflight: pool $POOL (${_HOST})"

_assert "SSH to ${_HOST}" _remote "echo ok"

echo ""
echo "  Cleaning up any previous state on pool $POOL ..."
_ensure_clean

# =============================================================================
# TEST GROUP 1: Deploy
# =============================================================================

_log "TEST 1: Deploy --pool $POOL"

out=$("$RUN" deploy --pool "$POOL" 2>&1) || true
_assert_output "deploy targets only pool $POOL" "con${POOL}:.*done" echo "$out"
for other in 1 2 3 4; do
	[ "$other" = "$POOL" ] && continue
	_assert_no_output "deploy does NOT touch pool $other" "con${other}:" echo "$out"
done

_assert "runner.sh exists on remote" _remote "test -f ~/aba/test/e2e/runner.sh"
_assert "dummy-pass suite exists on remote" _remote "test -f ~/aba/test/e2e/suites/suite-dummy-pass.sh"
_assert "dummy-fail suite exists on remote" _remote "test -f ~/aba/test/e2e/suites/suite-dummy-fail.sh"
_assert "framework.sh exists on remote" _remote "test -f ~/aba/test/e2e/lib/framework.sh"

# =============================================================================
# TEST GROUP 2: Status (idle)
# =============================================================================

_log "TEST 2: Status --pool $POOL (idle)"

out=$("$RUN" status --pool "$POOL" 2>&1) || true
_assert_output "status shows con${POOL}" "con${POOL}" echo "$out"
_assert_output "status shows IDLE" "IDLE" echo "$out"

# =============================================================================
# TEST GROUP 3: Verify RUNNING state detection
# =============================================================================

_log "TEST 3: RUNNING state detection"

# Use a long sleep so the session survives through tests 3-5
_remote "echo 'dummy-pass' > /tmp/e2e-last-suites"
_remote "tmux new-session -d -s '$E2E_TMUX_SESSION' 'sleep 300'"
sleep 1

_assert "tmux session exists" _remote "tmux has-session -t '$E2E_TMUX_SESSION'"

out=$("$RUN" status --pool "$POOL" 2>&1) || true
_assert_output "status shows RUNNING" "RUNNING" echo "$out"
_assert_output "status shows dummy-pass" "dummy-pass" echo "$out"

# =============================================================================
# TEST GROUP 4: Deploy --pool skips running suites
# =============================================================================

_log "TEST 4: Deploy skips running pool (no --force)"

out=$("$RUN" deploy --pool "$POOL" 2>&1) || true
_assert_output "deploy skips running pool" "RUNNING.*skipped" echo "$out"

# =============================================================================
# TEST GROUP 5: Stop --pool
# =============================================================================

_log "TEST 5: Stop --pool $POOL"

out=$("$RUN" stop --pool "$POOL" 2>&1) || true
_assert_output "stop reports stopped" "con${POOL}:.*stopped" echo "$out"

sleep 1
if ssh $_SSH_OPTS "$_TARGET" "tmux has-session -t '$E2E_TMUX_SESSION'" 2>/dev/null; then
	_fail "tmux session gone after stop (session still exists!)"
else
	_ok "tmux session gone after stop"
fi

out=$("$RUN" status --pool "$POOL" 2>&1) || true
_assert_output "status shows IDLE after stop" "IDLE" echo "$out"

# =============================================================================
# TEST GROUP 6: Stop --pool isolation (doesn't touch other pools)
# =============================================================================

_log "TEST 6: Stop --pool isolation"

# Launch a fake session, then stop a DIFFERENT (non-existent) pool
_remote "echo 'dummy-pass' > /tmp/e2e-last-suites"
_remote "tmux new-session -d -s '$E2E_TMUX_SESSION' 'sleep 300'"
sleep 1

_fake_pool=99
out=$("$RUN" stop --pool "$_fake_pool" 2>&1) || true
_assert_no_output "stop --pool $_fake_pool doesn't mention pool $POOL" "con${POOL}" echo "$out"

_assert "original tmux session still alive" _remote "tmux has-session -t '$E2E_TMUX_SESSION'"

_remote "tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null; true"

# =============================================================================
# TEST GROUP 7: Restart --pool
# =============================================================================

_log "TEST 7: Restart --pool $POOL"

"$RUN" deploy --pool "$POOL" >/dev/null 2>&1 || true
_remote "echo 'dummy-pass' > /tmp/e2e-last-suites"

out=$("$RUN" restart --pool "$POOL" 2>&1) || true
_assert_output "restart stops pool" "con${POOL}:.*stopped" echo "$out"
_assert_output "restart deploys" "con${POOL}:.*done" echo "$out"
_assert_output "restart dispatches dummy-pass" "dispatched.*dummy-pass" echo "$out"

sleep 2
_assert "tmux session running after restart" _remote "tmux has-session -t '$E2E_TMUX_SESSION'"

# Clean up for next test
"$RUN" stop --pool "$POOL" >/dev/null 2>&1 || true

# =============================================================================
# TEST GROUP 8: Deploy --pool --force replaces files on running pool
# =============================================================================

_log "TEST 8: Deploy --pool --force (overwrites running)"

_remote "echo 'dummy-pass' > /tmp/e2e-last-suites"
_remote "tmux new-session -d -s '$E2E_TMUX_SESSION' 'sleep 300'"
sleep 1
_assert "tmux session alive before force deploy" _remote "tmux has-session -t '$E2E_TMUX_SESSION'"

out=$("$RUN" deploy --pool "$POOL" --force 2>&1) || true
_assert_output "force deploy shows done" "con${POOL}:.*done" echo "$out"
_assert "files replaced (runner.sh is fresh)" _remote "test -f ~/aba/test/e2e/runner.sh"

_remote "tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null; true"

# =============================================================================
# TEST GROUP 9: Full runner.sh lifecycle -- dummy-pass produces RC=0
# =============================================================================

_log "TEST 9: runner.sh dummy-pass -> RC=0"

_dispatch_suite "dummy-pass"

echo -n "  Waiting for dummy-pass to complete ... "
rc=$(_wait_for_rc "dummy-pass" 60)
echo "$rc"

if [ "$rc" = "0" ]; then
	_ok "dummy-pass RC = 0 (PASS)"
else
	_fail "dummy-pass RC = '$rc' (expected 0)"
fi

_assert "last-suites = dummy-pass" \
	bash -c "[[ \$(ssh $_SSH_OPTS $_TARGET 'cat /tmp/e2e-last-suites 2>/dev/null') == 'dummy-pass' ]]"

# =============================================================================
# TEST GROUP 10: Full runner.sh lifecycle -- dummy-fail produces RC != 0
# =============================================================================

_log "TEST 10: runner.sh dummy-fail -> RC != 0"

_dispatch_suite "dummy-fail"

echo -n "  Waiting for dummy-fail to complete ... "
rc=$(_wait_for_rc "dummy-fail" 120)
echo "$rc"

if [ "$rc" != "0" ] && [ "$rc" != "TIMEOUT" ] && [ "$rc" != "" ]; then
	_ok "dummy-fail RC = $rc (non-zero, as expected)"
else
	_fail "dummy-fail RC = '$rc' (expected non-zero)"
fi

_assert "last-suites = dummy-fail" \
	bash -c "[[ \$(ssh $_SSH_OPTS $_TARGET 'cat /tmp/e2e-last-suites 2>/dev/null') == 'dummy-fail' ]]"

# =============================================================================
# TEST GROUP 11: Status detects completed suite
# =============================================================================

_log "TEST 11: Status after suite completion"

out=$("$RUN" status --pool "$POOL" 2>&1) || true
# After suite finishes, tmux session exits -> pool should show IDLE or COMPLETED
_assert_output "status shows pool $POOL" "con${POOL}" echo "$out"

# =============================================================================
# Cleanup
# =============================================================================

_log "Cleanup"
_ensure_clean
echo "  Pool $POOL cleaned."

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
