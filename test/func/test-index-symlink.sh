#!/bin/bash
# Test: .index/ comes from git, empty except its own gitignore.
# Product code does not mkdir it. A fresh clone already has the directory,
# so mirror/.index -> ../.index is not dangling.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== .index is a tracked empty directory ==="

if git check-ignore -q .index/.gitignore; then
	_fail ".index/.gitignore is ignored, so the directory would not be in git"
else
	_pass ".index/.gitignore is tracked"
fi

if git check-ignore -q .index/redhat-operator-index-v4.22; then
	_pass "catalog files inside .index are ignored"
else
	_fail "a file inside .index would be committed"
fi

WORK=$(mktemp -d /tmp/aba-index-link.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Same shape as a clone: the directory exists and is empty of catalog files.
mkdir -p "$WORK/repo/.index" "$WORK/repo/mirror/catalogs"
printf '%s\n' 'demo-operator Demo stable' > "$WORK/repo/mirror/catalogs/redhat-operator-index-v4.22"
ln -s ../.index "$WORK/repo/mirror/.index"

if ( cd "$WORK/repo/mirror" && _populate_shipped_indexes ); then
	_pass "populate uses the existing directory through the symlink"
else
	_fail "populate failed even though .index already existed"
fi

if [ -s "$WORK/repo/.index/redhat-operator-index-v4.22" ]; then
	_pass "shipped index was copied into the existing directory"
else
	_fail "shipped index was not copied"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
