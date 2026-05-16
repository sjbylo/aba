#!/bin/bash
# TUI password round-trip test — runs interactively in a tmux session.
# Tests: dialog entry → replace-value-conf → source → htpasswd auth
#
# Usage: bash test/func/tui-pw-roundtrip.sh

cd "$(dirname "$0")/../.."
source scripts/include_all.sh dummy_arg 2>/dev/null

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
pass=0
fail=0

test_pass() { printf "${GREEN}✓ PASS${NC}: %s\n" "$1"; pass=$(( pass + 1 )); }
test_fail() { printf "${RED}✗ FAIL${NC}: %s -- %s\n" "$1" "$2"; fail=$(( fail + 1 )); }

_TUI_TMP=$(mktemp)
_htfile=$(mktemp)
_conf=$(mktemp)
trap 'rm -f "$_TUI_TMP" "$_htfile" "$_conf"' EXIT

echo
echo "============================================================"
echo " TUI Password Round-Trip Test (interactive dialog)"
echo "============================================================"
echo

# Test one password through the full cycle
_test_tui_pw() {
	local test_name="$1"

	# Reset config file with template value
	cat > "$_conf" <<-'TMPL'
	reg_pw='p4ssw0rd'
	TMPL

	echo
	printf ">>> TEST: %s\n" "$test_name"
	echo "    Enter a password in the dialog box that appears."
	echo "    (The password will be tested for round-trip correctness.)"
	echo

	# Show the dialog passwordbox (same widget the TUI uses)
	local pw=""
	dialog --backtitle "TUI Password Round-Trip Test" \
		--title "$test_name" \
		--insecure --passwordbox \
		"Enter a test password (min 8 chars, no spaces, no single quotes):" \
		10 60 2>"$_TUI_TMP"
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		echo "    (cancelled)"
		return
	fi

	pw=$(cat "$_TUI_TMP")

	if [[ -z "$pw" ]]; then
		echo "    (empty — skipped)"
		return
	fi

	printf "    Entered password: [%s]\n" "$pw"

	# Step 1: Write to config via replace-value-conf (the real function)
	replace-value-conf -q -n reg_pw -v "'${pw}'" -f "$_conf" 2>/dev/null
	local file_content
	file_content=$(grep reg_pw "$_conf")
	printf "    Config file line:  %s\n" "$file_content"

	# Step 2: Read back by sourcing
	local readback
	readback=$(unset reg_pw; source "$_conf" 2>/dev/null; printf '%s' "$reg_pw")
	printf "    Read back value:   [%s]\n" "$readback"

	# Step 3: Verify round-trip
	if [[ "$readback" == "$pw" ]]; then
		test_pass "$test_name — round-trip"
	else
		test_fail "$test_name — round-trip" "wrote [$pw], read [$readback]"
	fi

	# Step 4: htpasswd auth
	htpasswd -bBc "$_htfile" admin "$pw" 2>/dev/null
	if htpasswd -bv "$_htfile" admin "$readback" 2>/dev/null; then
		test_pass "$test_name — htpasswd auth"
	else
		test_fail "$test_name — htpasswd auth" "password from config failed to authenticate"
	fi

	echo
}

# Run 5 test rounds with different passwords
_test_tui_pw "Test 1: Simple password"
_test_tui_pw "Test 2: Password with # and !"
_test_tui_pw "Test 3: Password with & (ampersand)"
_test_tui_pw "Test 4: Password with | (pipe) and \\ (backslash)"
_test_tui_pw "Test 5: Complex — all safe specials"

echo "============================================================"
printf " Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$pass" "$fail"
echo "============================================================"
echo
echo "Suggested test passwords to try:"
echo '  Test 1: p4ssw0rd'
echo '  Test 2: p4ss#w0rd!'
echo '  Test 3: p4ss&w0rd'
echo '  Test 4: p4ss|w0\rd'
echo '  Test 5: Kd8#f&2|xQ!@^z'
echo
