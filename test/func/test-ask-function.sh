#!/bin/bash
# Unit tests for ask() function — interactive response logic.
#
# Bug #1024: ask -n has COMPLETELY INVERTED interactive responses:
#   - User types "y" (YES) → returns 1 (NO!)
#   - User types "n" (NO) → returns 0 (YES!)
#   - User presses Enter (default NO) → returns 0 (YES!)
#
# This test proves the bug exists and verifies the correct behavior:
#   return 0 = "yes, proceed"
#   return 1 = "no, don't proceed"
# ...regardless of what the default is.
#
# Pure bash: no network, no oc, no make.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

# Source include_all.sh to get the ask() function
# ask() calls normalize-aba-conf which needs scripts/ in PATH
export PATH="$REPO_ROOT/scripts:$PATH"
source scripts/include_all.sh dummy_arg 2>/dev/null

# Force interactive mode: unset ASK_OVERRIDE and set ASK_ALWAYS so ask()
# reaches the interactive read path (not the auto-answer shortcut).
unset ASK_OVERRIDE
export ASK_ALWAYS=1

echo
echo "=== Testing: ask() interactive response logic (Bug #1024) ==="
echo

# Helper: run ask() with piped input, capture return code.
# Usage: _ask_rc <input> <ask_flags...> <prompt>
_ask_rc() {
	local input="$1"; shift
	local rc=0
	echo "$input" | ask "$@" "Test prompt" >/dev/null 2>&1 || rc=$?
	echo $rc
}

# ============================================================================
# Group 1: ask -y (default YES) — the common case
# ============================================================================
echo "--- ask -y (default YES) ---"

rc=$(_ask_rc "y" -y)
[ "$rc" -eq 0 ] && test_pass "ask -y: 'y' → rc=0 (proceed)" \
	|| test_fail "ask -y: 'y' should return 0" "got rc=$rc"

rc=$(_ask_rc "Y" -y)
[ "$rc" -eq 0 ] && test_pass "ask -y: 'Y' → rc=0 (proceed)" \
	|| test_fail "ask -y: 'Y' should return 0" "got rc=$rc"

rc=$(_ask_rc "n" -y)
[ "$rc" -eq 1 ] && test_pass "ask -y: 'n' → rc=1 (don't proceed)" \
	|| test_fail "ask -y: 'n' should return 1" "got rc=$rc"

rc=$(_ask_rc "N" -y)
[ "$rc" -eq 1 ] && test_pass "ask -y: 'N' → rc=1 (don't proceed)" \
	|| test_fail "ask -y: 'N' should return 1" "got rc=$rc"

rc=$(_ask_rc "" -y)
[ "$rc" -eq 0 ] && test_pass "ask -y: Enter (empty) → rc=0 (default=yes)" \
	|| test_fail "ask -y: Enter should return 0 (default yes)" "got rc=$rc"

# ============================================================================
# Group 2: ask -n (default NO) — THE BUG: all responses are inverted
# ============================================================================
echo "--- ask -n (default NO) — Bug #1024 ---"

rc=$(_ask_rc "y" -n)
[ "$rc" -eq 0 ] && test_pass "ask -n: 'y' → rc=0 (proceed)" \
	|| test_fail "ask -n: 'y' should return 0 (user said YES)" "got rc=$rc — BUG #1024: inverted!"

rc=$(_ask_rc "Y" -n)
[ "$rc" -eq 0 ] && test_pass "ask -n: 'Y' → rc=0 (proceed)" \
	|| test_fail "ask -n: 'Y' should return 0 (user said YES)" "got rc=$rc — BUG #1024: inverted!"

rc=$(_ask_rc "n" -n)
[ "$rc" -eq 1 ] && test_pass "ask -n: 'n' → rc=1 (don't proceed)" \
	|| test_fail "ask -n: 'n' should return 1 (user said NO)" "got rc=$rc — BUG #1024: inverted!"

rc=$(_ask_rc "N" -n)
[ "$rc" -eq 1 ] && test_pass "ask -n: 'N' → rc=1 (don't proceed)" \
	|| test_fail "ask -n: 'N' should return 1 (user said NO)" "got rc=$rc — BUG #1024: inverted!"

rc=$(_ask_rc "" -n)
[ "$rc" -eq 1 ] && test_pass "ask -n: Enter (empty) → rc=1 (default=no)" \
	|| test_fail "ask -n: Enter should return 1 (default no)" "got rc=$rc — BUG #1024: inverted!"

# ============================================================================
# Group 3: ask (no flag, default YES — same as -y)
# ============================================================================
echo "--- ask (no flag, implicit default YES) ---"

rc=$(_ask_rc "y")
[ "$rc" -eq 0 ] && test_pass "ask (no flag): 'y' → rc=0 (proceed)" \
	|| test_fail "ask (no flag): 'y' should return 0" "got rc=$rc"

rc=$(_ask_rc "n")
[ "$rc" -eq 1 ] && test_pass "ask (no flag): 'n' → rc=1 (don't proceed)" \
	|| test_fail "ask (no flag): 'n' should return 1" "got rc=$rc"

rc=$(_ask_rc "")
[ "$rc" -eq 0 ] && test_pass "ask (no flag): Enter → rc=0 (default=yes)" \
	|| test_fail "ask (no flag): Enter should return 0" "got rc=$rc"

# ============================================================================
# Group 4: Non-interactive mode (ASK_OVERRIDE / ask=false)
# ============================================================================
echo "--- Non-interactive mode (auto-answer) ---"

# Temporarily enable non-interactive mode
_ask_rc_auto() {
	local input="$1"; shift
	local rc=0
	( export ASK_ALWAYS=; export ASK_OVERRIDE=1; echo "$input" | ask "$@" "Test prompt" >/dev/null 2>&1 ) || rc=$?
	echo $rc
}

rc=$(_ask_rc_auto "" -n --auto-yes)
[ "$rc" -eq 0 ] && test_pass "auto: ask -n --auto-yes → rc=0 (auto proceeds)" \
	|| test_fail "auto: ask -n --auto-yes should return 0" "got rc=$rc"

rc=$(_ask_rc_auto "" -y --auto-no)
[ "$rc" -eq 1 ] && test_pass "auto: ask -y --auto-no → rc=1 (auto declines)" \
	|| test_fail "auto: ask -y --auto-no should return 1" "got rc=$rc"

rc=$(_ask_rc_auto "" -n)
[ "$rc" -eq 0 ] && test_pass "auto: ask -n with ASK_OVERRIDE → rc=0 (always yes, like dnf -y)" \
	|| test_fail "auto: ask -n with ASK_OVERRIDE should return 0 (go ahead)" "got rc=$rc"

rc=$(_ask_rc_auto "" -y)
[ "$rc" -eq 0 ] && test_pass "auto: ask -y → rc=0 (default yes)" \
	|| test_fail "auto: ask -y should return 0 in auto mode" "got rc=$rc"

# ============================================================================
# Group 5: Unrecognized input (not y/n/Y/N/empty)
# ============================================================================
echo "--- Unrecognized input ---"

rc=$(_ask_rc "x" -y)
[ "$rc" -eq 1 ] && test_pass "ask -y: 'x' → rc=1 (unrecognized = reject)" \
	|| test_fail "ask -y: 'x' should return 1 (only explicit y/Y proceeds)" "got rc=$rc"

rc=$(_ask_rc "x" -n)
[ "$rc" -eq 1 ] && test_pass "ask -n: 'x' → rc=1 (unrecognized = reject)" \
	|| test_fail "ask -n: 'x' should return 1 (only explicit y/Y proceeds)" "got rc=$rc"

# ============================================================================
# Group 6: --always + ask=false (BM gates must still prompt)
# ============================================================================
echo "--- ask --always vs ask=false ---"

_ask_rc_noask() {
	local input="$1"; shift
	local rc=0
	local td
	td=$(mktemp -d)
	printf 'ask=false\n' > "$td/aba.conf"
	(
		cd "$td" || exit 1
		unset ASK_ALWAYS ASK_OVERRIDE
		export PATH="$REPO_ROOT/scripts:$PATH"
		# shellcheck disable=SC1091
		source "$REPO_ROOT/scripts/include_all.sh" dummy_arg 2>/dev/null
		echo "$input" | ask "$@" "Test prompt" >/dev/null 2>&1
	) || rc=$?
	rm -rf "$td"
	echo $rc
}

# Regression: ask=false + --auto-no used to silently refuse BM boot (no prompt).
rc=$(_ask_rc_noask "" -y --auto-no)
[ "$rc" -eq 1 ] && test_pass "ask=false: -y --auto-no → rc=1 (auto decline)" \
	|| test_fail "ask=false: -y --auto-no should return 1" "got rc=$rc"

# --always forces interactive even with ask=false
rc=$(_ask_rc_noask "y" -y --always)
[ "$rc" -eq 0 ] && test_pass "ask=false: -y --always + 'y' → rc=0 (forced interactive)" \
	|| test_fail "ask=false: --always should prompt and accept y" "got rc=$rc"

rc=$(_ask_rc_noask "n" -y --always)
[ "$rc" -eq 1 ] && test_pass "ask=false: -y --always + 'n' → rc=1" \
	|| test_fail "ask=false: --always + n should decline" "got rc=$rc"

# aba -y (ASK_OVERRIDE) still wins over --always (automation)
rc=$(
	td=$(mktemp -d)
	printf 'ask=false\n' > "$td/aba.conf"
	(
		cd "$td" || exit 1
		unset ASK_ALWAYS
		export ASK_OVERRIDE=1
		export PATH="$REPO_ROOT/scripts:$PATH"
		source "$REPO_ROOT/scripts/include_all.sh" dummy_arg 2>/dev/null
		echo "n" | ask -y --always "Test prompt" >/dev/null 2>&1
	) && echo 0 || echo $?
	rm -rf "$td"
)
[ "$rc" -eq 0 ] && test_pass "ASK_OVERRIDE beats --always (aba -y still skips prompt)" \
	|| test_fail "ASK_OVERRIDE should win over --always" "got rc=$rc"

# ============================================================================
# Group 7: multi-line CLI prompt must keep newlines (not collapse to one line)
# ============================================================================
echo "--- multi-line CLI prompt ---"

_ml_out=$(
	unset ASK_OVERRIDE
	export ASK_ALWAYS=1
	export PLAIN_OUTPUT=1
	echo y | ask -y --always $'Boot servers from the agent ISO, then continue to monitor.\n\nISO file:\n  /tmp/agent.iso\n\nYes: continue' 2>&1
)
# Collapsed bug looks like: "...monitor.ISO file:  /tmp/..." (no newline).
# Require a real newline before "ISO file:" and before the indented path.
if echo "$_ml_out" | grep -q $'monitor\.\n\[ABA\] \n\[ABA\] ISO file:\n' \
	&& echo "$_ml_out" | grep -q $'ISO file:\n\[ABA\]   /tmp/agent.iso\n' \
	&& ! echo "$_ml_out" | grep -qF 'monitor.ISO file:'; then
	test_pass "multi-line ask preserves newlines on CLI"
else
	test_fail "multi-line ask must preserve newlines" "$(printf '%s' "$_ml_out" | tr '\n' '|' | head -c 240)"
fi

# BM scripts must use --always
if grep -q 'ask -y --always' "$REPO_ROOT/scripts/bm-ask-boot.sh" \
	&& grep -q 'ask -y --always' "$REPO_ROOT/scripts/bm-ask-edit.sh"; then
	test_pass "bm-ask-boot/edit use ask --always"
else
	test_fail "bm-ask-boot/edit must use ask --always" "missing --always"
fi
if grep -q -- '--auto-no' "$REPO_ROOT/scripts/bm-ask-boot.sh"; then
	test_fail "bm-ask-boot must not use --auto-no (blocks ask=false users)" "still has --auto-no"
else
	test_pass "bm-ask-boot has no --auto-no"
fi

echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
