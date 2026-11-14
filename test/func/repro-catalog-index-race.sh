#!/bin/bash
# Reproducer for the shared catalog index path.
# Does not call ABA product code.
#
# download-catalog-index.sh parses with:
#   ( slow extract ) | sort > .index/.NAME.downloading
# The shell truncates that shared path when the pipeline starts.
# A second run can move the path away, or truncate it, before the first
# run's "[ ! -s ]" check. The check then aborts with an empty index even
# though this run's extract produced a line.
#
# The fix, still only in this script:
#   parse into a private file, retry that private parse once if it is
#   empty while the extract has files, and publish under a flock.

set -u

fail=0

_say() {
	printf '%s\n' "$*"
}

# One catalog run. $1 is the worker name. $2 is "bug" or "fix".
# The extract is one operator file. The parse sleeps so two runs overlap
# the way two download-catalog-index.sh processes do.
_one_run() {
	local id="$1" mode="$2" work="$3" shared="$4" index="$5" lock="$6"
	local pause=0.2
	[ "$id" = "B" ] && pause=0.8

	mkdir -p "$work/configs/pkg${id}"
	printf 'package %s\n' "$id" > "$work/configs/pkg${id}/catalog.json"

	if [ "$mode" = "bug" ]; then
		(
			sleep "$pause"
			printf 'pkg%s Operator%s stable\n' "$id" "$id"
		) | sort > "$shared"
		if [ ! -s "$shared" ]; then
			_say "ABORT empty index for $id (extract still has $(find "$work/configs" -type f | wc -l) file(s))"
			return 1
		fi
		mv "$shared" "$index"
		return 0
	fi

	# Private parse. A second run cannot truncate this file.
	local private="$work/index"
	local attempt=0
	while [ "$attempt" -lt 2 ]; do
		attempt=$(( attempt + 1 ))
		(
			sleep "$pause"
			printf 'pkg%s Operator%s stable\n' "$id" "$id"
		) | sort > "$private"
		if [ -s "$private" ]; then
			break
		fi
		if [ "$attempt" -eq 1 ] && [ -n "$(find "$work/configs" -type f -print -quit 2>/dev/null)" ]; then
			_say "RETRY $id: private index empty, extract has files"
			continue
		fi
		_say "ABORT empty index for $id after retry"
		return 1
	done

	# Publish under a lock so the two mv operations do not pass each other.
	(
		flock 9
		cp "$private" "$index"
	) 9>"$lock"
	rm -f "$private"
	return 0
}

# First parse writes nothing. The extract file is still there, so the
# second parse must produce the index line. This is the third change.
_run_retry() {
	local root private
	root=$(mktemp -d)
	private="$root/index"
	mkdir -p "$root/configs/pkg"
	printf 'package\n' > "$root/configs/pkg/catalog.json"

	local attempt=0
	local saw_retry=0
	while [ "$attempt" -lt 2 ]; do
		attempt=$(( attempt + 1 ))
		if [ "$attempt" -eq 1 ]; then
			: > "$private"
		else
			printf 'pkg Operator stable\n' | sort > "$private"
		fi
		if [ -s "$private" ]; then
			break
		fi
		if [ "$attempt" -eq 1 ] && [ -n "$(find "$root/configs" -type f -print -quit 2>/dev/null)" ]; then
			saw_retry=1
			_say "  RETRY: private index empty, extract has files"
			continue
		fi
		_say "  ABORT empty index after retry"
		rm -rf "$root"
		return 1
	done

	if [ "$saw_retry" -eq 1 ] && [ -s "$private" ]; then
		_say "  index: $(cat "$private")"
		_say "  PASS: retry wrote the index"
		rm -rf "$root"
		return 0
	fi
	_say "  FAIL: retry did not recover"
	rm -rf "$root"
	return 1
}

_run_pair() {
	local mode="$1"
	local root
	root=$(mktemp -d)
	local shared="$root/.downloading"
	local index="$root/index"
	local lock="$root/publish.lock"
	local logA="$root/A.log" logB="$root/B.log"

	_one_run A "$mode" "$root/A" "$shared" "$index" "$lock" >"$logA" 2>&1 &
	local pidA=$!
	_one_run B "$mode" "$root/B" "$shared" "$index" "$lock" >"$logB" 2>&1 &
	local pidB=$!

	local rcA=0 rcB=0
	wait "$pidA" || rcA=$?
	wait "$pidB" || rcB=$?

	_say "---- $mode ----"
	sed 's/^/  A: /' "$logA"
	sed 's/^/  B: /' "$logB"
	_say "  exit A=$rcA B=$rcB"
	local index_ok=0
	if [ -s "$index" ]; then
		index_ok=1
		_say "  index: $(cat "$index")"
	else
		_say "  index: (missing or empty)"
	fi

	rm -rf "$root"

	if [ "$mode" = "bug" ]; then
		# The overlapping run must abort. The index from the winner may exist.
		if [ "$rcA" -ne 0 ] || [ "$rcB" -ne 0 ]; then
			_say "  PASS: shared path aborted an overlapping run"
			return 0
		fi
		_say "  FAIL: shared path did not abort"
		return 1
	fi

	if [ "$rcA" -eq 0 ] && [ "$rcB" -eq 0 ] && [ "$index_ok" -eq 1 ]; then
		_say "  PASS: private parse and locked publish both finished"
		return 0
	fi
	_say "  FAIL: fixed runs did not both publish"
	return 1
}

_say "=== catalog index race reproducer ==="
_say "Shared .downloading path (the product shape):"
if ! _run_pair bug; then
	fail=1
fi
_say ""
_say "Private file, one retry, flock around publish:"
if ! _run_pair fix; then
	fail=1
fi
_say ""
_say "Retry once when the private index is empty but the extract has files:"
if ! _run_retry; then
	fail=1
fi

if [ "$fail" -eq 0 ]; then
	_say ""
	_say "Reproducer passed: the shared path aborts, the private path does not."
fi
exit "$fail"
