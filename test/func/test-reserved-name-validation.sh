#!/bin/bash
# Test: Bug #1218 — Reserved directory names rejected for both cluster and mirror
#
# Verifies that _valid_cluster_name and _valid_mirror_name block reserved
# ABA directory names, while allowing legitimate names.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  ${GREEN}PASS${NC}  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  ${RED}FAIL${NC}  %s\n" "$*"; }

echo "=== Reserved Name Validation Tests ==="
echo

# ─────────────────────────────────────────────────────────────────
# Test 1: _valid_cluster_name rejects all reserved names
# ─────────────────────────────────────────────────────────────────
echo "--- Test 1: _valid_cluster_name rejects reserved names ---"
for name in mirror scripts cli templates tui build others test ai tools rpms images catalogs bundles docs devel; do
	if _valid_cluster_name "$name" 2>/dev/null; then
		_fail "cluster name '$name' should be rejected (reserved)"
	else
		_pass "cluster rejects '$name'"
	fi
done

# ─────────────────────────────────────────────────────────────────
# Test 2: _valid_mirror_name rejects reserved names (except 'mirror')
# ─────────────────────────────────────────────────────────────────
echo
echo "--- Test 2: _valid_mirror_name rejects reserved names ---"
for name in scripts cli templates tui build others test ai tools rpms images catalogs bundles docs devel; do
	if _valid_mirror_name "$name" 2>/dev/null; then
		_fail "mirror name '$name' should be rejected (reserved)"
	else
		_pass "mirror rejects '$name'"
	fi
done

# ─────────────────────────────────────────────────────────────────
# Test 3: _valid_mirror_name allows 'mirror' (the default)
# ─────────────────────────────────────────────────────────────────
echo
echo "--- Test 3: 'mirror' is allowed as a mirror name ---"
if _valid_mirror_name "mirror" 2>/dev/null; then
	_pass "mirror allows 'mirror'"
else
	_fail "mirror name 'mirror' should be allowed (it's the default)"
fi

# ─────────────────────────────────────────────────────────────────
# Test 4: Both functions accept valid names
# ─────────────────────────────────────────────────────────────────
echo
echo "--- Test 4: Valid names accepted ---"
for name in mycluster sno compact1 my-mirror prod-mirror reg1; do
	if _valid_cluster_name "$name" 2>/dev/null; then
		_pass "cluster accepts '$name'"
	else
		_fail "cluster name '$name' should be accepted"
	fi
	if _valid_mirror_name "$name" 2>/dev/null; then
		_pass "mirror accepts '$name'"
	else
		_fail "mirror name '$name' should be accepted"
	fi
done

# ─────────────────────────────────────────────────────────────────
# Test 5: Both functions reject invalid DNS labels
# ─────────────────────────────────────────────────────────────────
echo
echo "--- Test 5: Invalid DNS labels rejected ---"
for name in "" "123abc" "UPPER" "has space" "under_score" "-leading" "trailing-" "a.dot"; do
	label="$name"
	[ -z "$label" ] && label="(empty)"
	if _valid_cluster_name "$name" 2>/dev/null; then
		_fail "cluster should reject '$label'"
	else
		_pass "cluster rejects '$label'"
	fi
	if _valid_mirror_name "$name" 2>/dev/null; then
		_fail "mirror should reject '$label'"
	else
		_pass "mirror rejects '$label'"
	fi
done

# ─────────────────────────────────────────────────────────────────
# Test 6: CLI integration — aba mirror --name <reserved> aborts
# ─────────────────────────────────────────────────────────────────
echo
echo "--- Test 6: CLI rejects reserved mirror names ---"
for name in scripts cli tui; do
	out=$(aba mirror --name "$name" 2>&1) && rc=0 || rc=$?
	if [ $rc -ne 0 ] && echo "$out" | grep -qi "reserved\|invalid"; then
		_pass "aba mirror --name $name aborts (rc=$rc)"
	else
		_fail "aba mirror --name $name should abort (rc=$rc)"
	fi
done

echo
echo "--- Test 7: CLI allows default mirror name ---"
# Just test validation, don't actually create a mirror dir
# Use --help after to prevent actual creation
out=$(aba mirror --name mirror --help 2>&1) && rc=0 || rc=$?
if echo "$out" | grep -qi "reserved"; then
	_fail "aba mirror --name mirror wrongly rejected as reserved"
else
	_pass "aba mirror --name mirror not rejected"
fi

echo
echo "========================================="
echo "  Results: $pass passed, $fail failed"
echo "========================================="
[ $fail -gt 0 ] && exit 1 || exit 0
