#!/bin/bash
# Reproducer: shared .downloading path race in catalog index parse
#
# Product today (download-catalog-index.sh + catalog-extract-functions.sh):
#   tmp_file=".index/.${catalog}-index-v${ver}.downloading"  # SHARED across PIDs
#   _extract_catalog_dir ends with:  ... | sort > "$outfile" # O_TRUNC
#   then:  if [ ! -s "$tmp_file" ]; then abort; fi
#   flock covers podman create/cp only — NOT parse + check + mv
#
# Race:
#   PID-A finishes sort > SHARED, about to test -s
#   PID-B opens SHARED with O_TRUNC (starts its sort)
#   PID-A sees empty → "parser produced empty index" while /configs still full
#
# Three proposed fixes (FIX path in this script only — no scripts/ edits):
#   1. Parse into a per-run temp file; mv onto the real index after checks.
#   2. Hold the catalog lock through parse + checks + mv.
#   3. If empty but extract has files: re-parse once and print file count.
#
# Run: test/func/repro-catalog-downloading-race.sh

set -u
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=scripts/catalog-extract-functions.sh
source scripts/catalog-extract-functions.sh

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

WORKDIR=$(mktemp -d /tmp/repro-catalog-dl-race.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

CONFIGS="$WORKDIR/configs"
INDEX_DIR="$WORKDIR/index"
mkdir -p "$CONFIGS" "$INDEX_DIR"

SHARED="$INDEX_DIR/.redhat-operator-index-v4.22.downloading"
FINAL="$INDEX_DIR/redhat-operator-index-v4.22"
LOCK="$WORKDIR/catalog.lock"
EXPECTED=20

for i in $(seq 1 "$EXPECTED"); do
	name="repro-op-$(printf '%02d' "$i")"
	mkdir -p "$CONFIGS/$name"
	printf '%s\n' "{\"schema\":\"olm.package\",\"name\":\"$name\",\"defaultChannel\":\"stable\",\"displayName\":\"$name\"}" \
		>"$CONFIGS/$name/package.json"
done

echo "=== Repro: shared .downloading truncate race ==="
echo "  workdir: $WORKDIR"
echo

# ---------------------------------------------------------------------------
# 1. Explicit race: check -s after write while sibling re-opens with O_TRUNC
# ---------------------------------------------------------------------------
echo "--- 1. BUG: post-write -s check vs sibling O_TRUNC on shared path ---"

# PID-A: write full index, pause (simulates scheduling gap before [ ! -s ]), then check.
# PID-B: during A's pause, open SHARED with O_TRUNC and hold it empty (start of sort >).
# That is the product failure mode: empty index abort while configs are intact.
_bug_writer_a() {
	(
		local i
		for i in $(seq 1 100); do
			echo "repro-op-$(printf '%03d' "$i") Display stable"
		done
	) | sort >"$SHARED"
	# Gap before the size check — product does this immediately; under load a
	# second download-catalog-index.sh still lands here.
	sleep 0.1
	if [ ! -s "$SHARED" ]; then
		echo "A:EMPTY"
		return 1
	fi
	echo "A:OK:$(wc -l <"$SHARED")"
}

_bug_truncator_b() {
	# Wait until A has a non-empty file, then truncate+hold (O_TRUNC of sort >).
	local i
	for i in $(seq 1 50); do
		[ -s "$SHARED" ] && break
		sleep 0.01
	done
	# Truncate the shared path and keep it empty through A's check window.
	: >"$SHARED"
	sleep 0.15
	# B would then rewrite; irrelevant — A already failed the -s check.
	(
		local j
		for j in $(seq 1 100); do
			echo "repro-op-$(printf '%03d' "$j") Display stable"
		done
	) | sort >"$SHARED"
	echo "B:DONE"
}

_bug_hit=0
for round in $(seq 1 10); do
	rm -f "$SHARED"
	_bug_writer_a >"$WORKDIR/bug-a.out" &
	_pa=$!
	_bug_truncator_b >"$WORKDIR/bug-b.out" &
	_pb=$!
	wait "$_pa"
	_ra=$?
	wait "$_pb"
	_rb=$?
	_oa=$(cat "$WORKDIR/bug-a.out" 2>/dev/null || true)
	_ob=$(cat "$WORKDIR/bug-b.out" 2>/dev/null || true)
	if [[ "$_oa" == *EMPTY* ]]; then
		_bug_hit=1
		echo "  reproduced round $round: a=$_oa(rc=$_ra) b=$_ob(rc=$_rb)"
		echo "  sibling O_TRUNC held shared file empty during A's [ ! -s ] check"
		break
	fi
done

if [ "$_bug_hit" -eq 1 ]; then
	_pass "BUG: empty index via shared .downloading O_TRUNC during -s check"
else
	_fail "BUG: did not reproduce empty check in 10 rounds"
fi

# ---------------------------------------------------------------------------
# 2. Same race with the real _extract_catalog_dir helper
# ---------------------------------------------------------------------------
echo
echo "--- 2. BUG: real _extract_catalog_dir + shared path + truncator ---"

_real_writer_a() {
	rm -f "$WORKDIR/a-wrote"
	_extract_catalog_dir "$CONFIGS" "$SHARED"
	# Mark only after sort has closed the outfile (extract returns).
	touch "$WORKDIR/a-wrote"
	sleep 0.1
	if [ ! -s "$SHARED" ]; then
		_fc=$(find "$CONFIGS" -type f | wc -l)
		echo "A:EMPTY files=$_fc"
		return 1
	fi
	echo "A:OK:$(wc -l <"$SHARED")"
}

_real_truncator_b() {
	local i
	for i in $(seq 1 200); do
		[ -f "$WORKDIR/a-wrote" ] && break
		sleep 0.01
	done
	# Second download opens the same .downloading path → O_TRUNC.
	: >"$SHARED"
	sleep 0.15
	_extract_catalog_dir "$CONFIGS" "$SHARED"
	echo "B:DONE"
}

_real_hit=0
for round in $(seq 1 10); do
	rm -f "$SHARED" "$WORKDIR/a-wrote"
	_real_writer_a >"$WORKDIR/real-a.out" &
	_pa=$!
	_real_truncator_b >"$WORKDIR/real-b.out" &
	_pb=$!
	wait "$_pa"; _ra=$?
	wait "$_pb"; _rb=$?
	_oa=$(cat "$WORKDIR/real-a.out" 2>/dev/null || true)
	_ob=$(cat "$WORKDIR/real-b.out" 2>/dev/null || true)
	if [[ "$_oa" == *EMPTY* ]]; then
		_real_hit=1
		echo "  reproduced round $round: a=$_oa(rc=$_ra) b=$_ob(rc=$_rb)"
		echo "  configs untouched — failure is shared outfile truncate, not missing copy"
		break
	fi
done

if [ "$_real_hit" -eq 1 ]; then
	_pass "BUG: real parser sees empty index on shared .downloading under race"
else
	_fail "BUG: real parser race not seen in 10 rounds"
fi

# ---------------------------------------------------------------------------
# 3. FIX: per-run outfile + lock through parse/check/mv + empty retry
# ---------------------------------------------------------------------------
_configs_file_count() { find "$CONFIGS" -type f 2>/dev/null | wc -l; }

_fix_one_parse() {
	local run_tmp outfile n _fc
	run_tmp=$(mktemp -d "$WORKDIR/run.XXXXXX")
	outfile="$run_tmp/index.partial"

	(
		flock -w 30 9 || exit 99
		# Fix 1
		_extract_catalog_dir "$CONFIGS" "$outfile"
		# Same post-write pause the BUG path uses — must still be safe
		sleep 0.05

		# Fix 3
		if [ ! -s "$outfile" ]; then
			_fc=$(_configs_file_count)
			echo "WARN: empty index but configs has ${_fc} files — re-parsing" >&2
			_extract_catalog_dir "$CONFIGS" "$outfile"
			if [ ! -s "$outfile" ]; then
				echo "EMPTY_AFTER_RETRY files=${_fc}"
				rm -rf "$run_tmp"
				exit 1
			fi
		fi

		n=$(wc -l <"$outfile")
		if [ "$n" -ne "$EXPECTED" ]; then
			echo "PARTIAL:$n"
			rm -rf "$run_tmp"
			exit 1
		fi

		# Fix 2
		mv "$outfile" "$FINAL"
		rm -rf "$run_tmp"
		echo "OK:$n"
		exit 0
	) 9>"$LOCK"
}

echo
echo "--- 3. FIX: per-run outfile + flock (same timing stress as BUG) ---"
_fix_fail=0
for round in $(seq 1 30); do
	rm -f "$FINAL"
	_fix_one_parse >"$WORKDIR/fix-a.$round.out" 2>"$WORKDIR/fix-a.$round.err" &
	_pa=$!
	sleep 0.02
	_fix_one_parse >"$WORKDIR/fix-b.$round.out" 2>"$WORKDIR/fix-b.$round.err" &
	_pb=$!
	wait "$_pa"; _ra=$?
	wait "$_pb"; _rb=$?
	if [ "$_ra" -ne 0 ] || [ "$_rb" -ne 0 ] || [ ! -s "$FINAL" ] || \
		[ "$(wc -l <"$FINAL")" -ne "$EXPECTED" ]; then
		_fix_fail=1
		echo "  FIX failed round $round ra=$_ra rb=$_rb lines=$(wc -l <"$FINAL" 2>/dev/null || echo 0)"
		head -20 "$WORKDIR/fix-a.$round.err" "$WORKDIR/fix-b.$round.err" 2>/dev/null
		break
	fi
done

if [ "$_fix_fail" -eq 0 ]; then
	_pass "FIX: 30/30 parallel rounds green under same timing stress"
else
	_fail "FIX still failed under parallel stress"
fi

# ---------------------------------------------------------------------------
# 4. FIX also for the slow-sort micro pattern
# ---------------------------------------------------------------------------
echo
echo "--- 4. FIX: micro writers with per-run file + flock ---"
_fix_micro() {
	local mine
	mine=$(mktemp "$WORKDIR/partial.XXXXXX")
	(
		flock -w 30 9 || exit 99
		(
			local i
			for i in $(seq 1 100); do
				echo "repro-op-$(printf '%03d' "$i") Display stable"
			done
		) | sort >"$mine"
		sleep 0.05
		[ -s "$mine" ] || exit 1
		mv "$mine" "$FINAL"
	) 9>"$LOCK"
}

_micro_fail=0
for round in $(seq 1 30); do
	rm -f "$FINAL"
	_fix_micro &
	_pa=$!
	sleep 0.02
	_fix_micro &
	_pb=$!
	wait "$_pa"; _ra=$?
	wait "$_pb"; _rb=$?
	if [ "$_ra" -ne 0 ] || [ "$_rb" -ne 0 ] || [ "$(wc -l <"$FINAL" 2>/dev/null || echo 0)" -ne 100 ]; then
		_micro_fail=1
		echo "  micro-FIX failed round $round ra=$_ra rb=$_rb lines=$(wc -l <"$FINAL" 2>/dev/null || echo 0)"
		break
	fi
done

if [ "$_micro_fail" -eq 0 ]; then
	_pass "FIX micro-pattern: 30/30 full indexes"
else
	_fail "FIX micro-pattern lost lines"
fi

echo
echo "========================================"
echo "  PASS: $pass"
echo "  FAIL: $fail"
echo "========================================"
[ "$fail" -eq 0 ] && [ "$pass" -ge 4 ]
exit $?
