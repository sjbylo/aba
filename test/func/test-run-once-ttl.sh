#!/bin/bash
# Test: run_once -t (TTL) with real pass/fail asserts

set -u
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

export RUN_ONCE_DIR="/tmp/test-run-once-ttl-$$"
rm -rf "$RUN_ONCE_DIR"
mkdir -p "$RUN_ONCE_DIR"
trap 'rm -rf "$RUN_ONCE_DIR"' EXIT

OUT="$RUN_ONCE_DIR/output.txt"
: >"$OUT"

echo "=== run_once TTL ==="

echo "--- 1. First run executes ---"
run_once -i "test:ttl:task1" -t 5 -- bash -c "echo First >> '$OUT'"
run_once -w -S -i "test:ttl:task1" || true
if grep -qx 'First' "$OUT" && [[ $(wc -l <"$OUT") -eq 1 ]]; then
	_pass "first run wrote output"
else
	_fail "first run output wrong: $(cat "$OUT")"
fi

echo "--- 2. Within TTL skips ---"
run_once -i "test:ttl:task1" -t 5 -- bash -c "echo Second >> '$OUT'"
run_once -w -S -i "test:ttl:task1" || true
if grep -q Second "$OUT"; then
	_fail "second run executed within TTL"
else
	_pass "second run skipped within TTL"
fi

echo "--- 3. After TTL expires, runs again ---"
sleep 6
run_once -i "test:ttl:task1" -t 5 -- bash -c "echo Third >> '$OUT'"
run_once -w -S -i "test:ttl:task1" || true
if grep -q Third "$OUT" && grep -q 'TTL_EXPIRED' "$RUN_ONCE_DIR/test:ttl:task1/history"; then
	_pass "third run after TTL + TTL_EXPIRED in history"
else
	_fail "TTL expiry did not re-run or missing TTL_EXPIRED"
fi

echo "--- 4. wait mode + TTL ---"
: >"$OUT"
run_once -w -i "test:ttl:task2" -t 3 -- bash -c "echo T2a >> '$OUT'; sleep 0.2"
run_once -w -S -i "test:ttl:task2" -t 3 -- bash -c "echo T2skip >> '$OUT'" || true
if grep -q T2a "$OUT" && ! grep -q T2skip "$OUT"; then
	_pass "wait-mode caches within TTL (-S)"
else
	_fail "wait-mode TTL cache wrong: $(cat "$OUT")"
fi
sleep 4
run_once -w -i "test:ttl:task2" -t 3 -- bash -c "echo T2b >> '$OUT'; sleep 0.2"
if grep -q T2b "$OUT"; then
	_pass "wait-mode re-runs after TTL"
else
	_fail "wait-mode did not re-run after TTL"
fi

echo "--- 5. Peek after complete ---"
if run_once -p -i "test:ttl:task2"; then
	_pass "peek returns 0 for completed task"
else
	_fail "peek returned non-zero for completed task"
fi
if run_once -p -i "test:ttl:never"; then
	_fail "peek returned 0 for missing task"
else
	_pass "peek returns non-zero for missing task"
fi

echo
echo "========================================"
echo "  PASS: $pass"
echo "  FAIL: $fail"
echo "========================================"
exit "$fail"
