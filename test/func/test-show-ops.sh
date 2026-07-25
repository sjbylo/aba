#!/bin/bash
# Functional tests for show-ops.sh (aba show-operators / aba show-ops)
#
# Tests catalog file resolution, fallback, auto-download, column formatting,
# flag parsing, and alias equivalence.
#
# Usage:  bash test/func/test-show-ops.sh
#         bash test/func/test-show-ops.sh -v   # verbose -- show captured output

set -eo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ABA_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$ABA_ROOT"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0

# Simulate aba.sh default: info messages on
export INFO_ABA=1

# Read ocp_version directly from aba.conf
eval "$(grep '^ocp_version=' aba.conf | head -1)"
OCP_MAJOR=$(echo "$ocp_version" | cut -d. -f1-2)
[ -z "$OCP_MAJOR" ] && { echo "FATAL: could not determine ocp_version from aba.conf"; exit 1; }

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (expected='$expected', got='$actual')"
	fi
}

assert_contains() {
	local label="$1" pattern="$2" text="$3"
	if grep -qE "$pattern" <<< "$text"; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (pattern='$pattern' not found in output)"
		[ "$VERBOSE" = 1 ] && echo "    output: $text"
	fi
}

assert_not_contains() {
	local label="$1" pattern="$2" text="$3"
	if ! grep -qE "$pattern" <<< "$text"; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (pattern='$pattern' unexpectedly found in output)"
		[ "$VERBOSE" = 1 ] && echo "    output: $text"
	fi
}

assert_gt() {
	local label="$1" expected="$2" actual="$3"
	if [ "$actual" -gt "$expected" ] 2>/dev/null; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label ($actual > $expected)"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label (expected > $expected, got '$actual')"
	fi
}

# Count non-header data lines (starts with 2+ spaces then a lowercase letter)
_count_ops() {
	grep -cE '^\s+[a-z]' <<< "$1" || echo 0
}

# --- Backup & restore ---

_backup_dir=$(mktemp -d /tmp/test-show-ops.XXXXXX)

_restore_all() {
	# Restore .index/ files
	rm -f .index/*-operator-index-v${OCP_MAJOR}
	if ls "$_backup_dir/index/"*-operator-index-v${OCP_MAJOR} &>/dev/null; then
		cp "$_backup_dir/index/"*-operator-index-v${OCP_MAJOR} .index/
	fi
	# Restore catalogs/ files
	for f in "$_backup_dir/catalogs/"*-operator-index-v${OCP_MAJOR}; do
		[ -f "$f" ] && cp "$f" catalogs/
	done
}

_cleanup() {
	_restore_all
	rm -rf "$_backup_dir"
}
trap '_cleanup' EXIT

# Backup originals
mkdir -p "$_backup_dir/index" "$_backup_dir/catalogs"
for f in .index/*-operator-index-v${OCP_MAJOR}; do
	[ -f "$f" ] && cp "$f" "$_backup_dir/index/"
done
for f in catalogs/*-operator-index-v${OCP_MAJOR}; do
	[ -f "$f" ] && cp "$f" "$_backup_dir/catalogs/"
done

echo "=== show-ops functional tests (OCP $OCP_MAJOR) ==="
echo

# ─────────────────────────────────────────────────────────────────
# 1. Basic invocation -- default (redhat catalog)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 1: Default invocation (redhat catalog) ---"
out=$(scripts/show-ops.sh 2>&1)
assert_contains "Header has OPERATOR column" "OPERATOR" "$out"
assert_contains "Header has DESCRIPTION column" "DESCRIPTION" "$out"
assert_contains "Header has DEFAULT CHANNEL column" "DEFAULT CHANNEL" "$out"
assert_not_contains "No CATALOG column in single-catalog mode" "CATALOG" "$out"
op_count=$(_count_ops "$out")
assert_gt "Lists operators (got $op_count)" 10 "$op_count"
echo

# ─────────────────────────────────────────────────────────────────
# 2. Alias equivalence: show-ops == show-operators via aba.sh
# ─────────────────────────────────────────────────────────────────
echo "--- Test 2: show-ops and show-operators produce same output ---"
out_ops=$(aba show-ops 2>&1)
out_operators=$(aba show-operators 2>&1)
if [ "$out_ops" = "$out_operators" ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: show-ops and show-operators output is identical"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: show-ops and show-operators output differs"
fi
echo

# ─────────────────────────────────────────────────────────────────
# 3. --certified flag
# ─────────────────────────────────────────────────────────────────
echo "--- Test 3: --certified flag ---"
out=$(scripts/show-ops.sh --certified 2>&1)
assert_contains "Has OPERATOR header" "OPERATOR" "$out"
assert_not_contains "No CATALOG column" "CATALOG" "$out"
cert_count=$(_count_ops "$out")
assert_gt "Lists certified operators (got $cert_count)" 5 "$cert_count"
echo

# ─────────────────────────────────────────────────────────────────
# 4. --community flag
# ─────────────────────────────────────────────────────────────────
echo "--- Test 4: --community flag ---"
out=$(scripts/show-ops.sh --community 2>&1)
comm_count=$(_count_ops "$out")
assert_gt "Lists community operators (got $comm_count)" 5 "$comm_count"
echo

# ─────────────────────────────────────────────────────────────────
# 5. --all flag -- shows CATALOG column and all three catalogs
# ─────────────────────────────────────────────────────────────────
echo "--- Test 5: --all flag (multi-catalog with CATALOG column) ---"
out=$(scripts/show-ops.sh --all 2>&1)
assert_contains "Has CATALOG header" "CATALOG" "$out"
assert_contains "Shows redhat entries" "redhat" "$out"
assert_contains "Shows certified entries" "certified" "$out"
assert_contains "Shows community entries" "community" "$out"
all_count=$(_count_ops "$out")
assert_gt "Total operators across all catalogs (got $all_count)" "$op_count" "$all_count"
echo

# ─────────────────────────────────────────────────────────────────
# 6. --redhat flag (explicit, same as default)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 6: --redhat flag (explicit, same as default) ---"
out_redhat=$(scripts/show-ops.sh --redhat 2>&1)
out_default=$(scripts/show-ops.sh 2>&1)
if [ "$out_redhat" = "$out_default" ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: --redhat output matches default"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: --redhat output differs from default"
fi
echo

# ─────────────────────────────────────────────────────────────────
# 7. Unknown flag -- should abort
# ─────────────────────────────────────────────────────────────────
echo "--- Test 7: Unknown flag aborts ---"
if out=$(scripts/show-ops.sh --bogus 2>&1); then
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: --bogus should have failed but exited 0"
else
	PASS=$(( PASS + 1 ))
	echo "  PASS: --bogus exited non-zero"
fi
assert_contains "Error mentions unknown option" "Unknown option" "$out"
echo

# ─────────────────────────────────────────────────────────────────
# 8. .index/ preferred over catalogs/
# ─────────────────────────────────────────────────────────────────
echo "--- Test 8: .index/ is preferred over catalogs/ ---"
# Put a marker operator in .index/ -- must also remove from catalogs/
# so _populate_shipped_indexes doesn't run (catalogs/ copy to .index/ only
# happens when .index/ is missing, and we're providing it)
echo "zzz-test-marker-op A test marker operator stable" > ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
assert_contains "Uses .index/ (marker operator visible)" "zzz-test-marker-op" "$out"
real_count=$(_count_ops "$out")
assert_eq "Only the marker operator is listed" "1" "$real_count"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 9. Falls back to catalogs/ when .index/ is missing
# ─────────────────────────────────────────────────────────────────
echo "--- Test 9: Falls back to catalogs/ when .index/ is missing ---"
rm -f ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
fb_count=$(_count_ops "$out")
assert_gt "Fallback to catalogs/ still lists operators (got $fb_count)" 10 "$fb_count"
assert_not_contains "No download message (catalogs/ exists)" "Downloading" "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 10. _populate_shipped_indexes copies catalogs/ to .index/
# ─────────────────────────────────────────────────────────────────
echo "--- Test 10: _populate_shipped_indexes copies catalogs/ to .index/ ---"
rm -f ".index/redhat-operator-index-v${OCP_MAJOR}"
rm -f ".index/certified-operator-index-v${OCP_MAJOR}"
rm -f ".index/community-operator-index-v${OCP_MAJOR}"
# Running show-ops triggers _populate_shipped_indexes
scripts/show-ops.sh >/dev/null 2>&1
if [ -s ".index/redhat-operator-index-v${OCP_MAJOR}" ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: _populate_shipped_indexes restored .index/ from catalogs/"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: .index/ file was not restored from catalogs/"
fi
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 11. Empty .index/ file is treated as missing (uses catalogs/)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 11: Empty .index/ file treated as missing ---"
: > ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
emp_count=$(_count_ops "$out")
assert_gt "Empty .index/ falls back to catalogs/ (got $emp_count)" 10 "$emp_count"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 12. Both .index/ and catalogs/ missing -- triggers auto-download
# ─────────────────────────────────────────────────────────────────
echo "--- Test 12: Both missing triggers auto-download ---"
rm -f ".index/redhat-operator-index-v${OCP_MAJOR}"
rm -f "catalogs/redhat-operator-index-v${OCP_MAJOR}"
# Clear run_once cache so download_all_catalogs actually runs
for d in "$HOME/.aba/runner/catalog:${OCP_MAJOR}:"*; do
	[ -d "$d" ] && rm -rf "$d"
done
out=$(scripts/show-ops.sh 2>&1)
assert_contains "Shows downloading message" "Downloading redhat-operator" "$out"
dl_count=$(_count_ops "$out")
assert_gt "Auto-download produced operators (got $dl_count)" 10 "$dl_count"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 13. Description truncation
# ─────────────────────────────────────────────────────────────────
echo "--- Test 13: Long descriptions are truncated ---"
long_desc=$(printf 'X%.0s' {1..80})
echo "long-desc-operator ${long_desc} stable" > ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
assert_contains "Long description is truncated with '..'" '\.\.' "$out"
# Verify the full 80-char desc is NOT present (it was truncated)
assert_not_contains "Full description not in output" "X{80}" "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 14. Blank lines in catalog files are skipped
# ─────────────────────────────────────────────────────────────────
echo "--- Test 14: Blank lines in catalog are skipped ---"
printf "\n\ntest-op-alpha Alpha description stable\n\n\ntest-op-beta Beta description fast\n\n" \
	> ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
line_count=$(_count_ops "$out")
assert_eq "Exactly 2 operators listed (blank lines skipped)" "2" "$line_count"
assert_contains "First operator present" "test-op-alpha" "$out"
assert_contains "Second operator present" "test-op-beta" "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 15. --all with one catalog missing from both sources
# ─────────────────────────────────────────────────────────────────
echo "--- Test 15: --all with one catalog missing (auto-downloads) ---"
rm -f ".index/certified-operator-index-v${OCP_MAJOR}"
rm -f "catalogs/certified-operator-index-v${OCP_MAJOR}"
# Clear run_once cache so download_all_catalogs actually runs
for d in "$HOME/.aba/runner/catalog:${OCP_MAJOR}:"*; do
	[ -d "$d" ] && rm -rf "$d"
done
out=$(scripts/show-ops.sh --all 2>&1)
assert_contains "Shows downloading for certified" "Downloading certified-operator" "$out"
assert_contains "Still shows redhat operators" "redhat" "$out"
assert_contains "Still shows community operators" "community" "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 16. Column alignment -- single catalog
# ─────────────────────────────────────────────────────────────────
echo "--- Test 16: Column alignment (no line exceeds 170 chars) ---"
out=$(scripts/show-ops.sh 2>&1)
max_len=0
while IFS= read -r line; do
	len=${#line}
	[ "$len" -gt "$max_len" ] && max_len=$len
done <<< "$out"
if [ "$max_len" -le 170 ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: Max line length is $max_len (<=170)"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: Max line length is $max_len (>170)"
fi
echo

# ─────────────────────────────────────────────────────────────────
# 17. Column alignment -- --all mode
# ─────────────────────────────────────────────────────────────────
echo "--- Test 17: --all column alignment (no line exceeds 185 chars) ---"
out=$(scripts/show-ops.sh --all 2>&1)
max_len=0
while IFS= read -r line; do
	len=${#line}
	[ "$len" -gt "$max_len" ] && max_len=$len
done <<< "$out"
if [ "$max_len" -le 185 ]; then
	PASS=$(( PASS + 1 ))
	echo "  PASS: Max line length is $max_len (<=185)"
else
	FAIL=$(( FAIL + 1 ))
	echo "  FAIL: Max line length is $max_len (>185)"
fi
echo

# ─────────────────────────────────────────────────────────────────
# 18. Stale .index/ is used (no auto-refresh without --refresh)
# ─────────────────────────────────────────────────────────────────
echo "--- Test 18: Stale .index/ is used without --refresh ---"
# Put an old marker and verify it's served as-is
echo "stale-marker-op Stale catalog data stable" > ".index/redhat-operator-index-v${OCP_MAJOR}"
touch -d "2020-01-01" ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
assert_contains "Stale file is used without --refresh" "stale-marker-op" "$out"
assert_not_contains "No refresh/download happens" "Refreshing\|Downloading" "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 19. Single-line catalog file
# ─────────────────────────────────────────────────────────────────
echo "--- Test 19: Single-line catalog file ---"
echo "solo-operator The only operator stable" > ".index/redhat-operator-index-v${OCP_MAJOR}"
out=$(scripts/show-ops.sh 2>&1)
solo_count=$(_count_ops "$out")
assert_eq "Exactly 1 operator listed" "1" "$solo_count"
assert_contains "The solo operator is present" "solo-operator" "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# 20. --certified and --community combined
# ─────────────────────────────────────────────────────────────────
echo "--- Test 20: --certified --community combined (two catalogs, CATALOG column) ---"
out=$(scripts/show-ops.sh --certified --community 2>&1)
assert_contains "Has CATALOG header" "CATALOG" "$out"
assert_contains "Shows certified" "certified" "$out"
assert_contains "Shows community" "community" "$out"
assert_not_contains "No redhat in two-catalog mode" "^  redhat " "$out"
_restore_all
echo

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -gt 0 ] && exit 1
exit 0
