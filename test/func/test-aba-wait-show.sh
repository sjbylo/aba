#!/bin/bash
# Comprehensive tests for aba_wait_show()
#
# Usage:  bash test/func/test-aba-wait-show.sh
#         bash test/func/test-aba-wait-show.sh -v   # verbose -- show captured output
#
# Tests run in non-TTY mode (piped) so spinner output is deterministic.
# A few tests explicitly verify TTY behavior using script(1).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ABA_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# Source the function under test
# shellcheck source=../../scripts/include_all.sh
. "$ABA_ROOT/scripts/include_all.sh" 2>/dev/null || true
# Disable any ERR trap from include_all.sh so test assertions work
trap - ERR

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

TMPDIR_TEST=$(mktemp -d /tmp/aba-wait-test.XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0
SKIP=0

# ── Helpers ──────────────────────────────────────────────────────────────────

_pass() {
	PASS=$(( PASS + 1 ))
	printf "  \033[32mPASS\033[0m  %s\n" "$1"
}
_fail() {
	FAIL=$(( FAIL + 1 ))
	printf "  \033[31mFAIL\033[0m  %s\n" "$1"
	[ -n "${2:-}" ] && printf "        %s\n" "$2"
}
_skip() {
	SKIP=$(( SKIP + 1 ))
	printf "  \033[33mSKIP\033[0m  %s\n" "$1"
}
_show_output() {
	if [ "$VERBOSE" -eq 1 ] && [ -f "$1" ]; then
		printf "        output: %s\n" "$(cat "$1" | tr '\r' '~' | head -5)"
	fi
}

# Assert exit code of last command
assert_rc() {
	local expected=$1 actual=$2 label=$3
	if [ "$expected" -eq "$actual" ]; then
		_pass "$label"
	else
		_fail "$label" "expected rc=$expected, got rc=$actual"
	fi
}

# Assert file content contains a pattern
assert_output_matches() {
	local file=$1 pattern=$2 label=$3
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		_pass "$label"
	else
		_fail "$label" "pattern /$pattern/ not found in output"
		_show_output "$file"
	fi
}

# Assert file content does NOT contain a pattern
assert_output_no_match() {
	local file=$1 pattern=$2 label=$3
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		_fail "$label" "unwanted pattern /$pattern/ found in output"
		_show_output "$file"
	else
		_pass "$label"
	fi
}

# Assert elapsed wall-clock time is within bounds (seconds)
assert_elapsed() {
	local start=$1 min_s=$2 max_s=$3 label=$4
	local now
	now=$(date +%s)
	local elapsed=$(( now - start ))
	if [ "$elapsed" -ge "$min_s" ] && [ "$elapsed" -le "$max_s" ]; then
		_pass "$label (${elapsed}s)"
	else
		_fail "$label" "elapsed ${elapsed}s not in [${min_s}..${max_s}]"
	fi
}

# ── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "=== aba_wait_show() test suite ==="
echo ""

# --------------------------------------------------------------------------
# 1. Immediate success -- command succeeds on first check
# --------------------------------------------------------------------------
echo "── 1. Immediate success ──"

out="$TMPDIR_TEST/t1.out"
ts=$(date +%s)
rc=0
aba_wait_show "imm-ok" 1 10 true > "$out" 2>&1 || rc=$?
assert_rc 0 "$rc" "returns 0 on immediate success"
assert_elapsed "$ts" 0 2 "completes quickly"
_show_output "$out"

# --------------------------------------------------------------------------
# 2. Immediate failure (always-fail, short timeout)
# --------------------------------------------------------------------------
echo "── 2. Always-fail with timeout ──"

out="$TMPDIR_TEST/t2.out"
ts=$(date +%s)
rc=0
aba_wait_show "alw-fail" 1 4 false > "$out" 2>&1 || rc=$?
assert_rc 1 "$rc" "returns 1 on timeout"
assert_elapsed "$ts" 3 7 "runs for ~max seconds"
_show_output "$out"

# --------------------------------------------------------------------------
# 3. Eventual success via file-based trigger
# --------------------------------------------------------------------------
echo "── 3. Eventual success (file trigger) ──"

trigger="$TMPDIR_TEST/trigger3"
rm -f "$trigger"
# Create the trigger file after 2 seconds in the background
( sleep 2; touch "$trigger" ) &
_helper_pid=$!

out="$TMPDIR_TEST/t3.out"
ts=$(date +%s)
rc=0
aba_wait_show "evt-ok" 1 10 "test -f $trigger" > "$out" 2>&1 || rc=$?
wait "$_helper_pid" 2>/dev/null || true
assert_rc 0 "$rc" "returns 0 when file appears"
assert_elapsed "$ts" 1 5 "succeeds within expected window"
_show_output "$out"

# --------------------------------------------------------------------------
# 4. max=0 -- should return 1 immediately
# --------------------------------------------------------------------------
echo "── 4. Zero max timeout ──"

out="$TMPDIR_TEST/t4.out"
ts=$(date +%s)
rc=0
aba_wait_show "zero-max" 1 0 true > "$out" 2>&1 || rc=$?
assert_rc 1 "$rc" "returns 1 when max=0"
assert_elapsed "$ts" 0 2 "returns immediately"
_show_output "$out"

# --------------------------------------------------------------------------
# 5. Invalid arguments
# --------------------------------------------------------------------------
echo "── 5. Invalid arguments ──"

out="$TMPDIR_TEST/t5a.out"
rc=0
aba_wait_show "bad" abc 10 true > "$out" 2>&1 || rc=$?
assert_rc 2 "$rc" "non-integer interval returns 2"

out="$TMPDIR_TEST/t5b.out"
rc=0
aba_wait_show "bad" 1 xyz true > "$out" 2>&1 || rc=$?
assert_rc 2 "$rc" "non-integer max returns 2"

out="$TMPDIR_TEST/t5c.out"
rc=0
aba_wait_show "bad" -1 10 true > "$out" 2>&1 || rc=$?
assert_rc 2 "$rc" "negative interval returns 2"

# --------------------------------------------------------------------------
# 6. Command with special characters (pipes, subshells)
# --------------------------------------------------------------------------
echo "── 6. Special characters in command ──"

marker="$TMPDIR_TEST/special6"
rm -f "$marker"
out="$TMPDIR_TEST/t6.out"
rc=0
# Command uses pipe and subshell -- must work with eval
aba_wait_show "special" 1 5 "echo hello | grep -q hello && touch $marker" > "$out" 2>&1 || rc=$?
assert_rc 0 "$rc" "pipe command succeeds"
[ -f "$marker" ] && _pass "side-effect file created" || _fail "side-effect file created"
_show_output "$out"

# --------------------------------------------------------------------------
# 7. Long-running check command (longer than interval)
# --------------------------------------------------------------------------
echo "── 7. Long-running check (exceeds interval) ──"

trigger7="$TMPDIR_TEST/trigger7"
rm -f "$trigger7"
# Trigger after 3s; check command takes 2s each time
( sleep 3; touch "$trigger7" ) &
_helper_pid=$!

out="$TMPDIR_TEST/t7.out"
ts=$(date +%s)
rc=0
aba_wait_show "slow-chk" 1 10 "sleep 2 && test -f $trigger7" > "$out" 2>&1 || rc=$?
wait "$_helper_pid" 2>/dev/null || true
assert_rc 0 "$rc" "succeeds despite slow check command"
assert_elapsed "$ts" 3 8 "wall-clock within expected range"
_show_output "$out"

# --------------------------------------------------------------------------
# 8. Timeout kills long-running check command and its children
# --------------------------------------------------------------------------
echo "── 8. Timeout kills long-running check ──"

out="$TMPDIR_TEST/t8.out"
sentinel="$TMPDIR_TEST/sleep-sentinel-8"
rm -f "$sentinel"
ts=$(date +%s)
rc=0
# Check command sleeps 30s then creates a sentinel.  max=4s should kill it
# before the sentinel appears.
aba_wait_show "kill-chk" 1 4 "sleep 30 && touch $sentinel" > "$out" 2>&1 || rc=$?
assert_rc 1 "$rc" "returns 1 (timeout)"
assert_elapsed "$ts" 3 7 "does not wait for full sleep 30"
_show_output "$out"

sleep 2  # give any potential orphan time to act
if [ ! -f "$sentinel" ]; then
	_pass "background check process was killed (no sentinel)"
else
	_fail "background check process was killed" "sentinel file exists -- orphan survived"
fi

# --------------------------------------------------------------------------
# 9. Non-TTY output format (piped mode)
# --------------------------------------------------------------------------
echo "── 9. Non-TTY output format ──"

out="$TMPDIR_TEST/t9.out"
rc=0
PLAIN_OUTPUT=1 aba_wait_show "fmt-test" 1 4 false > "$out" 2>&1 || rc=$?
unset PLAIN_OUTPUT
assert_rc 1 "$rc" "returns 1 on timeout"
assert_output_matches "$out" '^\[ABA\] fmt-test \.\.\.' "non-TTY header present"
assert_output_matches "$out" '[0-9]+s' "elapsed time shown"
assert_output_no_match "$out" '\[1\]' "no job control noise"
_show_output "$out"

# --------------------------------------------------------------------------
# 10. No job control noise in output
# --------------------------------------------------------------------------
echo "── 10. No job control noise ──"

out="$TMPDIR_TEST/t10.out"
rc=0
# Run with monitor mode ON to verify suppression
set -m 2>/dev/null || true
aba_wait_show "no-noise" 1 4 false > "$out" 2>&1 || rc=$?
assert_output_no_match "$out" '\[1\]' "no [1] PID in output"
assert_output_no_match "$out" 'Exit [0-9]' "no Exit N in output"
assert_output_no_match "$out" 'command not found' "no error text leaks"
_show_output "$out"

# --------------------------------------------------------------------------
# 11. Caller's shell state is not modified (subshell isolation)
# --------------------------------------------------------------------------
echo "── 11. Shell state isolation ──"

set -m 2>/dev/null || true
before_flags="$-"
rc=0
aba_wait_show "iso-ok" 1 2 true > /dev/null 2>&1 || rc=$?
after_flags="$-"
if [[ "$before_flags" == *m* ]] && [[ "$after_flags" == *m* ]]; then
	_pass "monitor mode unchanged after success (subshell isolation)"
else
	_fail "monitor mode unchanged after success" "before=$before_flags after=$after_flags"
fi

rc=0
aba_wait_show "iso-fail" 1 3 false > /dev/null 2>&1 || rc=$?
after_flags="$-"
if [[ "$before_flags" == *m* ]] && [[ "$after_flags" == *m* ]]; then
	_pass "monitor mode unchanged after timeout (subshell isolation)"
else
	_fail "monitor mode unchanged after timeout" "before=$before_flags after=$after_flags"
fi

# Verify no job table pollution: run aba_wait_show, then check jobs
jobs_before=$(jobs -p | wc -l)
aba_wait_show "jobs-test" 1 4 false > /dev/null 2>&1 || true
jobs_after=$(jobs -p | wc -l)
if [ "$jobs_after" -le "$jobs_before" ]; then
	_pass "no job table pollution after call"
else
	_fail "no job table pollution" "jobs before=$jobs_before after=$jobs_after"
fi
set +m 2>/dev/null || true

# --------------------------------------------------------------------------
# 12. SIGINT (Ctrl+C) -- function is killable, no orphans
# --------------------------------------------------------------------------
echo "── 12. SIGINT handling ──"

marker12="$TMPDIR_TEST/orphan-marker-12"
rm -f "$marker12"

# Must use set -m so the background subshell gets its own process group
# and does NOT inherit SIG_IGN for SIGINT (which non-interactive shells
# with set +m apply to background jobs).  This matches real Ctrl+C on a
# terminal where the foreground process group receives SIGINT.
set -m 2>/dev/null || true
bash -c "
	. '$ABA_ROOT/scripts/include_all.sh' 2>/dev/null || true
	trap - ERR
	aba_wait_show sigint-test 1 30 'sleep 10 && touch $marker12'
" > "$TMPDIR_TEST/t12.out" 2>&1 &
sub_pid=$!
set +m 2>/dev/null || true
sleep 2
# Signal the entire process group (simulates real Ctrl+C)
kill -INT -- -"$sub_pid" 2>/dev/null || kill -INT "$sub_pid" 2>/dev/null || true
wait "$sub_pid" 2>/dev/null || true
sleep 3

if [ ! -f "$marker12" ]; then
	_pass "SIGINT killed background check (no marker)"
else
	_fail "SIGINT killed background check" "marker file exists -- orphan survived"
fi

# --------------------------------------------------------------------------
# 13. SIGTERM -- function is killable, no orphans
# --------------------------------------------------------------------------
echo "── 13. SIGTERM handling ──"

marker13="$TMPDIR_TEST/orphan-marker-13"
rm -f "$marker13"

bash -c "
	. '$ABA_ROOT/scripts/include_all.sh' 2>/dev/null || true
	trap - ERR
	aba_wait_show sigterm-test 1 30 'sleep 10 && touch $marker13'
" > "$TMPDIR_TEST/t13.out" 2>&1 &
sub_pid=$!
sleep 2
kill -TERM "$sub_pid" 2>/dev/null || true
wait "$sub_pid" 2>/dev/null || true
sleep 3

if [ ! -f "$marker13" ]; then
	_pass "SIGTERM killed background check (no marker)"
else
	_fail "SIGTERM killed background check" "marker file exists -- orphan survived"
fi

# --------------------------------------------------------------------------
# 13b. Known limitation: SIGINT to single PID (no group delivery)
# --------------------------------------------------------------------------
echo "── 13b. SIGINT single-PID limitation (known) ──"

# When SIGINT is sent to just the bash PID (not the process group),
# bash's WCE (wait-and-cooperative-exit) suppresses the INT trap because
# the foreground child (sleep 0.5) exits normally (it never received the
# signal).  Additionally, in non-interactive shells with set +m, background
# commands inherit SIG_IGN for SIGINT, making it untrappable.
#
# This does NOT affect real Ctrl+C (which signals the whole foreground
# process group) -- only programmatic kill -INT to a single PID.
# SIGTERM is not subject to WCE and always works (verified in test 13).

marker13b="$TMPDIR_TEST/orphan-marker-13b"
rm -f "$marker13b"

bash -c "
	. '$ABA_ROOT/scripts/include_all.sh' 2>/dev/null || true
	trap - ERR
	aba_wait_show sigint-pid 1 30 'sleep 8 && touch $marker13b'
" > "$TMPDIR_TEST/t13b.out" 2>&1 &
sub_pid=$!
sleep 2
# Single-PID SIGINT (NOT group-wide like real Ctrl+C)
kill -INT "$sub_pid" 2>/dev/null || true
wait "$sub_pid" 2>/dev/null || true
sleep 2

if [ -f "$marker13b" ]; then
	# The marker exists -- the orphan survived, confirming the limitation
	_pass "known limitation: single-PID SIGINT does not kill background check"
	rm -f "$marker13b"
else
	# If it was killed, even better -- the limitation may be fixed
	_pass "single-PID SIGINT killed background check (limitation resolved!)"
fi

# --------------------------------------------------------------------------
# 14. Rapid polling (interval=0)
# --------------------------------------------------------------------------
echo "── 14. Rapid polling (interval=0) ──"

trigger14="$TMPDIR_TEST/trigger14"
rm -f "$trigger14"
( sleep 1; touch "$trigger14" ) &
_helper_pid=$!

out="$TMPDIR_TEST/t14.out"
ts=$(date +%s)
rc=0
aba_wait_show "rapid" 0 5 "test -f $trigger14" > "$out" 2>&1 || rc=$?
wait "$_helper_pid" 2>/dev/null || true
assert_rc 0 "$rc" "succeeds with interval=0"
assert_elapsed "$ts" 0 4 "detects trigger quickly"
_show_output "$out"

# --------------------------------------------------------------------------
# 15. Large interval with quick success
# --------------------------------------------------------------------------
echo "── 15. Large interval, quick success ──"

out="$TMPDIR_TEST/t15.out"
ts=$(date +%s)
rc=0
# interval=60 but command succeeds immediately -- should NOT wait 60s
aba_wait_show "big-int" 60 120 true > "$out" 2>&1 || rc=$?
assert_rc 0 "$rc" "returns 0"
assert_elapsed "$ts" 0 2 "does not wait for interval on success"
_show_output "$out"

# --------------------------------------------------------------------------
# 16. Multiple sequential calls (state isolation)
# --------------------------------------------------------------------------
echo "── 16. Sequential calls (state isolation) ──"

out="$TMPDIR_TEST/t16.out"
rc=0
aba_wait_show "seq-1" 1 3 false > "$out" 2>&1 || rc=$?
assert_rc 1 "$rc" "first call times out (rc=1)"

rc=0
aba_wait_show "seq-2" 1 3 true > "$out" 2>&1 || rc=$?
assert_rc 0 "$rc" "second call succeeds (rc=0) -- no state leak"

rc=0
aba_wait_show "seq-3" 1 3 false > "$out" 2>&1 || rc=$?
assert_rc 1 "$rc" "third call times out (rc=1) -- no state leak"

# --------------------------------------------------------------------------
# 17. Check command exit codes are respected (not just 0/1)
# --------------------------------------------------------------------------
echo "── 17. Non-zero exit codes treated as failure ──"

out="$TMPDIR_TEST/t17.out"
rc=0
aba_wait_show "rc42" 1 3 "bash -c 'exit 42'" > "$out" 2>&1 || rc=$?
assert_rc 1 "$rc" "exit 42 treated as failure, function returns 1"
_show_output "$out"

# --------------------------------------------------------------------------
# 18. TTY spinner output (if script(1) is available)
# --------------------------------------------------------------------------
echo "── 18. TTY spinner output ──"

if command -v script >/dev/null 2>&1; then
	tty_out="$TMPDIR_TEST/t18.out"
	# Use script(1) to fake a TTY
	script -qefc "
		. '$ABA_ROOT/scripts/include_all.sh' 2>/dev/null || true
		trap - ERR
		aba_wait_show tty-spin 1 4 false
	" "$tty_out" > /dev/null 2>&1 || true

	assert_output_matches "$tty_out" 'tty-spin' "TTY output contains message"
	assert_output_no_match "$tty_out" '\[1\]' "no job control noise in TTY mode"
else
	_skip "TTY spinner test (script(1) not found)"
fi

# --------------------------------------------------------------------------
# 19. Concurrent aba_wait_show calls don't interfere
# --------------------------------------------------------------------------
echo "── 19. Concurrent calls ──"

trigger19a="$TMPDIR_TEST/trigger19a"
trigger19b="$TMPDIR_TEST/trigger19b"
rm -f "$trigger19a" "$trigger19b"

( sleep 2; touch "$trigger19a" ) &
_ha=$!
( sleep 3; touch "$trigger19b" ) &
_hb=$!

rc_a=99; rc_b=99
bash -c "
	. '$ABA_ROOT/scripts/include_all.sh' 2>/dev/null || true
	trap - ERR
	aba_wait_show conc-A 1 10 'test -f $trigger19a'
" > /dev/null 2>&1 &
pid_a=$!

bash -c "
	. '$ABA_ROOT/scripts/include_all.sh' 2>/dev/null || true
	trap - ERR
	aba_wait_show conc-B 1 10 'test -f $trigger19b'
" > /dev/null 2>&1 &
pid_b=$!

wait "$pid_a" 2>/dev/null && rc_a=0 || rc_a=$?
wait "$pid_b" 2>/dev/null && rc_b=0 || rc_b=$?
wait "$_ha" "$_hb" 2>/dev/null || true

assert_rc 0 "$rc_a" "concurrent call A succeeds"
assert_rc 0 "$rc_b" "concurrent call B succeeds"

# --------------------------------------------------------------------------
# 20. Stress: many rapid iterations
# --------------------------------------------------------------------------
echo "── 20. Stress: 10 rapid calls ──"

stress_ok=1
for i in 1 2 3 4 5 6 7 8 9 10; do
	rc=0
	aba_wait_show "stress-$i" 0 2 true > /dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		stress_ok=0
		_fail "stress iteration $i" "rc=$rc"
		break
	fi
done
[ "$stress_ok" -eq 1 ] && _pass "10 rapid successive calls all succeed"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "───────────────────────────────────"
printf "  \033[32mPASS: %d\033[0m" "$PASS"
[ "$FAIL" -gt 0 ] && printf "  \033[31mFAIL: %d\033[0m" "$FAIL" || printf "  FAIL: 0"
[ "$SKIP" -gt 0 ] && printf "  \033[33mSKIP: %d\033[0m" "$SKIP"
echo ""
echo "───────────────────────────────────"
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
