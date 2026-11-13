#!/usr/bin/env bash
# Unit tests for the four-day suite history and full-queue ordering.
# No pools or SSH.
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

export E2E_SUITE_HISTORY
E2E_SUITE_HISTORY="$(mktemp)"
export CLI_POOL_LIST="1 2 3 4"
export CLI_LOOP=1
export VM_BASE_DOMAIN=example.com
export NOTIFY_CMD="/bin/true"

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

source "$_E2E_DIR/lib/constants.sh"
source "$_E2E_DIR/lib/dispatcher.sh"

declare -A _completed=()
declare -A _busy_pools=()
declare -A _results=()
declare -A _result_pool=()
declare -A _retried=()
declare -A _bad_pools_map=()
declare -A _pool_infra_fail_count=()
declare -A _pool_cooldown_until=()
declare -a _work_queue=()
declare -a suites_to_run=()
declare -a _original_suites=()
_queue_idx=0
_round=1

_names() {
	printf '%s\n' "$@"
}

echo "=== test-suite-history ==="

# -------------------------------------------------------------------------
echo "--- 1) missing history leaves the order alone ---"
rm -f "$E2E_SUITE_HISTORY"
got=$( _e2e_order_by_history green new red )
_assert "missing file keeps input order" [ "$got" = "$(_names green new red)" ]

# -------------------------------------------------------------------------
echo "--- 2) empty and junk history leaves the order alone ---"
: > "$E2E_SUITE_HISTORY"
got=$( _e2e_order_by_history green new red )
_assert "empty file keeps input order" [ "$got" = "$(_names green new red)" ]

printf '%s\n' "not-a-line" "abc red fail" "1000" >> "$E2E_SUITE_HISTORY"
got=$( _e2e_order_by_history green new red )
_assert "junk lines are ignored" [ "$got" = "$(_names green new red)" ]

# -------------------------------------------------------------------------
echo "--- 3) failures first, unknown next, clean passes last ---"
now=$(date +%s)
old=$(( now - _E2E_SUITE_HISTORY_SECS - 10 ))
cat > "$E2E_SUITE_HISTORY" <<EOF
$now fail-once fail
$now fail-often fail
$now fail-often fail
$now fail-often fail
$now clean-a pass
$now clean-b pass
$old ancient fail
junk leftover words
EOF

got=$( _e2e_order_by_history clean-a fresh fail-once fail-often clean-b )
got_head=$(printf '%s\n' "$got" | head -3)
got_tail=$(printf '%s\n' "$got" | tail -2 | sort)
_assert "failures then the unknown suite" [ "$got_head" = "$(_names fail-often fail-once fresh)" ]
_assert "clean passes are last, in either order" [ "$got_tail" = "$(printf '%s\n' clean-a clean-b | sort)" ]

# Equal failure counts keep the input order.
cat > "$E2E_SUITE_HISTORY" <<EOF
$now beta fail
$now alpha fail
EOF
got=$( _e2e_order_by_history beta alpha )
_assert "equal failure counts stay stable" [ "$got" = "$(_names beta alpha)" ]

# A failure older than four days does not pull a suite forward.
cat > "$E2E_SUITE_HISTORY" <<EOF
$old stale fail
$now fresh pass
EOF
got=$( _e2e_order_by_history stale middle fresh )
_assert "expired failure is no history" [ "$got" = "$(_names stale middle fresh)" ]

# -------------------------------------------------------------------------
echo "--- 4) record appends pass/fail and drops old lines ---"
rm -f "$E2E_SUITE_HISTORY"
printf '%s\n' "$old ancient fail" "not a result" > "$E2E_SUITE_HISTORY"
_e2e_history_record cluster-ops 1
_e2e_history_record kvm-network 0
_assert "record returns success" [ $? -eq 0 ]
_assert "fail line written" grep -q " cluster-ops fail$" "$E2E_SUITE_HISTORY"
_assert "pass line written" grep -q " kvm-network pass$" "$E2E_SUITE_HISTORY"
_assert "old line pruned" bash -c '! grep -q ancient "$1"' _ "$E2E_SUITE_HISTORY"
_assert "junk line pruned" bash -c '! grep -q "not a result" "$1"' _ "$E2E_SUITE_HISTORY"

bad_path="/proc/e2e-history-not-a-dir/history"
_saved_hist="$E2E_SUITE_HISTORY"
E2E_SUITE_HISTORY="$bad_path"
_rc=0
_e2e_history_record cluster-ops 1 || _rc=$?
_assert "unwritable history is ignored" [ "$_rc" -eq 0 ]
E2E_SUITE_HISTORY="$_saved_hist"

# -------------------------------------------------------------------------
echo "--- 5) skip and infra requeue are not suite results ---"
rm -f "$E2E_SUITE_HISTORY"
_result_pool[skipped]=1
_result_pool[crashed]=2
_result_pool[infra]=3
_work_queue=()
_queue_idx=0
_record_result skipped 3
_record_result crashed 1
_record_result infra 99
_assert "skip not logged" bash -c '! grep -q skipped "$1"' _ "$E2E_SUITE_HISTORY"
_assert "real failure logged" grep -q " crashed fail$" "$E2E_SUITE_HISTORY"
_assert "infra requeue not logged" bash -c '! grep -q infra "$1"' _ "$E2E_SUITE_HISTORY"
_assert "infra not stored as a result" [ -z "${_results[infra]:-}" ]
_assert "skip stored but not as history" [ "${_results[skipped]}" = 3 ]

# -------------------------------------------------------------------------
echo "--- 6) full-suite queue uses history; a named list does not ---"
cat > "$E2E_SUITE_HISTORY" <<EOF
$now fail-often fail
$now fail-often fail
$now fail-once fail
$now clean-a pass
$now clean-b pass
EOF
CLI_ALL=
suites_to_run=(clean-a fresh fail-once fail-often clean-b)
_completed=()
_busy_pools=()
_build_work_queue
_assert "named list stays put" [ "${_work_queue[*]}" = "clean-a fresh fail-once fail-often clean-b" ]

CLI_ALL=1
_build_work_queue
_assert "full list puts the most failures first" [ "${_work_queue[0]}" = "fail-often" ]
_assert "full list puts the other failure second" [ "${_work_queue[1]}" = "fail-once" ]
_assert "full list keeps the unknown suite in the middle" [ "${_work_queue[2]}" = "fresh" ]
_tail=$(printf '%s\n' "${_work_queue[3]}" "${_work_queue[4]}" | sort)
_assert "full list ends with both clean passes" [ "$_tail" = "$(printf '%s\n' clean-a clean-b | sort)" ]

# A running suite is still left out after the reorder.
_busy_pools[2]=fail-often
_build_work_queue
_assert "in-flight suite stays off the queue" \
	bash -c '! printf "%s\n" "$@" | grep -qx fail-often' -- "${_work_queue[@]}"
_assert "remaining failure still leads" [ "${_work_queue[0]}" = "fail-once" ]

# -------------------------------------------------------------------------
echo "--- 7) a --loop refill of all suites uses the same order ---"
unset '_busy_pools[2]'
_busy_pools=()
CLI_ALL=1
CLI_LOOP=1
_original_suites=(clean-a fresh fail-once fail-often clean-b)
_results=()
_work_queue=()
_queue_idx=0
_round=1
_loop_refill_queue >/dev/null
_assert "refill leads with the most failures" [ "${_work_queue[0]}" = "fail-often" ]
_assert "refill keeps the unknown suite before clean passes" \
	bash -c '
		fresh_at=0
		i=0
		for n in "$@"; do
			[ "$n" = fresh ] && fresh_at=$i
			i=$(( i + 1 ))
		done
		[ "$fresh_at" -eq 2 ]
	' -- "${_work_queue[@]}"

echo ""
echo "passed: $pass  failed: $fail"
rm -f "$E2E_SUITE_HISTORY"
[ "$fail" -eq 0 ]
