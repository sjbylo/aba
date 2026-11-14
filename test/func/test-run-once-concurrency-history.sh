#!/bin/bash
# Test: run_once concurrency + history telemetry contracts
#
# Covers gaps the older suites miss:
#   - SKIP_RUNNING when a second -s hits a held lock
#   - after RESET, two concurrent -s → exactly one STARTED + ≥1 SKIP
#   - STARTED/COMPLETE history carries caller_pid / waiter_pid / job_pid
#   - failed-task TTL cap (effective_ttl ≤ 30s even when -t is larger)

set -u
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

export RUN_ONCE_DIR
RUN_ONCE_DIR=$(mktemp -d /tmp/test-run-once-conc.XXXXXX)
trap 'rm -rf "$RUN_ONCE_DIR"' EXIT

_hist() { echo "$RUN_ONCE_DIR/$1/history"; }

echo "=== run_once concurrency + history ==="
echo "  RUN_ONCE_DIR=$RUN_ONCE_DIR"
echo

# ---------------------------------------------------------------------------
echo "--- 1. History PID fields on STARTED / COMPLETE ---"
ID=test:conc:pids
run_once -i "$ID" -- bash -c 'echo ok; sleep 0.1'
run_once -w -S -i "$ID" || true
h=$(_hist "$ID")
if grep -qE 'STARTED caller_pid=[0-9]+ waiter_pid=[0-9]+ job_pid=[0-9]+' "$h" && \
   grep -qE 'COMPLETE rc=0 caller_pid=[0-9]+ waiter_pid=[0-9]+ job_pid=[0-9]+' "$h"; then
	_pass "STARTED/COMPLETE include caller_pid waiter_pid job_pid"
else
	_fail "history missing PID fields: $(tr '\n' '|' <"$h")"
fi

# job_pid on STARTED matches pid file and COMPLETE
_job=$(grep ' STARTED ' "$h" | tail -1 | grep -oE 'job_pid=[0-9]+' | cut -d= -f2)
_pidf=$(cat "$RUN_ONCE_DIR/$ID/pid" 2>/dev/null || true)
_jobc=$(grep ' COMPLETE ' "$h" | tail -1 | grep -oE 'job_pid=[0-9]+' | cut -d= -f2)
if [[ -n "$_job" && "$_job" == "$_jobc" ]]; then
	_pass "STARTED and COMPLETE share the same job_pid ($_job)"
else
	_fail "job_pid mismatch started=$_job complete=$_jobc pidfile=$_pidf"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 2. SKIP_RUNNING when lock is held ---"
ID=test:conc:skip
rm -rf "$RUN_ONCE_DIR/$ID"
run_once -i "$ID" -- bash -c 'sleep 2'
sleep 0.15
run_once -i "$ID" -- bash -c 'sleep 2'
run_once -w -S -i "$ID" || true
h=$(_hist "$ID")
_starts=$(grep -c ' STARTED ' "$h" || echo 0)
_skips=$(grep -c ' SKIP_RUNNING ' "$h" || echo 0)
if [[ "$_starts" -eq 1 && "$_skips" -ge 1 ]]; then
	_pass "second start while running → SKIP_RUNNING (starts=$_starts skips=$_skips)"
else
	_fail "expected 1 STARTED and ≥1 SKIP, got starts=$_starts skips=$_skips"
	sed 's/^/    /' "$h"
fi
if grep -qE 'SKIP_RUNNING caller_pid=[0-9]+' "$h"; then
	_pass "SKIP_RUNNING logs caller_pid"
else
	_fail "SKIP_RUNNING missing caller_pid"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 3. After RESET: concurrent -s → one STARTED, at least one SKIP ---"
ID=test:conc:reset
_rounds_ok=0
_rounds=8
for round in $(seq 1 "$_rounds"); do
	rm -rf "$RUN_ONCE_DIR/$ID"
	run_once -i "$ID" -- bash -c 'sleep 0.05'
	run_once -w -S -i "$ID" || true
	run_once -r -i "$ID"
	run_once -i "$ID" -- bash -c 'sleep 0.8' &
	_a=$!
	sleep 0.02
	run_once -i "$ID" -- bash -c 'sleep 0.8' &
	_b=$!
	wait "$_a" "$_b" 2>/dev/null || true
	run_once -w -S -i "$ID" || true
	h=$(_hist "$ID")
	# Count STARTED / SKIP only after the last RESET
	_post=$(awk '
		/ RESET / { buf=""; next }
		{ buf = buf $0 ORS }
		END { printf "%s", buf }
	' "$h")
	_starts=$(printf '%s' "$_post" | grep -c ' STARTED ' || echo 0)
	_skips=$(printf '%s' "$_post" | grep -c ' SKIP_RUNNING ' || echo 0)
	# Normalize empty grep -c quirks
	_starts=${_starts:-0}
	_skips=${_skips:-0}
	if [[ "$_starts" -eq 1 && "$_skips" -ge 1 ]]; then
		_rounds_ok=$(( _rounds_ok + 1 ))
	else
		echo "  round $round FAIL: post-RESET starts=$_starts skips=$_skips"
		printf '%s' "$_post" | sed 's/^/    /'
	fi
done
if [[ "$_rounds_ok" -eq "$_rounds" ]]; then
	_pass "RESET+2 concurrent starts: $_rounds/$_rounds rounds had 1 STARTED + SKIP"
else
	_fail "RESET+2 concurrent: only $_rounds_ok/$_rounds rounds clean"
fi
# RESET line must carry caller_pid (pp_cmd optional)
if grep -qE 'RESET caller_pid=[0-9]+' "$(_hist "$ID")"; then
	_pass "RESET logs caller_pid"
else
	_fail "RESET missing caller_pid"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 4. Failed-task TTL cap (≤30s even when -t is larger) ---"
ID=test:conc:failttl
rm -rf "$RUN_ONCE_DIR/$ID"
run_once -i "$ID" -t 120 -- bash -c 'echo fail-run; exit 7'
run_once -w -S -i "$ID" || true
_rc=$(cat "$RUN_ONCE_DIR/$ID/exit" 2>/dev/null || echo missing)
if [[ "$_rc" != "7" ]]; then
	_fail "setup: expected exit 7, got $_rc"
else
	# Backdate exit so age > 30s (failed effective_ttl) but < 120s (requested ttl)
	touch -d '45 seconds ago' "$RUN_ONCE_DIR/$ID/exit"
	run_once -i "$ID" -t 120 -- bash -c 'echo recovered; exit 0'
	run_once -w -S -i "$ID" || true
	h=$(_hist "$ID")
	if grep -q 'TTL_EXPIRED' "$h" && grep -q 'recovered' "$RUN_ONCE_DIR/$ID/log.out" 2>/dev/null; then
		_pass "failed task re-ran after ~30s effective TTL (requested -t 120)"
	else
		_fail "failed TTL cap did not re-run; history=$(tr '\n' '|' <"$h")"
		echo "  log.out=$(cat "$RUN_ONCE_DIR/$ID/log.out" 2>/dev/null)"
	fi
	# Still within 120s of a *success* should cache
	run_once -i "$ID" -t 120 -- bash -c 'echo should-skip; exit 0'
	if grep -q 'should-skip' "$RUN_ONCE_DIR/$ID/log.out" 2>/dev/null; then
		_fail "success within TTL re-ran unexpectedly"
	else
		_pass "successful result still cached under -t 120"
	fi
fi

# ---------------------------------------------------------------------------
echo
echo "========================================"
echo "  PASS: $pass"
echo "  FAIL: $fail"
echo "========================================"
exit "$fail"
