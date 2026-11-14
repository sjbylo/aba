#!/bin/bash
# Test parallel validation / concurrent -w on a completed run_once task

set -u
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

export RUN_ONCE_DIR="$HOME/.aba/runner-test-parallel-validation-$$"
TEST_OUTPUT_DIR="/tmp/aba-test-parallel-validation-$$"
cleanup() { rm -rf "$RUN_ONCE_DIR" "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$RUN_ONCE_DIR" "$TEST_OUTPUT_DIR"

echo "=== run_once parallel validation ==="

echo "--- 1. Sequential validation baseline ---"
output1="$TEST_OUTPUT_DIR/output1.txt"
run_once -i "test:parallel:seq" -- bash -c "
	if [[ -f '$output1' ]]; then exit 0; fi
	echo creating > '$output1'
"
run_once -w -i "test:parallel:seq" || { _fail "first wait failed"; }
if [[ -f "$output1" ]]; then
	_pass "task created output"
else
	_fail "output not created"
fi
_starts1=$(grep -c ' STARTED ' "$RUN_ONCE_DIR/test:parallel:seq/history" || echo 0)
run_once -w -i "test:parallel:seq" || { _fail "validation wait failed"; }
_starts2=$(grep -c ' STARTED ' "$RUN_ONCE_DIR/test:parallel:seq/history" || echo 0)
# Default -w may validate (re-run); with completed exit, STARTED should stay 1
# unless validation restarts — use -S for cache check
run_once -w -S -i "test:parallel:seq" || { _fail "-S wait failed"; }
_starts3=$(grep -c ' STARTED ' "$RUN_ONCE_DIR/test:parallel:seq/history" || echo 0)
if [[ "$_starts1" -eq 1 && "$_starts3" -eq 1 ]]; then
	_pass "cached -S wait does not add STARTED (was $_starts1, now $_starts3)"
else
	_fail "STARTED drifted: $_starts1 → $_starts2 → $_starts3"
fi

echo "--- 2. Parallel waits on completed task ---"
output2="$TEST_OUTPUT_DIR/output2.txt"
echo initial > "$output2"
run_once -i "test:parallel:waits" -- bash -c "
	if [[ -f '$output2' ]]; then exit 0; fi
	echo created > '$output2'
"
run_once -w -i "test:parallel:waits" || { _fail "setup wait failed"; }

_rcs=0
for i in 1 2 3; do
	(
		rc=0
		run_once -q -w -i "test:parallel:waits" || rc=$?
		echo "$rc" > "$TEST_OUTPUT_DIR/pw.$i.rc"
	) &
done
wait
_bad=0
for i in 1 2 3; do
	rc=$(cat "$TEST_OUTPUT_DIR/pw.$i.rc" 2>/dev/null || echo 99)
	[[ "$rc" == "0" ]] || _bad=$(( _bad + 1 ))
done
if [[ "$_bad" -eq 0 && -f "$output2" ]]; then
	_pass "3 parallel -w all rc=0 and output intact"
else
	_fail "parallel waits: bad=$_bad output=$(cat "$output2" 2>/dev/null)"
fi

echo
echo "========================================"
echo "  PASS: $pass"
echo "  FAIL: $fail"
echo "========================================"
exit "$fail"
