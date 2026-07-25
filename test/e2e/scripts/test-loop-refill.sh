#!/usr/bin/env bash
# Unit tests for --loop mid-round refill (_loop_refill_queue).
# No pools/SSH required.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"

pass=0
fail=0
_assert() {
	local desc="$1"; shift
	if "$@"; then
		echo "  PASS: $desc"
		pass=$(( pass + 1 ))
	else
		echo "  FAIL: $desc"
		fail=$(( fail + 1 ))
	fi
}

# Minimal env so dispatcher.sh can source
export E2E_TMUX_SESSION="${E2E_TMUX_SESSION:-e2e-suite}"
export E2E_RC_PREFIX="${E2E_RC_PREFIX:-/tmp/e2e-suite-test-loop}"
export E2E_DISPATCH_STATE="${E2E_DISPATCH_STATE:-/tmp/e2e-dispatch-state-test-loop.txt}"
export E2E_INJECT_QUEUE="${E2E_INJECT_QUEUE:-/tmp/e2e-inject-test-loop.txt}"
export E2E_FORCE_RERUN="${E2E_FORCE_RERUN:-/tmp/e2e-force-rerun-test-loop.txt}"
export E2E_FORCED_DISPATCH="${E2E_FORCED_DISPATCH:-/tmp/e2e-forced-dispatch-test-loop.txt}"
export CLI_POOL_LIST="1 2 3 4"
export CLI_LOOP=1
export NOTIFY_CMD="/bin/true"
export VM_BASE_DOMAIN=example.com

# Stubs for anything dispatcher may touch at source/call time
_essh() { return 0; }
_escp() { return 0; }
_ssh_con() { return 0; }
_con_target() { echo "root@con${1}.example.com"; }
_dis_target() { echo "root@dis${1}.example.com"; }
_wait_for_ssh() { return 0; }
_e2e_process_cleanup_dir() { return 0; }
sync_harness() { return 0; }
sync_extras() { return 0; }
sync_source() { return 0; }
sync_dis_aba() { return 0; }
_make_source_tar() { echo "/dev/null"; }
_export_pool_ssh_users() { :; }
_run_cleanup_on_host() { return 0; }
_process_pool_cleanup_files() { return 0; }
_is_running_on_external_pool() { return 1; }
_refresh_external_running() { :; }
_recheck_unreachable_pools() { :; }
_collect_pool_logs() { :; }
_check_hung() { :; }
_notify_periodic_status() { :; }

# Track notify invocations
_NOTIFY_HITS=0
NOTIFY_CMD="$(mktemp)"
cat > "$NOTIFY_CMD" <<'EOF'
#!/bin/bash
echo "$@" >> "${NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$NOTIFY_CMD"
NOTIFY_LOG="$(mktemp)"
export NOTIFY_LOG
export NOTIFY_CMD

source "$_E2E_DIR/lib/constants.sh"
source "$_E2E_DIR/lib/dispatcher.sh"

declare -A _completed=()
declare -A _busy_pools=()
declare -A _results=()
declare -A _result_pool=()
declare -A _retried=()
declare -A _unreachable_pools=()
declare -a _work_queue=()
declare -a suites_to_run=()
declare -a _original_suites=()
_queue_idx=0
_round=1

_reset() {
	_completed=()
	_busy_pools=()
	_results=()
	_result_pool=()
	_retried=()
	_unreachable_pools=()
	_work_queue=()
	suites_to_run=()
	_original_suites=()
	_queue_idx=0
	_round=1
	: > "$NOTIFY_LOG"
}

echo "=== test-loop-refill ==="

# -------------------------------------------------------------------------
echo "--- 1) mid-round refill: queue empty, 1 in-flight, 3 free ---"
_reset
_original_suites=(alpha beta gamma delta)
_busy_pools[4]=delta
_results[alpha]=0
_results[beta]=0
_results[gamma]=0
_result_pool[alpha]=1
_result_pool[beta]=2
_result_pool[gamma]=3
_work_queue=()
_queue_idx=0
_round=1

_rc=0
_loop_refill_queue || _rc=$?

_assert "refill succeeds" [ "$_rc" -eq 0 ]
_assert "round advanced to 2" [ "$_round" -eq 2 ]
_assert "queue non-empty" [ "${#_work_queue[@]}" -gt 0 ]
_assert "in-flight suite excluded from queue" \
	bash -c '! printf "%s\n" "$@" | grep -qx delta' -- "${_work_queue[@]}"
_assert "alpha cleared from results (not in-flight)" [ -z "${_results[alpha]:-}" ]
_assert "delta has no result yet (still in-flight)" [ -z "${_results[delta]:-}" ]
_assert "notify fired once" [ "$(wc -l < "$NOTIFY_LOG")" -eq 1 ]
# queue should be alpha beta gamma (shuffled)
_assert "queued exactly 3 suites" [ "${#_work_queue[@]}" -eq 3 ]

# -------------------------------------------------------------------------
echo "--- 2) all suites in-flight: quiet no-op (no spam) ---"
_reset
_original_suites=(only-one)
_busy_pools[1]=only-one
_work_queue=()
_queue_idx=0
_round=7
: > "$NOTIFY_LOG"

_rc=0
_loop_refill_queue || _rc=$?
_assert "refill fails (nothing available)" [ "$_rc" -eq 1 ]
_assert "round NOT bumped" [ "$_round" -eq 7 ]
_assert "no notify" [ ! -s "$NOTIFY_LOG" ]

# Call thrice more -- still quiet
_loop_refill_queue || true
_loop_refill_queue || true
_loop_refill_queue || true
_assert "still round 7 after repeats" [ "$_round" -eq 7 ]
_assert "still no notify after repeats" [ ! -s "$NOTIFY_LOG" ]

# -------------------------------------------------------------------------
echo "--- 3) full drain (no in-flight): refill all suites ---"
_reset
_original_suites=(a b c)
_results[a]=0
_results[b]=0
_results[c]=1
_work_queue=()
_queue_idx=0
_round=3

_rc=0
_loop_refill_queue || _rc=$?
_assert "refill ok" [ "$_rc" -eq 0 ]
_assert "round 4" [ "$_round" -eq 4 ]
_assert "all 3 re-queued" [ "${#_work_queue[@]}" -eq 3 ]
_assert "failed suite result cleared" [ -z "${_results[c]:-}" ]
_assert "passed suite result cleared" [ -z "${_results[a]:-}" ]

# -------------------------------------------------------------------------
echo "--- 4) CLI_LOOP unset: no refill ---"
_reset
CLI_LOOP=
_original_suites=(a b)
_work_queue=()
_rc=0
_loop_refill_queue || _rc=$?
_assert "refill rejected without --loop" [ "$_rc" -eq 1 ]
CLI_LOOP=1

# -------------------------------------------------------------------------
echo "--- 5) simulate dispatch-loop guard: refill only when queue drained ---"
_reset
_original_suites=(a b c d)
_busy_pools[4]=d
_results[a]=0
_results[b]=0
_results[c]=0
# Queue still has pending work -- caller must NOT refill
_work_queue=(x y)
_queue_idx=0
_round=1
# Emulate caller condition
if [ -n "${CLI_LOOP:-}" ] && [ $_queue_idx -ge ${#_work_queue[@]} ]; then
	_did_refill=1
else
	_did_refill=
fi
_assert "caller does not refill while queue has pending" [ -z "$_did_refill" ]

_queue_idx=2  # past end
_rc=99
if [ -n "${CLI_LOOP:-}" ] && [ $_queue_idx -ge ${#_work_queue[@]} ]; then
	_rc=0
	_loop_refill_queue || _rc=$?
fi
_assert "caller refills when queue drained" [ "$_rc" -eq 0 ]
_assert "d excluded (in-flight)" bash -c '! printf "%s\n" "$@" | grep -qx d' -- "${_work_queue[@]}"

# -------------------------------------------------------------------------
echo "--- 6) after in-flight finishes, next refill includes it ---"
_reset
_original_suites=(a b)
_busy_pools[1]=a
_results[b]=0
_work_queue=()
_queue_idx=0
_round=1
_rc=0
_loop_refill_queue >/dev/null || _rc=$?
_assert "first refill ok" [ "$_rc" -eq 0 ]
_assert "first refill has only b" [ "${#_work_queue[@]}" -eq 1 ] && [ "${_work_queue[0]}" = "b" ]

# a finishes
unset '_busy_pools[1]'
_results[a]=0
_work_queue=()
_queue_idx=0
_rc=0
_loop_refill_queue >/dev/null || _rc=$?
_assert "second refill ok" [ "$_rc" -eq 0 ]
_assert "second refill includes both" [ "${#_work_queue[@]}" -eq 2 ]

# -------------------------------------------------------------------------
echo "--- 7) unset-while-iterate safety: many results cleared ---"
_reset
_original_suites=(s1 s2 s3 s4 s5 s6)
# s3 is in-flight (no result yet); others completed
for i in 1 2 4 5 6; do _results[s$i]=0; done
_busy_pools[2]=s3
_work_queue=()
_queue_idx=0
_rc=0
_loop_refill_queue >/dev/null || _rc=$?
_assert "refill ok with many results" [ "$_rc" -eq 0 ]
_assert "in-flight s3 still has no result entry" [ -z "${_results[s3]:-}" ]
_assert "s1 cleared" [ -z "${_results[s1]:-}" ]
_assert "s2 cleared" [ -z "${_results[s2]:-}" ]
_assert "s4 cleared" [ -z "${_results[s4]:-}" ]
_assert "s5 cleared" [ -z "${_results[s5]:-}" ]
_assert "s6 cleared" [ -z "${_results[s6]:-}" ]
_assert "5 suites queued (s3 excluded)" [ "${#_work_queue[@]}" -eq 5 ]

# Also: if an in-flight suite somehow already has a result, leave it alone
_reset
_original_suites=(x y)
_results[x]=0
_results[y]=0
_busy_pools[1]=y
_work_queue=()
_queue_idx=0
_rc=0
_loop_refill_queue >/dev/null || _rc=$?
_assert "x cleared (finished)" [ -z "${_results[x]:-}" ]
_assert "y result preserved while in-flight" [ "${_results[y]:-}" = "0" ]
_assert "only x queued (count)" [ "${#_work_queue[@]}" -eq 1 ]
_assert "only x queued (name)" [ "${_work_queue[0]}" = "x" ]

# -------------------------------------------------------------------------
echo "--- 8) mini dispatch loop: free pools get work while one suite in-flight ---"
_reset
_original_suites=(fast1 fast2 fast3 slow)
CLI_POOL_LIST="1 2 3 4"
# Round 1 complete except slow on pool 4
_busy_pools[4]=slow
_results[fast1]=0
_results[fast2]=0
_results[fast3]=0
_work_queue=()
_queue_idx=0
_round=1

# Emulate the real call site
_dispatched=()
_find_free_pool() {
	for _p in $CLI_POOL_LIST; do
		[ -z "${_busy_pools[$_p]:-}" ] && { echo "$_p"; return 0; }
	done
	return 1
}
_dispatch_suite() {
	local pool="$1" suite="$2"
	_busy_pools[$pool]="$suite"
	_dispatched+=("$pool:$suite")
	return 0
}

if [ -n "${CLI_LOOP:-}" ] && [ $_queue_idx -ge ${#_work_queue[@]} ]; then
	if _find_free_pool >/dev/null; then
		_loop_refill_queue >/dev/null || true
	fi
fi
while [ $_queue_idx -lt ${#_work_queue[@]} ]; do
	free=$(_find_free_pool) || break
	suite="${_work_queue[$_queue_idx]}"
	[ "${_results[$suite]:-}" = "0" ] && { _queue_idx=$((_queue_idx+1)); continue; }
	_dup=
	for _dp in "${!_busy_pools[@]}"; do
		[ "${_busy_pools[$_dp]}" = "$suite" ] && _dup=1 && break
	done
	[ -n "$_dup" ] && { _queue_idx=$((_queue_idx+1)); continue; }
	_dispatch_suite "$free" "$suite" || true
	_queue_idx=$((_queue_idx+1))
done

_assert "3 free pools received new work" [ "${#_dispatched[@]}" -eq 3 ]
_assert "pool 4 still on slow" [ "${_busy_pools[4]}" = "slow" ]
_assert "pool 1 busy after refill dispatch" [ -n "${_busy_pools[1]:-}" ]
_assert "slow not double-dispatched" bash -c '! printf "%s\n" "$@" | grep -q ":slow$"' -- "${_dispatched[@]}"

rm -f "$NOTIFY_CMD" "$NOTIFY_LOG"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
