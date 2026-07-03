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
[ "$rc" -eq 1 ] && test_pass "auto: ask -n (no --auto-yes) → rc=1 (default no)" \
	|| test_fail "auto: ask -n should return 1 in auto mode" "got rc=$rc"

rc=$(_ask_rc_auto "" -y)
[ "$rc" -eq 0 ] && test_pass "auto: ask -y → rc=0 (default yes)" \
	|| test_fail "auto: ask -y should return 0 in auto mode" "got rc=$rc"

# ============================================================================
# Group 5: Unrecognized input (not y/n/Y/N/empty)
# ============================================================================
echo "--- Unrecognized input ---"

rc=$(_ask_rc "x" -y)
[ "$rc" -eq 0 ] && test_pass "ask -y: 'x' → rc=0 (treat as default=yes)" \
	|| test_fail "ask -y: 'x' should fall back to default (yes)" "got rc=$rc"

rc=$(_ask_rc "x" -n)
[ "$rc" -eq 1 ] && test_pass "ask -n: 'x' → rc=1 (treat as default=no)" \
	|| test_fail "ask -n: 'x' should fall back to default (no)" "got rc=$rc"

echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
