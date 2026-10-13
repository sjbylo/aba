#!/bin/bash
# Smoke test for the TUI progress dialog engine.
# Simulates day2.sh progress events without needing a real cluster.
# Usage: bash test/func/test-tui-progress.sh

set -e

cd "$(cd "$(dirname "$0")/../.." && pwd -P)"

source scripts/include_all.sh

echo "=== Test 1: aba_progress is a no-op without FIFO ==="
unset ABA_PROGRESS_FIFO
aba_progress "PLAN|test|This should be silent"
echo "PASS: no error, no output"

echo
echo "=== Test 2: aba_progress writes to FIFO when set ==="
_tmpdir=$(mktemp -d)
_fifo="$_tmpdir/progress"
mkfifo "$_fifo"

# Open read-write to avoid blocking
exec 8<>"$_fifo"

export ABA_PROGRESS_FIFO="$_fifo"
aba_progress "PLAN|test|Hello from test"
aba_progress "START|test"
aba_progress "DONE|test"

# Read back
_got=""
while read -t 0.1 -r -u 8 _line; do
	_got="${_got}${_line}\n"
done

exec 8>&-
rm -rf "$_tmpdir"
unset ABA_PROGRESS_FIFO

if echo -e "$_got" | grep -q "PLAN|test|Hello from test"; then
	echo "PASS: FIFO received PLAN event"
else
	echo "FAIL: expected PLAN event in FIFO output"
	echo "Got: $_got"
	exit 1
fi
if echo -e "$_got" | grep -q "DONE|test"; then
	echo "PASS: FIFO received DONE event"
else
	echo "FAIL: expected DONE event"
	exit 1
fi

echo
echo "=== Test 3: tui-progress.sh sourcing and state functions ==="
# Source tui-progress.sh (it needs dialog, but we only test parse/state functions)
source tui/v2/tui-progress.sh

_tp_status=()
_tp_text=()
_tp_order=()
_tp_errors=()
_tp_details=()
_tp_nexts=()
_tp_prompt_msg=""
_tp_abort=""

_tp_parse_event "PLAN|access|Accessing cluster"
_tp_parse_event "PLAN|trustca|Registry trust CA"
_tp_parse_event "START|access"
_tp_parse_event "DONE|access"
_tp_parse_event "START|trustca"

if [ "${#_tp_order[@]}" -ne 2 ]; then
	echo "FAIL: expected 2 steps in _tp_order, got ${#_tp_order[@]}"
	exit 1
fi
echo "PASS: _tp_order has ${#_tp_order[@]} steps"

if [ "${_tp_status[access]}" != "0" ]; then
	echo "FAIL: expected access status 0 (Succeeded), got ${_tp_status[access]}"
	exit 1
fi
echo "PASS: access status is 0 (Succeeded)"

if [ "${_tp_status[trustca]}" != "77" ]; then
	echo "FAIL: expected trustca status 77 (queued start), got ${_tp_status[trustca]}"
	exit 1
fi
echo "PASS: trustca status is 77 (queued start)"

if [ "${_tp_text[access]}" != "Accessing cluster" ]; then
	echo "FAIL: expected text 'Accessing cluster', got '${_tp_text[access]}'"
	exit 1
fi
echo "PASS: step text preserved"

echo
echo "=== Test 4: parse ERROR/DETAIL/NEXT events ==="
_tp_parse_event "ERROR|catalogs|CatalogSource failed to become READY"
_tp_parse_event "DETAIL|Check pod logs in openshift-marketplace"
_tp_parse_event "NEXT|Run aba -d mirror sync to re-mirror operators"

if [ "${#_tp_errors[@]}" -ne 1 ] || [ "${_tp_errors[0]}" != "CatalogSource failed to become READY" ]; then
	echo "FAIL: ERROR event not parsed correctly"
	exit 1
fi
echo "PASS: ERROR event parsed"

if [ "${#_tp_details[@]}" -ne 1 ]; then
	echo "FAIL: DETAIL event not parsed"
	exit 1
fi
echo "PASS: DETAIL event parsed"

if [ "${#_tp_nexts[@]}" -ne 1 ]; then
	echo "FAIL: NEXT event not parsed"
	exit 1
fi
echo "PASS: NEXT event parsed"

echo
echo "=== Test 5: auto-complete logic ==="
_tp_status=()
_tp_text=()
_tp_order=()

_tp_parse_event "PLAN|a|Step A"
_tp_parse_event "PLAN|b|Step B"
_tp_parse_event "PLAN|c|Step C"
# b starts before a completes — triggers queued start
_tp_parse_event "START|b"

# a is pending (9), b is queued (77) — auto-complete should mark a as done
if _tp_auto_complete_one; then
	echo "PASS: auto-complete found work to do"
else
	echo "FAIL: auto-complete returned false"
	exit 1
fi

if [ "${_tp_status[a]}" != "0" ]; then
	echo "FAIL: expected a to be auto-completed (0), got ${_tp_status[a]}"
	exit 1
fi
echo "PASS: step a auto-completed to Succeeded"

# Next auto-complete should transition b from 77 to 7
if _tp_auto_complete_one; then
	echo "PASS: second auto-complete found work"
else
	echo "FAIL: second auto-complete returned false"
	exit 1
fi

if [ "${_tp_status[b]}" != "7" ]; then
	echo "FAIL: expected b to transition 77→7, got ${_tp_status[b]}"
	exit 1
fi
echo "PASS: step b transitioned 77→7 (In Progress)"

# c is still pending, b is in progress — no more auto-complete work
if ! _tp_auto_complete_one; then
	echo "PASS: no more auto-complete work (correct)"
else
	echo "FAIL: auto-complete should have returned false"
	exit 1
fi

echo
echo "=== Test 6: outcome determination ==="
_tp_status=()
_tp_text=()
_tp_order=()
_tp_errors=()

_tp_parse_event "PLAN|a|Step A"
_tp_parse_event "PLAN|b|Step B"
_tp_status[a]="0"
_tp_status[b]="0"

outcome=$(_tp_finish_outcome)
if [ "$outcome" != "success" ]; then
	echo "FAIL: expected 'success', got '$outcome'"
	exit 1
fi
echo "PASS: all done → success"

_tp_status[b]="1"
outcome=$(_tp_finish_outcome)
if [ "$outcome" != "error" ]; then
	echo "FAIL: expected 'error', got '$outcome'"
	exit 1
fi
echo "PASS: failed step → error"

_tp_status[b]="9"
outcome=$(_tp_finish_outcome)
if [ "$outcome" != "stopped" ]; then
	echo "FAIL: expected 'stopped', got '$outcome'"
	exit 1
fi
echo "PASS: incomplete step → stopped"

_tp_abort="User cancelled"
outcome=$(_tp_finish_outcome)
if [ "$outcome" != "abort" ]; then
	echo "FAIL: expected 'abort', got '$outcome'"
	exit 1
fi
echo "PASS: abort event → abort"

echo
echo "======================================="
echo "All tests passed!"
echo "======================================="
