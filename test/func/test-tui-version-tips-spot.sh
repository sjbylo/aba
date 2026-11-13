#!/bin/bash
# Spot-check: TUI version menu shows the same tips as fetch_latest/previous/older.
# Non-destructive — Esc out without saving.
#
# Durable: does not hardcode z-streams. Expects whatever Cincinnati+CDN logic
# returns today (peek, cross-major, etc.).
#
# Usage:
#   TUI_TEST_HOST=bastion.example.com test/func/test-tui-version-tips-spot.sh
#   TUI_TEST_HOST=conno.example.com CHANNEL=fast test/func/test-tui-version-tips-spot.sh
#
# Env: TUI_TEST_HOST (default bastion.example.com), CHANNEL (default stable)

cd "$(dirname "$0")/../.." || exit 1

_CHANNEL="${CHANNEL:-stable}"
case "$_CHANNEL" in
	stable) _ch_key=s ;;
	fast) _ch_key=f ;;
	candidate) _ch_key=c ;;
	*) echo "Unknown CHANNEL=$_CHANNEL (use stable|fast|candidate)" >&2; exit 1 ;;
esac

export TUI_TEST_HOST="${TUI_TEST_HOST:-bastion.example.com}"
export TUI_TEST_SESSION="${TUI_TEST_SESSION:-tui-ver-spot}"

source test/func/tui-test-lib.sh

echo "=== TUI version tip spot-check ==="
echo "  Host: $_TUI_HOST  channel: $_CHANNEL"
echo ""

# Distribution of the test host's aba.conf: the tip tasks are named <distribution>:<channel>:...
_DIST=$($_TUI_SSH "cd ~/aba && source ./scripts/include_all.sh >/dev/null 2>&1; dist_of" 2>/dev/null | tail -1)
_DIST="${_DIST:-ocp}"
if [[ "$_DIST" == "okd" && "$_CHANNEL" == "fast" ]]; then
	echo "OKD has no fast channel (use CHANNEL=stable|candidate)" >&2
	exit 1
fi
echo "  Distribution: $_DIST"

# Fresh tip tasks on the test host (avoid sticky run_once tips)
$_TUI_SSH "rm -rf \"\$HOME/.aba/runner/${_DIST}:${_CHANNEL}:latest_version\"*" 2>/dev/null || true

# Expected ladder from the same code the TUI uses
echo "--- Resolve expected tips (fetch_*) ---"
_expect=$($_TUI_SSH "cd ~/aba && source ./scripts/include_all.sh && trap - ERR
	ABA_CACHE_DIR=\$(mktemp -d); export ABA_CACHE_DIR
	lat=\$(fetch_latest_version $_CHANNEL) || true
	prev=\$(fetch_previous_version $_CHANNEL) || true
	old=\$(fetch_older_version $_CHANNEL) || true
	rm -rf \"\$ABA_CACHE_DIR\"
	printf '%s|%s|%s\n' \"\$lat\" \"\$prev\" \"\$old\"
" 2>/dev/null) || _expect=""

_exp_lat="${_expect%%|*}"
_rest="${_expect#*|}"
_exp_prev="${_rest%%|*}"
_exp_old="${_rest#*|}"

echo "  expect Latest=$_exp_lat Previous=$_exp_prev Older=${_exp_old:--}"

if [[ -z "$_exp_lat" ]] || ! [[ "$_exp_lat" =~ ^[0-9]+\.[0-9]+\. ]]; then
	echo "  ✗ FAIL: could not resolve Latest via fetch_latest_version"
	exit 1
fi

tui_start_to_menu || { tui_summary; exit 1; }

echo ""
echo "--- Launch Rerun Wizard (W; may be below fold) ---"
tui_keys W
sleep 0.5
tui_keys Enter
sleep 3
tui_screenshot "spot-01-wiz"
_scr=$(tui_capture)
if ! echo "$_scr" | grep -qiE 'Channel|Version|Resume Configuration|Pull Secret|Wizard|Reconfigure'; then
	echo "  ✗ FAIL: Wizard did not open after W"
	echo "$_scr" | head -25
	tui_cleanup
	tui_summary
	exit 1
fi

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Resume Configuration\|Continue with this"; then
	echo "  Resume Configuration — Reconfigure"
	tui_press_button "Reconfigure" || true
	sleep 3
fi

_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Pull Secret"; then
	echo "  Pull Secret page — Next"
	tui_keys Enter
	sleep 2
fi

echo ""
echo "--- Channel ($_CHANNEL) ---"
if ! tui_wait_for "Channel\|channel\|stable\|fast\|candidate" 20; then
	echo "  ✗ FAIL: channel page never appeared"
	tui_screenshot "spot-fail-channel"
	tui_cleanup
	tui_summary
	exit 1
fi
tui_screenshot "spot-02-channel"
tui_keys "$_ch_key"
sleep 0.5
tui_keys Enter
sleep 4

echo ""
echo "--- Version page ---"
if ! tui_wait_for "Latest" 45; then
	echo "  ✗ FAIL: version page never appeared"
	tui_screenshot "spot-fail-version"
	tui_cleanup
	tui_summary
	exit 1
fi
tui_screenshot "spot-03-version"
_scr=$(tui_capture)
echo "---- version pane ----"
echo "$_scr" | grep -iE 'Latest|Previous|Older|Manual|Version' || echo "$_scr" | head -30
echo "----------------------"

# Escape dots for basic grep RE
_re_escape() { printf '%s' "$1" | sed 's/[.]/\\./g'; }

tui_assert_contains "Latest.*$(_re_escape "$_exp_lat")" "Latest shows $_exp_lat"

if [[ -n "$_exp_prev" ]]; then
	tui_assert_contains "Previous.*$(_re_escape "$_exp_prev")" "Previous shows $_exp_prev"
else
	echo "  (no Previous tip expected — skip)"
fi

if [[ -n "$_exp_old" ]]; then
	tui_assert_contains "Older.*$(_re_escape "$_exp_old")" "Older shows $_exp_old"
else
	# candidate often has <3 offer tips
	if echo "$_scr" | grep -qi 'Older'; then
		echo "  ✗ FAIL: Older shown but fetch_older_version was empty"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	else
		echo "  ✓ PASS: Older absent (matches empty fetch)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	fi
fi

# Abort without saving
tui_keys Escape
sleep 1
tui_keys Escape
sleep 1
tui_cleanup

tui_summary
exit "$_TUI_FAIL"
