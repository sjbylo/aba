#!/bin/bash
# Test: verify bundle build-order sorting (oldest/missing first)
#
# Simulates CLOUD_DIR contents and checks that the sort logic
# produces the correct build order for each test case.

set -e

PASS=0
FAIL=0
BUNDLE_UPLOADING="INSTALL-BUNDLE-UPLOADING-OR-INCOMPLETE.txt"

# --- Sort function (same logic that will go into go.sh) ---

compute_build_order() {
	local ver="$1"
	local cloud_dir="$2"
	shift 2
	local -n _names=$1

	local major_ver
	major_ver=$(echo "$ver" | cut -d. -f1,2)

	local build_order=()
	for i in "${!_names[@]}"; do
		local name=${_names[$i]}
		local current_patch=-1
		for d in "$cloud_dir/${major_ver}".*-"${name}"; do
			if [ -d "$d" ] && [ -f "$d/README.txt" ] && [ ! -f "$d/$BUNDLE_UPLOADING" ]; then
				local p
				p=$(basename "$d" | sed "s/^${major_ver}\.\([0-9]*\)-.*/\1/")
				[ "$p" -gt "$current_patch" ] 2>/dev/null && current_patch=$p
			fi
		done
		build_order+=("$current_patch:$i")
	done

	IFS=$'\n' sorted=($(sort -t: -k1,1n <<<"${build_order[*]}")); unset IFS

	local result=""
	for entry in "${sorted[@]}"; do
		local idx=${entry#*:}
		result+="${_names[$idx]} "
	done
	echo "$result"
}

# --- Test harness ---

assert_order() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"

	# Trim trailing space
	expected=$(echo "$expected" | sed 's/ *$//')
	actual=$(echo "$actual" | sed 's/ *$//')

	if [ "$expected" = "$actual" ]; then
		echo "  PASS: $test_name"
		PASS=$(( PASS + 1 ))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$(( FAIL + 1 ))
	fi
}

# --- Setup ---

TMPDIR_BASE=$(mktemp -d /tmp/test-bundle-sort.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Bundle type names (same as go.sh)
arr_name=(release ocp mesh3 opp virt sec ai)

echo "=== Test: bundle build-order sorting (oldest first) ==="
echo

# --- Test 1: User's real scenario ---
# 4.21.7-ai, 4.21.7-sec, 4.21.7-virt (patch 7)
# 4.21.8-release, 4.21.8-ocp, 4.21.8-mesh3, 4.21.8-opp (patch 8)
# Building 4.21.9 → expect: ai sec virt (7) before release ocp mesh3 opp (8)

CLOUD="$TMPDIR_BASE/test1"
mkdir -p "$CLOUD"/{4.21.7-ai,4.21.7-sec,4.21.7-virt,4.21.8-release,4.21.8-ocp,4.21.8-mesh3,4.21.8-opp}
for d in "$CLOUD"/4.21.*; do touch "$d/README.txt"; done

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "real scenario: oldest (7) before (8)" \
	"virt sec ai release ocp mesh3 opp" \
	"$result"

# --- Test 2: All bundles at same patch version ---
# Should preserve original array order as tiebreaker

CLOUD="$TMPDIR_BASE/test2"
mkdir -p "$CLOUD"/{4.21.8-release,4.21.8-ocp,4.21.8-mesh3,4.21.8-opp,4.21.8-virt,4.21.8-sec,4.21.8-ai}
for d in "$CLOUD"/4.21.*; do touch "$d/README.txt"; done

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "all same patch: original order" \
	"release ocp mesh3 opp virt sec ai" \
	"$result"

# --- Test 3: No existing bundles (first run) ---
# All missing → all get -1 → original order

CLOUD="$TMPDIR_BASE/test3"
mkdir -p "$CLOUD"

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "no existing bundles: original order" \
	"release ocp mesh3 opp virt sec ai" \
	"$result"

# --- Test 4: Some bundles missing entirely ---
# Only release(8) and ocp(8) exist → missing ones (-1) come first

CLOUD="$TMPDIR_BASE/test4"
mkdir -p "$CLOUD"/{4.21.8-release,4.21.8-ocp}
for d in "$CLOUD"/4.21.*; do touch "$d/README.txt"; done

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "missing bundles first" \
	"mesh3 opp virt sec ai release ocp" \
	"$result"

# --- Test 5: Incomplete bundle (uploading marker) treated as missing ---

CLOUD="$TMPDIR_BASE/test5"
mkdir -p "$CLOUD"/{4.21.8-release,4.21.8-ocp,4.21.8-mesh3,4.21.8-opp,4.21.8-virt,4.21.8-sec,4.21.8-ai}
for d in "$CLOUD"/4.21.*; do touch "$d/README.txt"; done
# Mark virt as incomplete
touch "$CLOUD/4.21.8-virt/$BUNDLE_UPLOADING"

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "incomplete bundle treated as missing" \
	"virt release ocp mesh3 opp sec ai" \
	"$result"

# --- Test 6: Mixed patch versions across three levels ---
# release(6), ocp(7), mesh3(7), opp(8), virt(8), sec(8), ai(6)

CLOUD="$TMPDIR_BASE/test6"
mkdir -p "$CLOUD"/{4.21.6-release,4.21.7-ocp,4.21.7-mesh3,4.21.8-opp,4.21.8-virt,4.21.8-sec,4.21.6-ai}
for d in "$CLOUD"/4.21.*; do touch "$d/README.txt"; done

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "three patch levels: 6 before 7 before 8" \
	"release ai ocp mesh3 opp virt sec" \
	"$result"

# --- Test 7: Different minor version dirs are ignored ---
# 4.20.17-release should NOT affect 4.21 ordering

CLOUD="$TMPDIR_BASE/test7"
mkdir -p "$CLOUD"/{4.20.17-release,4.20.17-ocp,4.21.8-release,4.21.7-ocp}
for d in "$CLOUD"/4.*; do touch "$d/README.txt"; done

result=$(compute_build_order "4.21.9" "$CLOUD" arr_name)
assert_order "ignores other minor versions" \
	"mesh3 opp virt sec ai ocp release" \
	"$result"

# --- Summary ---

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
echo "All tests passed."
