#!/bin/bash
# Test: Public-repo hygiene gate
# Scans shipped files for internal ticket IDs, em/en-dashes, ANSI escapes.
# Scope: git ls-files minus .planning/ ai/ test/ and dotfile prefixes.
# Exits non-zero on any failure. Registered as the FIRST unit test in run-all-tests.sh
# so violations fail fast before slower tests run.

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}OK PASS${NC}: $1"; }
test_fail() { echo -e "${RED}FAIL${NC}: $1"; exit 1; }

echo
echo "=== Shipped File Hygiene Gate (test-shipped-file-hygiene.sh) ==="
echo

failed=0

# Enumerate shipped files. git ls-files respects .gitignore.
# Exclude: .planning/, ai/, test/, dotfiles at repo root (.gitignore, .git/, etc.)
_scoped_files=$(git ls-files | grep -v \
	-e '^\.planning/' \
	-e '^ai/' \
	-e '^test/' \
	-e '^\.'\
	)

# Check 1: Internal ticket IDs ([A-Z]{4,}-[0-9]+)
# External tracker prefixes that are valid in shipped files (not internal ticket IDs).
# Edit this allowlist to add new external trackers.
# KCS-     = Red Hat Knowledge Centered Service articles
# BZ-      = Red Hat Bugzilla
# OCPBUGS- = Red Hat public OCP bug tracker (JIRA)
# OPTIND-  = false positive: bash $((OPTIND-1)) arithmetic expression
# LICENSE- = false positive: Apache LICENSE-2.0 URL path component
_allowlist_prefixes='KCS-|BZ-|OCPBUGS-|OPTIND-|LICENSE-'

echo "--- Check 1: Internal ticket IDs ([A-Z]{4,}-[0-9]+) ---"
_internal_ticket_failed=0
while IFS= read -r _file; do
	[ -f "$_file" ] || continue
	# Find any 4+-uppercase-letter-dash-digits pattern; filter out allowlisted prefixes.
	# Grep returns 1 on no match; capture in a subshell that always exits 0.
	_hits=$(grep -nE '[A-Z]{4,}-[0-9]+' "$_file" | { grep -vE "${_allowlist_prefixes}"; :; })
	if [ -n "$_hits" ]; then
		echo "FAIL: $_file"
		echo "$_hits"
		_internal_ticket_failed=$((_internal_ticket_failed + 1))
	fi
done <<< "$_scoped_files"
if [ "$_internal_ticket_failed" -eq 0 ]; then
	test_pass "No internal ticket IDs in shipped files (allowlist: KCS-, BZ-, OCPBUGS-)"
else
	failed=$((failed + _internal_ticket_failed))
	echo -e "${RED}Found $_internal_ticket_failed file(s) with non-allowlisted internal ticket IDs${NC}"
fi

# Check 2: Em-dash (U+2014) and en-dash (U+2013)
echo
echo "--- Check 2: Em-dash (U+2014) and en-dash (U+2013) ---"
_dash_failed=0
while IFS= read -r _file; do
	[ -f "$_file" ] || continue
	# Skip binary files (e.g. images/*.mp4); grep -I silently ignores them.
	# Match U+2014 (E2 80 94) or U+2013 (E2 80 93) in text files only.
	if grep -InP $'[\x{2013}\x{2014}]' "$_file" >/dev/null; then
		echo "FAIL: $_file (em-dash or en-dash present)"
		grep -nP $'[\x{2013}\x{2014}]' "$_file"
		_dash_failed=$((_dash_failed + 1))
	fi
done <<< "$_scoped_files"
if [ "$_dash_failed" -eq 0 ]; then
	test_pass "No em-dashes or en-dashes in shipped files (use short hyphens only)"
else
	failed=$((failed + _dash_failed))
	echo -e "${RED}Found $_dash_failed file(s) with em-dash or en-dash${NC}"
fi

# Check 3: ANSI escape sequences (\x1b[...)
echo
echo "--- Check 3: ANSI escape sequences (\x1b[...) ---"
# Note: test/func/run-all-tests.sh and test/func/tui-test-lib.sh are allowed to use ANSI;
# they are already excluded from this scan by the ^test/ scope prefix filter.
_ansi_failed=0
while IFS= read -r _file; do
	[ -f "$_file" ] || continue
	# Use -I to skip binary files; use -P for the ESC[ escape pattern.
	if grep -InP $'\\x1b\\[' "$_file" >/dev/null; then
		echo "FAIL: $_file (ANSI escape sequence present)"
		grep -InP $'\\x1b\\[' "$_file"
		_ansi_failed=$((_ansi_failed + 1))
	fi
done <<< "$_scoped_files"
if [ "$_ansi_failed" -eq 0 ]; then
	test_pass "No ANSI escape sequences in shipped output strings"
else
	failed=$((failed + _ansi_failed))
	echo -e "${RED}Found $_ansi_failed file(s) with ANSI escapes${NC}"
fi

echo
if [ "$failed" -eq 0 ]; then
	echo -e "${GREEN}OK ALL HYGIENE CHECKS PASSED${NC}"
	exit 0
else
	echo -e "${RED}FAIL: $failed file(s) failed hygiene checks${NC}"
	exit 1
fi
