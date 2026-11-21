#!/bin/bash
# Test: non-quiet ./install must stop a live run_once job before it deletes
# ~/.aba/runner. Otherwise the setsid child keeps writing the shared
# .downloading path while a second start locks a new file.
#
# Real incident: pool2 kvm-lifecycle 2026-11-15 ~00:28
#   aba --version → download_all_catalogs (job A)
#   Test2 ./install → rm -rf ~/.aba/runner  (no kill)
#   aba --version again → job B STARTED
#   shared .index/.…downloading O_TRUNC → "parser produced empty index"
#
# Tier: unit (no network)

set -u
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

WORKDIR=$(mktemp -d /tmp/test-install-wipe-orphan.XXXXXX)
# install deletes ~/.aba/runner. Point HOME here so the real ./install
# wipes this runner and cannot touch the developer's ~/.aba.
export HOME="$WORKDIR/home"
export RUN_ONCE_DIR="$HOME/.aba/runner"
INDEX_DIR="$WORKDIR/index"
mkdir -p "$RUN_ONCE_DIR" "$INDEX_DIR" "$HOME/bin"
# Identical aba so install exits "already up-to-date" after the wipe,
# and writes only into this HOME/bin.
cp -p scripts/aba.sh "$HOME/bin/aba"
chmod +x "$HOME/bin/aba"

# Same shared path shape as download-catalog-index.sh
SHARED="$INDEX_DIR/.redhat-operator-index-v4.22.downloading"
TASK_ID="catalog:4.22:redhat-operator"
A_RESULT="$WORKDIR/a.result"
B_RESULT="$WORKDIR/b.result"

cleanup() {
	# Best-effort: kill anything still holding our workdir
	if [[ -f "$WORKDIR/a.job_pid" ]]; then
		kill -9 "$(cat "$WORKDIR/a.job_pid")" 2>/dev/null || true
	fi
	if [[ -f "$WORKDIR/b.job_pid" ]]; then
		kill -9 "$(cat "$WORKDIR/b.job_pid")" 2>/dev/null || true
	fi
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "=== install runner wipe → orphan catalog race ==="
echo "  WORKDIR=$WORKDIR"
echo "  Calls non-quiet ./install while a setsid job holds the runner"
echo

# ---------------------------------------------------------------------------
echo "--- 1. Start job A (catalog-like writer), then wipe runner like ./install ---"

# Job A: write a full index, then wait until the shared file is truncated
# (job B) and re-check [ ! -s ] — same post-parse check as download-catalog-index.sh.
run_once -i "$TASK_ID" -- bash -c "
	set +e
	for i in \$(seq 1 80); do
		echo \"repro-op-\$(printf '%03d' \$i) Display stable\"
	done | sort > '$SHARED'
	echo written > '$WORKDIR/a.wrote'
	# Stay in the check long enough that only a kill can end the job.
	# 5s was shorter than a slow ./install and let A exit on its own.
	for _w in \$(seq 1 300); do
		[ ! -s '$SHARED' ] && break
		sleep 0.1
	done
	# Brief dwell while B holds the file empty
	sleep 0.15
	if [ ! -s '$SHARED' ]; then
		echo EMPTY > '$A_RESULT'
		exit 1
	fi
	echo OK > '$A_RESULT'
	exit 0
"

# Wait until A has started and written the shared file
_a_pid=""
for _i in $(seq 1 50); do
	if [[ -f "$RUN_ONCE_DIR/$TASK_ID/pid" ]]; then
		_a_pid=$(cat "$RUN_ONCE_DIR/$TASK_ID/pid" 2>/dev/null || true)
	fi
	[[ -n "$_a_pid" && -f "$WORKDIR/a.wrote" && -s "$SHARED" ]] && break
	sleep 0.05
done

if [[ -z "$_a_pid" ]]; then
	_fail "job A never wrote a pid file"
	echo "Results: $pass passed, $fail failed"
	exit "$fail"
fi
echo "$_a_pid" > "$WORKDIR/a.job_pid"
echo "  job A pid=$_a_pid shared_lines=$(wc -l <"$SHARED")"

# Real non-quiet ./install. PATH lists only this HOME/bin plus system dirs
# so the copy lands here and not in /usr/local/bin or the real ~/bin.
_inst_log="$WORKDIR/install.log"
if env HOME="$HOME" PATH="$HOME/bin:/usr/bin:/bin" ./install >"$_inst_log" 2>&1; then
	if grep -q "Cache cleared" "$_inst_log"; then
		_pass "./install printed Cache cleared"
	else
		_fail "./install did not print Cache cleared"
		sed 's/^/  /' "$_inst_log"
	fi
else
	_fail "./install exited $?"
	sed 's/^/  /' "$_inst_log"
fi

# -G TERM/KILLs, then install returns. Give the waiter a moment to reap.
_a_alive=1
for _i in $(seq 1 20); do
	if ! kill -0 "$_a_pid" 2>/dev/null; then
		_a_alive=0
		break
	fi
	sleep 0.1
done
if [[ "$_a_alive" -eq 0 ]]; then
	_pass "job A is dead after ./install (no orphan setsid child)"
else
	_fail "job A still alive after ./install (pid=$_a_pid)"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 2. Second start on same work_id (aba --version after reinstall) ---"

# Job B: truncate shared path (O_TRUNC as a new sort > would), hold empty
# long enough for A's [ ! -s ] check, then rewrite.
run_once -i "$TASK_ID" -- bash -c "
	set +e
	: > '$SHARED'
	echo truncated > '$WORKDIR/b.truncated'
	sleep 0.8
	for i in \$(seq 1 80); do
		echo \"repro-op-\$(printf '%03d' \$i) Display stable\"
	done | sort > '$SHARED'
	echo DONE > '$B_RESULT'
	exit 0
"

# B must have been allowed to start (fresh runner, lock free)
_b_started=0
for _i in $(seq 1 40); do
	if [[ -f "$RUN_ONCE_DIR/$TASK_ID/history" ]] && grep -q ' STARTED ' "$RUN_ONCE_DIR/$TASK_ID/history"; then
		_b_started=1
		break
	fi
	sleep 0.05
done

if [[ "$_b_started" -eq 1 ]]; then
	_pass "second start STARTED on the fresh runner"
else
	_fail "job B never STARTED after wipe"
fi

_b_pid=$(cat "$RUN_ONCE_DIR/$TASK_ID/pid" 2>/dev/null || true)
if [[ -n "$_b_pid" ]]; then
	echo "$_b_pid" > "$WORKDIR/b.job_pid"
fi
if [[ -n "$_b_pid" && "$_b_pid" != "$_a_pid" ]]; then
	_pass "job B has its own pid (A=$_a_pid B=$_b_pid)"
else
	_fail "expected a new job pid (A=$_a_pid B=$_b_pid)"
fi
if [[ -n "$_b_pid" ]] && kill -0 "$_a_pid" 2>/dev/null; then
	_fail "job A still alive while job B is running"
else
	_pass "job A is not running alongside job B"
fi

# ---------------------------------------------------------------------------
echo
echo "--- 3. Wait for B; the shared file must not look empty to A ---"

# A is already dead on the fixed path, so there is no result file to wait for.
# If the kill missed, give the orphan time to notice B's truncate.
if [[ "$_a_alive" -eq 1 ]]; then
	for _i in $(seq 1 40); do
		[[ -f "$A_RESULT" ]] && break
		sleep 0.1
	done
fi
# Wait for B via run_once
run_once -w -S -q -i "$TASK_ID" 2>/dev/null || true
for _i in $(seq 1 30); do
	[[ -f "$B_RESULT" ]] && break
	sleep 0.1
done

_a_out=$(cat "$A_RESULT" 2>/dev/null || echo missing)
_b_out=$(cat "$B_RESULT" 2>/dev/null || echo missing)
echo "  A result=$_a_out  B result=$_b_out"

if [[ "$_a_out" == "EMPTY" ]]; then
	_fail "job A saw an empty shared .downloading (orphan still parsed)"
else
	_pass "job A did not report an empty index (result=$_a_out)"
fi
if [[ "$_b_out" == "DONE" ]]; then
	_pass "job B finished the shared file on its own"
else
	_fail "job B did not finish (result=$_b_out)"
fi

h="$RUN_ONCE_DIR/$TASK_ID/history"
echo "  --- history after install ---"
sed 's/^/  /' "$h" 2>/dev/null || echo "  (no history)"

_started_n=$(grep -c ' STARTED ' "$h" 2>/dev/null || true)
_started_n=${_started_n:-0}

# The wipe removes A's STARTED. Only B's start belongs in the new file.
# A's waiter may still append one COMPLETE; that is not a second writer.
if [[ "$_started_n" -eq 1 ]]; then
	_pass "post-wipe history has 1 STARTED"
else
	_fail "expected exactly 1 STARTED in post-wipe history (got $_started_n)"
fi
if grep -q "COMPLETE rc=0 .*job_pid=$_b_pid" "$h" 2>/dev/null; then
	_pass "job B COMPLETE rc=0"
else
	_fail "job B did not COMPLETE rc=0"
fi

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
