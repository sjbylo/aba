#!/bin/bash
# Test: replace-value-conf() — the critical config value replacement function.
# Unit test (fast, no network, no aba install needed)
#
# Tests all code paths:
#   1. Replace an active value                    → returns 0, value changed
#   2. Uncomment and set a commented-out value    → returns 0, value set
#   3. Value already matches (idempotent)         → returns 0, file unchanged
#   4. Key not found in file                      → returns 1, file unchanged
#   5. File does not exist                        → returns 1
#   6. File is empty                              → returns 1
#   7. Undefine a value (set to empty)            → returns 0, value cleared
#   8. Multiple files: key in second file         → returns 0, second file changed
#   9. Value with trailing comment preserved      → returns 0, comment kept
#  10. Symlink: writes through symlink            → returns 0, target updated
#  11. Quiet mode                                 → returns 0, no info output
#  12. Key with similar prefix not confused        → returns 0, correct key changed

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; passed=$((passed + 1)); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; failed=$((failed + 1)); }

# Set up a temp dir for test fixtures
TMPDIR=$(mktemp -d /tmp/test-replace-value-conf.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# Source include_all.sh to get the function (suppress initialization noise)
export ABA_ROOT="$PWD"
export INFO_ABA=0
export ABA_DEBUG=0
source scripts/include_all.sh >/dev/null 2>&1

echo
echo "=== Testing: replace-value-conf() ==="
echo

# ── 1. Replace an active value ───────────────────────────────────────────────
echo "ocp_version=4.18.2" > "$TMPDIR/conf1"
replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/conf1"
rc=$?
val=$(grep "^ocp_version=" "$TMPDIR/conf1" | cut -d= -f2)
if [ "$rc" -eq 0 ] && [ "$val" = "4.19.28" ]; then
	test_pass "1. Replace active value (4.18.2 → 4.19.28)"
else
	test_fail "1. Replace active value: rc=$rc val=$val (expected 0, 4.19.28)"
fi

# ── 2. Uncomment a commented-out value ───────────────────────────────────────
echo "#ocp_version_target=" > "$TMPDIR/conf2"
replace-value-conf -q -n ocp_version_target -v 4.19.28 -f "$TMPDIR/conf2"
rc=$?
val=$(grep "^ocp_version_target=" "$TMPDIR/conf2" | cut -d= -f2)
if [ "$rc" -eq 0 ] && [ "$val" = "4.19.28" ]; then
	test_pass "2. Uncomment and set commented-out value"
else
	test_fail "2. Uncomment commented-out value: rc=$rc val=$val (expected 0, 4.19.28)"
fi

# ── 3. Idempotent: value already matches ─────────────────────────────────────
echo "ocp_version=4.19.28" > "$TMPDIR/conf3"
cp "$TMPDIR/conf3" "$TMPDIR/conf3.orig"
replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/conf3"
rc=$?
if [ "$rc" -eq 0 ] && diff -q "$TMPDIR/conf3" "$TMPDIR/conf3.orig" >/dev/null; then
	test_pass "3. Idempotent — value already matches, file unchanged"
else
	test_fail "3. Idempotent: rc=$rc (expected 0, file unchanged)"
fi

# ── 4. Key not found in file ─────────────────────────────────────────────────
echo "some_other_key=hello" > "$TMPDIR/conf4"
cp "$TMPDIR/conf4" "$TMPDIR/conf4.orig"
replace-value-conf -q -n missing_key -v foo -f "$TMPDIR/conf4" && rc=$? || rc=$?
if [ "$rc" -eq 1 ] && diff -q "$TMPDIR/conf4" "$TMPDIR/conf4.orig" >/dev/null; then
	test_pass "4. Key not found → returns 1, file unchanged"
else
	test_fail "4. Key not found: rc=$rc (expected 1, file unchanged)"
fi

# ── 5. File does not exist ───────────────────────────────────────────────────
replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/nonexistent" && rc=$? || rc=$?
if [ "$rc" -eq 1 ]; then
	test_pass "5. Nonexistent file → returns 1"
else
	test_fail "5. Nonexistent file: rc=$rc (expected 1)"
fi

# ── 6. Empty file ────────────────────────────────────────────────────────────
touch "$TMPDIR/conf6"
replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/conf6" && rc=$? || rc=$?
if [ "$rc" -eq 1 ]; then
	test_pass "6. Empty file → returns 1"
else
	test_fail "6. Empty file: rc=$rc (expected 1)"
fi

# ── 7. Undefine a value (set to empty) ───────────────────────────────────────
echo "reg_pw=secret123" > "$TMPDIR/conf7"
replace-value-conf -q -n reg_pw -v -f "$TMPDIR/conf7"
rc=$?
line=$(grep "^reg_pw=" "$TMPDIR/conf7")
if [ "$rc" -eq 0 ] && [ "$line" = "reg_pw=" ]; then
	test_pass "7. Undefine value (set to empty)"
else
	test_fail "7. Undefine value: rc=$rc line=[$line] (expected 0, reg_pw=)"
fi

# ── 8. Multiple files: key in second file ────────────────────────────────────
echo "unrelated=yes" > "$TMPDIR/conf8a"
echo "ocp_version=4.18.2" > "$TMPDIR/conf8b"
replace-value-conf -q -n ocp_version -v 4.20.0 -f "$TMPDIR/conf8a" "$TMPDIR/conf8b"
rc=$?
val=$(grep "^ocp_version=" "$TMPDIR/conf8b" | cut -d= -f2)
if [ "$rc" -eq 0 ] && [ "$val" = "4.20.0" ]; then
	test_pass "8. Multiple files — key found in second file"
else
	test_fail "8. Multiple files: rc=$rc val=$val (expected 0, 4.20.0)"
fi

# ── 9. Trailing comment preserved ────────────────────────────────────────────
printf 'ocp_version=4.18.2\t\t# Target version\n' > "$TMPDIR/conf9"
replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/conf9"
rc=$?
line=$(cat "$TMPDIR/conf9")
if [ "$rc" -eq 0 ] && echo "$line" | grep -q "ocp_version=4.19.28" && echo "$line" | grep -q "# Target version"; then
	test_pass "9. Trailing comment preserved after value change"
else
	test_fail "9. Trailing comment: rc=$rc line=[$line]"
fi

# ── 10. Symlink: writes through to target ────────────────────────────────────
echo "reg_host=old.example.com" > "$TMPDIR/real10"
ln -sf "$TMPDIR/real10" "$TMPDIR/link10"
replace-value-conf -q -n reg_host -v new.example.com -f "$TMPDIR/link10"
rc=$?
val=$(grep "^reg_host=" "$TMPDIR/real10" | cut -d= -f2)
if [ "$rc" -eq 0 ] && [ "$val" = "new.example.com" ]; then
	test_pass "10. Symlink — writes through to target file"
else
	test_fail "10. Symlink: rc=$rc val=$val (expected 0, new.example.com)"
fi

# ── 11. Quiet mode suppresses info output ────────────────────────────────────
echo "ocp_version=4.18.2" > "$TMPDIR/conf11"
output=$(replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/conf11" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$output" ]; then
	test_pass "11. Quiet mode — no stdout/stderr output"
else
	test_fail "11. Quiet mode: rc=$rc output=[$output]"
fi

# ── 12. Similar prefix not confused ──────────────────────────────────────────
printf 'ocp_version=4.18.2\nocp_version_target=4.19.28\n' > "$TMPDIR/conf12"
replace-value-conf -q -n ocp_version -v 4.20.0 -f "$TMPDIR/conf12"
rc=$?
ver=$(grep "^ocp_version=" "$TMPDIR/conf12" | cut -d= -f2)
tgt=$(grep "^ocp_version_target=" "$TMPDIR/conf12" | cut -d= -f2)
if [ "$rc" -eq 0 ] && [ "$ver" = "4.20.0" ] && [ "$tgt" = "4.19.28" ]; then
	test_pass "12. Similar prefix — only exact key changed"
else
	test_fail "12. Similar prefix: rc=$rc ver=$ver tgt=$tgt (expected 4.20.0, 4.19.28)"
fi

# ── 13. Value with '# comment' commented-out key with space ──────────────────
echo "# ocp_version_target=" > "$TMPDIR/conf13"
replace-value-conf -q -n ocp_version_target -v 4.19.28 -f "$TMPDIR/conf13"
rc=$?
val=$(grep "^ocp_version_target=" "$TMPDIR/conf13" | cut -d= -f2)
if [ "$rc" -eq 0 ] && [ "$val" = "4.19.28" ]; then
	test_pass "13. Commented with space (# key=) → uncommented and set"
else
	test_fail "13. Commented with space: rc=$rc val=$val (expected 0, 4.19.28)"
fi

# ── 14. Value already matches with trailing comment ──────────────────────────
printf 'ocp_version=4.19.28\t\t# some comment\n' > "$TMPDIR/conf14"
cp "$TMPDIR/conf14" "$TMPDIR/conf14.orig"
replace-value-conf -q -n ocp_version -v 4.19.28 -f "$TMPDIR/conf14"
rc=$?
if [ "$rc" -eq 0 ] && diff -q "$TMPDIR/conf14" "$TMPDIR/conf14.orig" >/dev/null; then
	test_pass "14. Idempotent with trailing comment — file unchanged"
else
	test_fail "14. Idempotent with trailing comment: rc=$rc"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ "$failed" -eq 0 ] && exit 0 || exit 1
