#!/bin/bash
# Functional tests for try_cmd()
#
# Usage:  bash test/func/test-try-cmd.sh
#         bash test/func/test-try-cmd.sh -v   # verbose -- show captured output

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ABA_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# Source the function under test
# shellcheck source=../../scripts/include_all.sh
export INFO_ABA=1
. "$ABA_ROOT/scripts/include_all.sh" 2>/dev/null || true
trap - ERR

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (expected='$expected', got='$actual')"
	fi
}

assert_contains() {
	local label="$1" pattern="$2" text="$3"
	if echo "$text" | grep -q "$pattern"; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (pattern='$pattern' not found in output)"
		[ "$VERBOSE" = 1 ] && echo "    output: $text"
	fi
}

assert_not_contains() {
	local label="$1" pattern="$2" text="$3"
	if ! echo "$text" | grep -q "$pattern"; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (pattern='$pattern' unexpectedly found in output)"
		[ "$VERBOSE" = 1 ] && echo "    output: $text"
	fi
}

# Helper: a command that fails N times then succeeds
_fail_counter_file=$(mktemp /tmp/try-cmd-test.XXXXXX)
trap 'rm -f "$_fail_counter_file"' EXIT

_reset_fail_counter() {
	echo 0 > "$_fail_counter_file"
}

_cmd_fail_n_times() {
	local n=$1; shift
	local count
	count=$(< "$_fail_counter_file")
	count=$(( count + 1 ))
	echo "$count" > "$_fail_counter_file"
	if [ "$count" -le "$n" ]; then
		echo "deliberate failure $count/$n" >&2
		return 1
	fi
	return 0
}

echo "=== try_cmd() functional tests ==="
echo

# ── 1. Basic success on first attempt ────────────────────────────────
echo "Test 1: Command succeeds on first attempt"
rc=0
out=$(try_cmd -n 3 -d 0 -- true 2>&1) || rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_contains "shows attempt message" "Attempt 1/3" "$out"
assert_contains "shows OK message" "true" "$out"

# ── 2. Command fails all attempts ────────────────────────────────────
echo "Test 2: Command fails all attempts"
rc=0
out=$(try_cmd -n 3 -d 0 -- false 2>&1) || rc=$?
assert_eq "exit code is non-zero" "1" "$rc"
assert_contains "shows failure message" "Failed after 3 attempts" "$out"

# ── 3. Command succeeds on 2nd attempt ──────────────────────────────
echo "Test 3: Command succeeds on 2nd attempt"
_reset_fail_counter
rc=0
out=$(try_cmd -n 3 -d 0 -m "flaky-op" -- bash -c "$(declare -f _cmd_fail_n_times); _cmd_fail_n_times 1 $_fail_counter_file" 2>&1) || rc=$?
# The bash -c approach won't work because of file path. Use a different approach.
# Reset and use a simpler mechanism.

# Use a temp file as a counter directly
_tc_file=$(mktemp /tmp/try-cmd-tc.XXXXXX)
echo 0 > "$_tc_file"
rc=0
out=$(try_cmd -n 3 -d 0 -m "flaky-op" -- bash -c '
	count=$(< "'"$_tc_file"'")
	count=$(( count + 1 ))
	echo "$count" > "'"$_tc_file"'"
	[ "$count" -ge 2 ]
' 2>&1) || rc=$?
assert_eq "exit code is 0 (succeeded on attempt 2)" "0" "$rc"
assert_contains "shows retry warning" "flaky-op failed" "$out"
assert_contains "shows OK" "flaky-op" "$out"
rm -f "$_tc_file"

# ── 4. Single attempt (no retry) ────────────────────────────────────
echo "Test 4: Single attempt — no retry"
rc=0
out=$(try_cmd -n 1 -d 0 -- true 2>&1) || rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_not_contains "no OK message for single attempt" "OK" "$out"

rc=0
out=$(try_cmd -n 1 -d 0 -- false 2>&1) || rc=$?
assert_eq "exit code is 1" "1" "$rc"
assert_contains "shows failure" "Failed after 1 attempts" "$out"

# ── 5. -q (quiet) mode ──────────────────────────────────────────────
echo "Test 5: Quiet mode (-q)"
rc=0
out=$(try_cmd -q -n 3 -d 0 -- false 2>&1) || rc=$?
assert_not_contains "no attempt messages" "Attempt" "$out"
assert_not_contains "no retry warnings" "retrying" "$out"
assert_contains "still shows final failure" "Failed after 3" "$out"

# ── 6. -Q (silent) mode ─────────────────────────────────────────────
echo "Test 6: Silent mode (-Q)"
rc=0
out=$(try_cmd -Q -n 3 -d 0 -- false 2>&1) || rc=$?
assert_eq "exit code is 1" "1" "$rc"
assert_eq "no output at all" "" "$out"

rc=0
out=$(try_cmd -Q -n 1 -d 0 -- true 2>&1) || rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_eq "no output at all on success" "" "$out"

# ── 7. -m (message) label ───────────────────────────────────────────
echo "Test 7: Custom label (-m)"
rc=0
out=$(try_cmd -n 2 -d 0 -m "Pull my-image" -- false 2>&1) || rc=$?
assert_contains "label in attempt" "Pull my-image" "$out"
assert_contains "label in failure" "Pull my-image" "$out"

# ── 8. Default label (first word of command) ─────────────────────────
echo "Test 8: Default label from command"
rc=0
out=$(try_cmd -n 1 -d 0 -- echo hello 2>&1) || rc=$?
assert_contains "label is command name" "echo" "$out"

# ── 9. Increasing backoff (-D) ──────────────────────────────────────
echo "Test 9: Increasing backoff (-D) timing"
_tc_file2=$(mktemp /tmp/try-cmd-tc2.XXXXXX)
: > "$_tc_file2"
start_time=$(date +%s)
rc=0
# 3 attempts, delay 1s, increase 1s → sleeps are 1s, 2s = 3s total
try_cmd -Q -n 3 -d 1 -D 1 -- false 2>/dev/null || rc=$?
elapsed=$(( $(date +%s) - start_time ))
rm -f "$_tc_file2"
assert_eq "exit code is 1" "1" "$rc"
# Should take ~3s (1s + 2s). Allow range 2-5.
if [ "$elapsed" -ge 2 ] && [ "$elapsed" -le 5 ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: elapsed ${elapsed}s is in expected range (2-5s for 1+2=3s backoff)"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: elapsed ${elapsed}s outside expected range 2-5s"
fi

# ── 10. Fixed delay (-d without -D) ─────────────────────────────────
echo "Test 10: Fixed delay (no -D)"
start_time=$(date +%s)
rc=0
# 3 attempts, delay 1s, no increase → sleeps are 1s, 1s = 2s total
try_cmd -Q -n 3 -d 1 -- false 2>/dev/null || rc=$?
elapsed=$(( $(date +%s) - start_time ))
assert_eq "exit code is 1" "1" "$rc"
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -le 4 ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: elapsed ${elapsed}s is in expected range (1-4s for 1+1=2s fixed)"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: elapsed ${elapsed}s outside expected range 1-4s"
fi

# ── 11. No command specified ─────────────────────────────────────────
echo "Test 11: No command — should error"
rc=0
out=$(try_cmd 2>&1) || rc=$?
assert_eq "exit code is 1" "1" "$rc"
assert_contains "error message" "no command specified" "$out"

# ── 12. Preserves exit code from command ─────────────────────────────
echo "Test 12: Preserves original exit code"
rc=0
out=$(try_cmd -Q -n 1 -- bash -c 'exit 42' 2>&1) || rc=$?
assert_eq "exit code is 42" "42" "$rc"

# ── 13. -- separator works ───────────────────────────────────────────
echo "Test 13: -- separator"
rc=0
out=$(try_cmd -n 1 -d 0 -- echo -n hello 2>&1) || rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_contains "command ran correctly" "hello" "$out"

# ── 14. Command with arguments containing spaces ────────────────────
echo "Test 14: Command with spaces in args"
_tc_file3=$(mktemp /tmp/try-cmd-tc3.XXXXXX)
rc=0
try_cmd -Q -n 1 -- bash -c "echo 'hello world' > '$_tc_file3'" || rc=$?
result=$(< "$_tc_file3")
rm -f "$_tc_file3"
assert_eq "exit code is 0" "0" "$rc"
assert_eq "content is correct" "hello world" "$result"

# ── 15. Defaults: -n 3, -d 5 ────────────────────────────────────────
echo "Test 15: Default values"
rc=0
out=$(try_cmd -d 0 -- true 2>&1) || rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_contains "default attempts is 3" "1/3" "$out"

# ── Summary ──────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
