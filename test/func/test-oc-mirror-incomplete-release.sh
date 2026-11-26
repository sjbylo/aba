#!/bin/bash
# An oc-mirror retry drops a release tag directory that has no index.json.
# A tag that already has index.json stays. The delete is not on the success path.

set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
source scripts/include_all.sh
trap - ERR
set -euo pipefail

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

base="$tmp/mirror"
mkdir -p "$base/data/working-dir/release-images/release-scos/4.22.0-okd-scos.10/blobs"
mkdir -p "$base/data/working-dir/release-images/release-scos/4.22.0-okd-scos.9/blobs"
printf '{}' > "$base/data/working-dir/release-images/release-scos/4.22.0-okd-scos.9/index.json"
mkdir -p "$base/data/working-dir/release-images/other-repo/good"
printf '{}' > "$base/data/working-dir/release-images/other-repo/good/index.json"
mkdir -p "$base/data/working-dir/release-images/release-scos/bad tag/blobs"
mkdir -p "$base/data/working-dir/.history"
echo keep > "$base/data/working-dir/.history/keep"
mkdir -p "$base/data/working-dir/cluster-resources"
echo cs > "$base/data/working-dir/cluster-resources/idms.yaml"

cd "$base"
_oc_mirror_drop_incomplete_release

if [ ! -d "data/working-dir/release-images/release-scos/4.22.0-okd-scos.10" ]; then
	_pass "tag directory with no index.json is removed"
else
	_fail "incomplete tag directory was kept"
fi
if [ -d data/working-dir/release-images/release-scos ]; then
	_pass "the repo directory stays"
else
	_fail "the repo directory was removed"
fi
if [ -f data/working-dir/release-images/release-scos/4.22.0-okd-scos.9/index.json ] \
	&& [ -d data/working-dir/release-images/release-scos/4.22.0-okd-scos.9/blobs ]; then
	_pass "a tag that has index.json stays"
else
	_fail "a complete tag was removed"
fi
if [ -f data/working-dir/release-images/other-repo/good/index.json ]; then
	_pass "a complete tag in another repo stays"
else
	_fail "the other repo's tag was removed"
fi
if [ ! -e "data/working-dir/release-images/release-scos/bad tag" ]; then
	_pass "a tag name with a space is removed when index.json is missing"
else
	_fail "spaced tag name was kept"
fi
if [ -f data/working-dir/.history/keep ] && [ -f data/working-dir/cluster-resources/idms.yaml ]; then
	_pass ".history and cluster-resources stay"
else
	_fail "a directory outside release-images was removed"
fi

mkdir -p data/working-dir/release-images/release-scos/empty-index
: > data/working-dir/release-images/release-scos/empty-index/index.json
_oc_mirror_drop_incomplete_release
if [ -f data/working-dir/release-images/release-scos/empty-index/index.json ]; then
	_pass "an empty index.json still counts as present"
else
	_fail "an empty index.json was treated as missing"
fi

plain="$tmp/plain"
mkdir -p "$plain/data/working-dir/.history"
echo keep > "$plain/data/working-dir/.history/keep"
cd "$plain"
_oc_mirror_drop_incomplete_release
if [ -f data/working-dir/.history/keep ]; then
	_pass "no release-images directory is a no-op"
else
	_fail "missing release-images changed other files"
fi

# The call sits in the retry branch: after .history is removed, before the
# next attempt is announced. A successful oc-mirror returns before that block.
src="$ROOT/scripts/include_all.sh"
uses=$(grep -c '^[[:space:]]*_oc_mirror_drop_incomplete_release$' "$src" || true)
if [ "$uses" = "1" ]; then
	_pass "the helper is called once"
else
	_fail "helper call count is $uses"
fi
window=$(awk '
	/Removing stale data\/working-dir\/\.history before retry/ { show=1 }
	show { print }
	/Trying again\./ { show=0 }
' "$src")
if printf '%s\n' "$window" | grep -q '^[[:space:]]*_oc_mirror_drop_incomplete_release$'; then
	_pass "the delete runs with the .history cleanup, before the next attempt"
else
	_fail "the delete is not next to the .history cleanup"
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
