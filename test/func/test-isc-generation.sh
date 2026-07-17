#!/bin/bash
# Functional tests for ISC (ImageSet Config) generation
#
# Calls the real reg-create-imageset-config.sh from mirror/ with
# temporary aba.conf overrides. Tests the ISC output contract.
#
# Usage:  bash test/func/test-isc-generation.sh
#         bash test/func/test-isc-generation.sh -v   # verbose
#
# Prerequisites: catalog indexes in mirror/.index/

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ABA_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
MIRROR_DIR="$ABA_ROOT/mirror"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
_cleanup_files=()

# --- test helpers ---

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label"
		echo "    expected: '$expected'"
		echo "    actual:   '$actual'"
	fi
}

assert_file_valid_yaml_operators() {
	local label="$1" file="$2"
	local count
	count=$(grep -c '^  operators:' "$file" 2>/dev/null || true)
	if [ "$count" -le 1 ]; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label (operators keys: $count)"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label — found $count 'operators:' keys (expected 0 or 1)"
		[[ $VERBOSE -eq 1 ]] && cat "$file"
	fi
}

assert_contains() {
	local label="$1" file="$2" pattern="$3"
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label — pattern '$pattern' not found"
		[[ $VERBOSE -eq 1 ]] && cat "$file"
	fi
}

assert_not_contains() {
	local label="$1" file="$2" pattern="$3"
	if ! grep -qE "$pattern" "$file" 2>/dev/null; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: $label"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: $label — pattern '$pattern' unexpectedly found"
		[[ $VERBOSE -eq 1 ]] && grep -nE "$pattern" "$file"
	fi
}

count_in_file() {
	grep -c "$1" "$2" 2>/dev/null || echo 0
}

# Count operator package entries (4-space indent, exclude platform channel names)
count_operators() {
	# Platform channel names match "X.Y" pattern; operator names don't
	grep -E '^\s{4}- name: \S' "$1" 2>/dev/null | grep -cvE 'name: (stable|fast|candidate|eus)-' || echo 0
}

# --- ISC generation: patch aba.conf, run, restore ---
# Generates ISC by temporarily patching aba.conf, running the real script,
# then restoring. Output ISC is copied to a temp file.
#
# Args: key=value pairs for aba.conf overrides
# Sets: _isc (path to generated ISC)

_isc=""

generate_isc() {
	local tmpdir
	tmpdir=$(mktemp -d /tmp/test-isc-XXXXXX)
	_cleanup_files+=("$tmpdir")

	# Build a test aba.conf
	local aba_conf="$tmpdir/aba.conf"
	cp "$ABA_ROOT/aba.conf" "$aba_conf"

	# Build a test mirror.conf
	local mirror_conf="$tmpdir/mirror.conf"
	cp "$MIRROR_DIR/mirror.conf" "$mirror_conf"

	# Always clear ocp_upgrade_to unless caller explicitly sets it
	if grep -q "^ocp_upgrade_to=" "$mirror_conf" 2>/dev/null; then
		sed -i "s|^ocp_upgrade_to=.*|ocp_upgrade_to=|" "$mirror_conf"
	fi

	for arg in "$@"; do
		local key="${arg%%=*}"
		local val="${arg#*=}"

		# Mirror.conf keys go to mirror.conf, rest to aba.conf
		case "$key" in
			ocp_upgrade_to)
				if grep -q "^#*${key}=" "$mirror_conf" 2>/dev/null; then
					sed -i "s|^#*${key}=.*|${key}=${val}|" "$mirror_conf"
				else
					echo "${key}=${val}" >> "$mirror_conf"
				fi
				;;
			*)
				if grep -q "^${key}=" "$aba_conf" 2>/dev/null; then
					sed -i "s|^${key}=.*|${key}=${val}|" "$aba_conf"
				else
					echo "${key}=${val}" >> "$aba_conf"
				fi
				;;
		esac
	done

	# Generate ISC using real script but with temp configs
	local data_dir="$tmpdir/data"
	mkdir -p "$data_dir"
	_isc="$data_dir/imageset-config.yaml"

	# Swap aba.conf and mirror.conf, run, restore
	cp "$ABA_ROOT/aba.conf" "$tmpdir/aba.conf.orig"
	cp "$MIRROR_DIR/mirror.conf" "$tmpdir/mirror.conf.orig"
	cp "$aba_conf" "$ABA_ROOT/aba.conf"
	cp "$mirror_conf" "$MIRROR_DIR/mirror.conf"

	# Run in mirror/ with force to always regenerate
	local rc=0
	(cd "$MIRROR_DIR" && INFO_ABA= scripts/reg-create-imageset-config.sh -f force) \
		2>"$tmpdir/stderr.log" || rc=$?

	# Restore original configs immediately
	cp "$tmpdir/aba.conf.orig" "$ABA_ROOT/aba.conf"
	cp "$tmpdir/mirror.conf.orig" "$MIRROR_DIR/mirror.conf"

	if [ $rc -ne 0 ]; then
		echo "  [generate_isc] FAILED (exit $rc)" >&2
		[[ $VERBOSE -eq 1 ]] && cat "$tmpdir/stderr.log" >&2
		return 1
	fi

	# Copy generated ISC to our temp dir (so we don't interfere with real data/)
	if [ -f "$MIRROR_DIR/data/imageset-config.yaml" ]; then
		cp "$MIRROR_DIR/data/imageset-config.yaml" "$_isc"
	fi

	return 0
}

final_cleanup() {
	for d in "${_cleanup_files[@]}"; do
		rm -rf "$d"
	done
}
trap final_cleanup EXIT

# --- pre-flight ---

if [ ! -d "$MIRROR_DIR/.index" ]; then
	echo "ERROR: catalog indexes not found at $MIRROR_DIR/.index/"
	echo "Run 'aba -d mirror catalog' first."
	exit 2
fi

OCP_VER="4.22.3"
OCP_MAJOR="4.22"
if [ ! -f "$MIRROR_DIR/.index/redhat-operator-index-v${OCP_MAJOR}" ]; then
	echo "ERROR: redhat-operator-index-v${OCP_MAJOR} not found"
	exit 2
fi

echo "ISC Generation Functional Tests"
echo "Using OCP version: $OCP_VER (indexes: v$OCP_MAJOR)"
echo ""

# ============================================================================
echo "=== Test 1: Basic ISC — no operators ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform="

assert_file_valid_yaml_operators "No duplicate operators keys" "$_isc"
assert_contains "Has platform channel" "$_isc" "name: stable-${OCP_MAJOR}"
assert_contains "Has minVersion" "$_isc" "minVersion: ${OCP_VER}"
assert_contains "Has maxVersion" "$_isc" "maxVersion: ${OCP_VER}"
assert_contains "Has graph: true" "$_isc" "graph: true"
assert_not_contains "No operators section" "$_isc" "^  operators:"
assert_contains "Has commented operators hint" "$_isc" "^#  operators:"
[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 2: ISC with op_sets=ocp ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_contains "Has operators section" "$_isc" "^  operators:"
assert_contains "Has redhat catalog" "$_isc" "redhat-operator-index:v${OCP_MAJOR}"
assert_contains "Has kubernetes-nmstate" "$_isc" "kubernetes-nmstate-operator"
assert_contains "Has node-maintenance" "$_isc" "node-maintenance-operator"
assert_contains "Has node-healthcheck" "$_isc" "node-healthcheck-operator"
assert_contains "Has redhat-oadp" "$_isc" "redhat-oadp-operator"
assert_contains "Has web-terminal" "$_isc" "web-terminal"
assert_contains "Has devworkspace" "$_isc" "devworkspace-operator"
assert_contains "Has cli-manager" "$_isc" "cli-manager"
assert_contains "Has cincinnati" "$_isc" "cincinnati-operator"
assert_contains "Has channel for nmstate" "$_isc" 'name: "stable"'

_op_count=$(count_operators "$_isc")
assert_eq "OCP set has 9 operators" "9" "$_op_count"

_nmstate_count=$(count_in_file 'kubernetes-nmstate-operator' "$_isc")
assert_eq "kubernetes-nmstate appears once" "1" "$_nmstate_count"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 3: ISC with individual ops ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal,cincinnati-operator" "excl_platform="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_contains "Has web-terminal" "$_isc" "web-terminal"
assert_contains "Has cincinnati" "$_isc" "cincinnati-operator"
_op_count=$(count_operators "$_isc")
assert_eq "Individual ops has 2 operators" "2" "$_op_count"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 4: Dedup — op_sets + ops with overlap ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=web-terminal,3scale-operator" "excl_platform="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"

_wt_count=$(count_in_file 'web-terminal' "$_isc")
assert_eq "web-terminal deduplicated (appears once)" "1" "$_wt_count"

assert_contains "3scale-operator added" "$_isc" "3scale-operator"

_op_count=$(count_operators "$_isc")
assert_eq "Combined has 10 operators" "10" "$_op_count"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 5: excl_platform comments out platform section ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=true"

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_not_contains "Platform channels commented out" "$_isc" "^    channels:"
assert_contains "Platform commented with #" "$_isc" "^#.*channels:"
assert_contains "Operators still present" "$_isc" "^  operators:"
assert_contains "Has kubernetes-nmstate" "$_isc" "kubernetes-nmstate-operator"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 6: Upgrade mode (same minor) ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=4.22.5"

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_contains "Has minVersion (source)" "$_isc" "minVersion: ${OCP_VER}"
assert_contains "Has maxVersion (target)" "$_isc" "maxVersion: 4.22.5"
assert_contains "Has shortestPath" "$_isc" "shortestPath: true"
assert_contains "Channel is stable-${OCP_MAJOR}" "$_isc" "name: stable-${OCP_MAJOR}"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 7: Cross-catalog operators ==="
# ============================================================================
_cert_op=$(head -1 "$MIRROR_DIR/.index/certified-operator-index-v${OCP_MAJOR}" | awk '{print $1}')
_comm_op=$(head -1 "$MIRROR_DIR/.index/community-operator-index-v${OCP_MAJOR}" | awk '{print $1}')

generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal,${_cert_op},${_comm_op}" "excl_platform="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"

_catalog_count=$(grep -c '^\s*- catalog:' "$_isc" || true)
assert_eq "Three catalogs present" "3" "$_catalog_count"
assert_contains "Has redhat catalog" "$_isc" "redhat-operator-index"
assert_contains "Has certified catalog" "$_isc" "certified-operator-index"
assert_contains "Has community catalog" "$_isc" "community-operator-index"

_op_count=$(count_operators "$_isc")
assert_eq "3 operators total" "3" "$_op_count"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 8: Unknown operator gracefully skipped ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal,nonexistent-bogus-operator-xyz" "excl_platform="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_contains "Has web-terminal" "$_isc" "web-terminal"
assert_not_contains "No bogus operator" "$_isc" "nonexistent-bogus-operator-xyz"
_op_count=$(count_operators "$_isc")
assert_eq "Only valid operator present" "1" "$_op_count"

# ============================================================================
echo ""
echo "=== Test 9: Display name comments ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=cincinnati-operator" "excl_platform="

assert_contains "Display name comment for cincinnati" "$_isc" "# OpenShift Update Service"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 10: Channel name varies by version ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=candidate" "op_sets=" "ops=" "excl_platform="

assert_contains "Channel is candidate-${OCP_MAJOR}" "$_isc" "name: candidate-${OCP_MAJOR}"

# ============================================================================
echo ""
echo "=== Test 11: ISC file header and structure ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="

assert_contains "Has 'File generated by aba' header" "$_isc" "^# File generated by aba"
assert_contains "Has ownership transfer notice" "$_isc" "ownership transfers to you"
assert_contains "Has ImageSetConfiguration kind" "$_isc" "^kind: ImageSetConfiguration"
assert_contains "Has v2alpha1 API" "$_isc" "apiVersion: mirror.openshift.io/v2alpha1"
assert_contains "Has mirror: key" "$_isc" "^mirror:"
assert_contains "Has platform: key" "$_isc" "^  platform:"

# ============================================================================
echo ""
echo "=== Test 12: Idempotent — same input produces same output ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="
_first=$(md5sum "$_isc" | awk '{print $1}')

generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="
_second=$(md5sum "$_isc" | awk '{print $1}')

assert_eq "Identical output on regeneration" "$_first" "$_second"

# ============================================================================
echo ""
echo "=== Test 13: Operator channels match catalog index ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="

assert_contains "web-terminal has fast channel" "$_isc" 'name: "fast"'
assert_contains "cincinnati has v1 channel" "$_isc" 'name: "v1"'
assert_contains "cli-manager has tech-preview channel" "$_isc" 'name: "tech-preview"'

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================"
echo "  ISC Generation Tests: $PASS passed, $FAIL failed"
echo "========================================"

[ $FAIL -gt 0 ] && exit 1
exit 0
