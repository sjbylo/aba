#!/bin/bash
# The progress yes/no must keep the ask's line breaks.
# dialog collapses real newlines into one paragraph unless --cr-wrap.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== BM prompt dialog keeps line breaks ==="

if awk '/^_tp_handle_prompt\(\)/{p=1} p&&/--cr-wrap/&&/--no-collapse/{found=1} p&&/^_tp_[a-z]/&&!/^_tp_handle_prompt/{exit} END{exit !found}' tui/v2/tui-progress.sh; then
	_pass "prompt dialog uses --cr-wrap and --no-collapse"
else
	_fail "prompt dialog must pass --cr-wrap and --no-collapse"
fi

if ! command -v dialog >/dev/null || ! command -v tmux >/dev/null; then
	_fail "dialog and tmux are required to check the prompt layout"
	echo ""
	echo "Results: $pass passed, $fail failed"
	exit "$fail"
fi

_sock="aba-dlg-$$"
_text=$'Boot servers from the agent ISO, then continue.\n\nISO file:\n  /tmp/agent.x86_64.iso\n\n  - USB:  sudo dd if=/tmp/agent.x86_64.iso\n          of=/dev/sdX bs=4M conv=fsync status=progress\n'
tmux -L "$_sock" kill-session -t dlg 2>/dev/null || true
tmux -L "$_sock" new-session -d -x 100 -y 36 -s dlg "dialog --cr-wrap --no-collapse --yesno $(printf '%q' "$_text") 0 0"
sleep 0.6
_scr=$(tmux -L "$_sock" capture-pane -t dlg -p)
tmux -L "$_sock" kill-session -t dlg 2>/dev/null || true

if echo "$_scr" | grep -q 'ISO file:' && ! echo "$_scr" | grep -q 'continue.*ISO file:'; then
	_pass "ISO file label is on its own line"
else
	_fail "ISO file label was folded into the paragraph"
	echo "$_scr"
fi
if echo "$_scr" | grep -q 'of=/dev/sdX'; then
	_pass "dd target stays whole"
else
	_fail "of=/dev/sdX was split or missing"
	echo "$_scr"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
