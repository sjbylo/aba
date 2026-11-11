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
	sed -i "s|^catalog_versions=.*|catalog_versions=|" "$mirror_conf"

	for arg in "$@"; do
		local key="${arg%%=*}"
		local val="${arg#*=}"

		# Mirror.conf keys go to mirror.conf, rest to aba.conf
		case "$key" in
			ocp_upgrade_to|catalog_versions)
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
	_isc_stderr="$tmpdir/stderr.log"
	(cd "$MIRROR_DIR" && INFO_ABA= scripts/reg-create-imageset-config.sh -f force) \
		2>"$_isc_stderr" || rc=$?

	# Restore original configs immediately
	cp "$tmpdir/aba.conf.orig" "$ABA_ROOT/aba.conf"
	cp "$tmpdir/mirror.conf.orig" "$MIRROR_DIR/mirror.conf"

	_isc_stderr="$tmpdir/stderr.log"
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

# Shipped catalogs/ are copied below when a fresh tree has no .index yet.
mkdir -p "$MIRROR_DIR/.index"

# Ensure all 3 catalog indexes exist for the target version.
# Prior tests (e.g. test-aba-root-cleanup) may have wiped .index/.
# Copy from shipped catalogs/ (no network needed).
for _ver in 4.21 4.22; do
	for _cat in redhat-operator certified-operator community-operator; do
		if [ ! -s "$MIRROR_DIR/.index/${_cat}-index-v${_ver}" ] && [ -s "$ABA_ROOT/catalogs/${_cat}-index-v${_ver}" ]; then
			mkdir -p "$MIRROR_DIR/.index"
			cp "$ABA_ROOT/catalogs/${_cat}-index-v${_ver}" "$MIRROR_DIR/.index/"
		fi
	done
done

OCP_VER="4.22.3"
OCP_MAJOR="4.22"
# Fall back to the latest available version if 4.22 index is missing
# (prior catalog tests may have replaced indexes with a different version)
if [ ! -f "$MIRROR_DIR/.index/redhat-operator-index-v${OCP_MAJOR}" ]; then
	_latest=$(ls "$MIRROR_DIR/.index"/redhat-operator-index-v* 2>/dev/null | sort -V | tail -1)
	if [ -z "$_latest" ]; then
		echo "ERROR: no redhat-operator-index found in $MIRROR_DIR/.index/"
		exit 2
	fi
	OCP_MAJOR=$(echo "$_latest" | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/^v//')
	OCP_VER="${OCP_MAJOR}.0"
	echo "NOTE: v4.22 index not found, using v${OCP_MAJOR} instead"
fi

echo "ISC Generation Functional Tests"
echo "Using OCP version: $OCP_VER (indexes: v$OCP_MAJOR)"
echo ""

# ============================================================================
echo "=== Test 1: Basic ISC — no operators ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="

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
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "excl_operators=" "excl_additional="

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
assert_contains "Has descheduler" "$_isc" "cluster-kube-descheduler-operator"
assert_contains "Has lightspeed" "$_isc" "lightspeed-operator"
assert_contains "Has cincinnati" "$_isc" "cincinnati-operator"
assert_contains "Has channel for nmstate" "$_isc" 'name: "stable"'

_op_count=$(count_operators "$_isc")
assert_eq "OCP set has 10 operators" "10" "$_op_count"

_nmstate_count=$(count_in_file 'kubernetes-nmstate-operator' "$_isc")
assert_eq "kubernetes-nmstate appears once" "1" "$_nmstate_count"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 3: ISC with individual ops ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal,cincinnati-operator" "excl_platform=" "excl_operators=" "excl_additional="

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
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=web-terminal,3scale-operator" "excl_platform=" "excl_operators=" "excl_additional="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"

_wt_count=$(count_in_file 'web-terminal' "$_isc")
assert_eq "web-terminal deduplicated (appears once)" "1" "$_wt_count"

assert_contains "3scale-operator added" "$_isc" "3scale-operator"

_op_count=$(count_operators "$_isc")
assert_eq "Combined has 11 operators" "11" "$_op_count"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 5: excl_platform comments out platform section ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=true" "excl_operators=" "excl_additional="

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
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=4.22.5" "excl_operators=" "excl_additional="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_contains "Has minVersion (source)" "$_isc" "minVersion: ${OCP_VER}"
assert_contains "Has maxVersion (target)" "$_isc" "maxVersion: 4.22.5"
assert_contains "Has shortestPath" "$_isc" "shortestPath: true"
assert_contains "Channel is stable-${OCP_MAJOR}" "$_isc" "name: stable-${OCP_MAJOR}"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 6b: Upgrade mode (cross minor), catalog_versions=all ==="
# ============================================================================
# By default only the target minor's catalogs are in the ISC. With
# catalog_versions=all the source minor's catalogs are added too, for a
# cluster installed on the source minor from the same archive.
_x_src="4.21.17" _x_tgt="4.22.18"
if [ -s "$MIRROR_DIR/.index/redhat-operator-index-v4.21" ] && [ -s "$MIRROR_DIR/.index/redhat-operator-index-v4.22" ]; then
	generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=$_x_tgt"
	assert_contains "Default: target minor redhat catalog" "$_isc" "redhat-operator-index:v4.22$"
	assert_not_contains "Default: no source minor catalog" "$_isc" "redhat-operator-index:v4.21$"

	generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=$_x_tgt" "catalog_versions=all"
	_x_ops=$(count_operators "$_isc")

	assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
	assert_contains "Channel is stable-4.22" "$_isc" "name: stable-4.22"
	assert_contains "Has source minor redhat catalog" "$_isc" "redhat-operator-index:v4.21$"
	assert_contains "Has target minor redhat catalog" "$_isc" "redhat-operator-index:v4.22$"
	assert_eq "Two catalogs present" "2" "$(grep -c '^\s*- catalog:' "$_isc" || true)"

	generate_isc "ocp_version=$_x_tgt" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="
	_tgt_ops=$(count_operators "$_isc")
	generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform="
	_src_ops=$(count_operators "$_isc")
	assert_eq "Operators of both minors included" "$(( _src_ops + _tgt_ops ))" "$_x_ops"

	_x_cert=$(awk '{print $1}' "$MIRROR_DIR/.index/certified-operator-index-v4.21" | grep -m1 -xFf <(awk '{print $1}' "$MIRROR_DIR/.index/certified-operator-index-v4.22"))
	_x_comm=$(awk '{print $1}' "$MIRROR_DIR/.index/community-operator-index-v4.21" | grep -m1 -xFf <(awk '{print $1}' "$MIRROR_DIR/.index/community-operator-index-v4.22"))
	generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=" "ops=web-terminal,${_x_cert},${_x_comm}" "excl_platform=" "ocp_upgrade_to=$_x_tgt" "catalog_versions=all"
	assert_eq "Six catalogs present (3 per minor)" "6" "$(grep -c '^\s*- catalog:' "$_isc" || true)"

	generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=all" "ops=" "excl_platform=" "ocp_upgrade_to=$_x_tgt" "catalog_versions=all"
	assert_contains "op_sets=all: source minor catalog" "$_isc" "redhat-operator-index:v4.21$"
	assert_contains "op_sets=all: target minor catalog" "$_isc" "redhat-operator-index:v4.22$"
	assert_file_valid_yaml_operators "op_sets=all: exactly one operators key" "$_isc"

	[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

	# An unknown value must not turn on both catalogs.
	generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=$_x_tgt" "catalog_versions=both"
	assert_contains "Unknown value: target catalog kept" "$_isc" "redhat-operator-index:v4.22$"
	assert_not_contains "Unknown value: source catalog not added" "$_isc" "redhat-operator-index:v4.21$"
	if grep -q "Unknown value catalog_versions=both" "$_isc_stderr"; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: Unknown catalog_versions value is warned"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: Unknown catalog_versions value produced no warning"
	fi

	# The second catalog index is missing. Resolution runs in a subshell, so the
	# parent must see the failure and stop instead of writing a partial ImageSet.
	if generate_isc "ocp_version=$_x_src" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=4.99.1" "catalog_versions=all"; then
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: Missing catalog index should abort"
	elif grep -q "Operator resolution failed" "$_isc_stderr"; then
		PASS=$(( PASS + 1 ))
		echo "  PASS: Missing catalog index aborts the parent"
	else
		FAIL=$(( FAIL + 1 ))
		echo "  FAIL: Missing catalog index exited without the parent abort"
		[[ $VERBOSE -eq 1 ]] && cat "$_isc_stderr"
	fi
else
	echo "  SKIP: needs v4.21 and v4.22 indexes in $MIRROR_DIR/.index/"
fi

# ============================================================================
echo ""
echo "=== Test 6c: catalog_versions=all on one minor does not duplicate ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "ocp_upgrade_to=${OCP_MAJOR}.5" "catalog_versions=all" "excl_operators=" "excl_additional="
assert_eq "Same minor: one redhat catalog" "1" "$(grep -c "redhat-operator-index:v${OCP_MAJOR}$" "$_isc" || true)"

# ============================================================================
echo ""
echo "=== Test 7: Cross-catalog operators ==="
# ============================================================================
_cert_op=$(head -1 "$MIRROR_DIR/.index/certified-operator-index-v${OCP_MAJOR}" | awk '{print $1}')
_comm_op=$(head -1 "$MIRROR_DIR/.index/community-operator-index-v${OCP_MAJOR}" | awk '{print $1}')

generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal,${_cert_op},${_comm_op}" "excl_platform=" "excl_operators=" "excl_additional="

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
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal,nonexistent-bogus-operator-xyz" "excl_platform=" "excl_operators=" "excl_additional="

assert_file_valid_yaml_operators "Exactly one operators key" "$_isc"
assert_contains "Has web-terminal" "$_isc" "web-terminal"
assert_not_contains "No bogus operator" "$_isc" "nonexistent-bogus-operator-xyz"
_op_count=$(count_operators "$_isc")
assert_eq "Only valid operator present" "1" "$_op_count"

# ============================================================================
echo ""
echo "=== Test 9: Display name comments ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=cincinnati-operator" "excl_platform=" "excl_operators=" "excl_additional="

assert_contains "Display name comment for cincinnati" "$_isc" "# OpenShift Update Service"

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 10: Channel name varies by version ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=candidate" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="

assert_contains "Channel is candidate-${OCP_MAJOR}" "$_isc" "name: candidate-${OCP_MAJOR}"

# ============================================================================
echo ""
echo "=== Test 11: ISC file header and structure ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "excl_operators=" "excl_additional="

assert_contains "Has 'File generated by ABA' header" "$_isc" "^# File generated by ABA"
assert_not_contains "No ownership invitation in freshly generated ISC" "$_isc" "ownership transfers to you"
assert_contains "Has ImageSetConfiguration kind" "$_isc" "^kind: ImageSetConfiguration"
assert_contains "Has v2alpha1 API" "$_isc" "apiVersion: mirror.openshift.io/v2alpha1"
assert_contains "Has mirror: key" "$_isc" "^mirror:"
assert_contains "Has platform: key" "$_isc" "^  platform:"

# ============================================================================
echo ""
echo "=== Test 12: Idempotent — same input produces same output ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
_first=$(md5sum "$_isc" | awk '{print $1}')

generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
_second=$(md5sum "$_isc" | awk '{print $1}')

assert_eq "Identical output on regeneration" "$_first" "$_second"

# ============================================================================
echo ""
echo "=== Test 13: Operator channels match catalog index ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=ocp" "ops=" "excl_platform=" "excl_operators=" "excl_additional="

assert_contains "web-terminal has fast channel" "$_isc" 'name: "fast"'
assert_contains "cincinnati has v1 channel" "$_isc" 'name: "v1"'
assert_contains "cli-manager has tech-preview channel" "$_isc" 'name: "tech-preview"'

[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 14: excl_platform comments the whole platform block, keeps operators ==="
# ============================================================================
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=web-terminal" "excl_platform=true" "excl_operators=" "excl_additional="

assert_not_contains "No active platform key" "$_isc" "^  platform:"
assert_not_contains "No active channels" "$_isc" "^    channels:"
assert_not_contains "No active graph" "$_isc" "^    graph:"
assert_contains "Platform block is commented" "$_isc" "^#    graph: true"
assert_contains "Operators section still active" "$_isc" "^  operators:"
assert_contains "Operator package kept" "$_isc" "name: web-terminal"
assert_contains "Exclusion note added" "$_isc" "^# NOTE: Platform/release images excluded"

# ============================================================================
# OKD: no network. The release digest comes from the update graph; the cache is
# seeded and curl is a shim that refuses, so any other lookup fails the run.
# ============================================================================
_okd_bin=$(mktemp -d); _okd_cache=$(mktemp -d); _okd_curl_log="$_okd_cache/curl.log"
_cleanup_files+=("$_okd_bin" "$_okd_cache")
printf '#!/usr/bin/bash\necho "$*" >> "%s"\nexit 22\n' "$_okd_curl_log" > "$_okd_bin/curl"
chmod +x "$_okd_bin/curl"
# Offline registry for "skopeo inspect --raw": a digest with a fixture manifest_<digest>.json is a
# manifest list, any other digest a plain single-architecture image.
cat > "$_okd_bin/skopeo" <<'EOS'
#!/usr/bin/bash
[ -z "${OKD_TEST_SKOPEO_FAIL:-}" ] || exit 1
ref="${*: -1}"; d="${ref##*@sha256:}"
if [ -f "$ABA_CACHE_DIR/../manifest_$d.json" ]; then cat "$ABA_CACHE_DIR/../manifest_$d.json"
else echo '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":[]}'; fi
EOS
chmod +x "$_okd_bin/skopeo"
# architecture override (ARCH is taken from uname -m)
printf '#!/usr/bin/bash\n[ "${1:-}" = "-m" ] && [ -n "${OKD_TEST_UNAME_M:-}" ] && { echo "$OKD_TEST_UNAME_M"; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$_okd_bin/uname"
chmod +x "$_okd_bin/uname"
_okd_old_path="$PATH"
export PATH="$_okd_bin:$PATH" ABA_CACHE_DIR="$_okd_cache/cache"

_okd_dg() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
_okd_seed() { # <channel-minor> <version>...
	local cm="$1"; shift
	mkdir -p "$ABA_CACHE_DIR"
	local v
	for v in "$@"; do
		jq -nc --arg v "$v" --arg p "quay.io/okd/scos-release@sha256:$(_okd_dg "$v")" '{version:$v,payload:$p}'
	done | jq -sc '{nodes: ., edges: []}' > "$ABA_CACHE_DIR/graph_okd_${cm}_amd64.json"
}
# 4.21.0-okd-scos.11 is published as a manifest list: the graph names the list, the ISC must name the amd64 image
_okd_idx="$(_okd_dg index-4.21.0-okd-scos.11)"
mkdir -p "$ABA_CACHE_DIR"
jq -nc --arg a "quay.io/okd/scos-release@sha256:$(_okd_dg 4.21.0-okd-scos.10)" --arg b "quay.io/okd/scos-release@sha256:$_okd_idx" \
	'{nodes:[{version:"4.21.0-okd-scos.10",payload:$a},{version:"4.21.0-okd-scos.11",payload:$b}],edges:[]}' > "$ABA_CACHE_DIR/graph_okd_stable-4.21_amd64.json"
jq -nc --arg d "sha256:$(_okd_dg 4.21.0-okd-scos.11)" '{schemaVersion:2,manifests:[{platform:{architecture:"amd64",os:"linux"},digest:$d}]}' \
	> "$_okd_cache/manifest_$_okd_idx.json"
_okd_seed stable-4.20 4.20.0-okd-scos.8
_okd_seed stable-5.0 5.0.0-okd-scos.5
_okd_seed candidate-4.22 4.22.0-okd-scos.4

# ============================================================================
echo ""
echo "=== Test 15: OKD ISC — release by digest, no channels ==="
# ============================================================================
generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.11" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="

assert_file_valid_yaml_operators "No duplicate operators keys" "$_isc"
assert_contains "Has platform key" "$_isc" "^  platform:"
assert_contains "Release is the child digest of the payload repo" "$_isc" "^    release: quay.io/okd/scos-release@sha256:$(_okd_dg 4.21.0-okd-scos.11)$"
assert_not_contains "Not the manifest list digest" "$_isc" "$(_okd_dg index-4.21.0-okd-scos.11)"
assert_contains "Has architectures" "$_isc" "^    architectures:"
assert_contains "Architecture is amd64" "$_isc" "^    - amd64$"
assert_contains "graph is false" "$_isc" "^    graph: false"
assert_not_contains "No channels block" "$_isc" "channels:"
assert_not_contains "No minVersion" "$_isc" "minVersion"
assert_not_contains "No maxVersion" "$_isc" "maxVersion"
assert_not_contains "No OCP channel type" "$_isc" "type: ocp"
assert_not_contains "No graph: true" "$_isc" "graph: true"
assert_not_contains "No OCP release channel name" "$_isc" "name: (stable|fast|candidate|eus)-"
assert_not_contains "No ocp-release repo" "$_isc" "openshift-release-dev"
assert_contains "Has 'File generated by ABA' header" "$_isc" "^# File generated by ABA"
assert_not_contains "No operators section (core only)" "$_isc" "^  operators:"
assert_not_contains "No registry.redhat.io anywhere (needs an account)" "$_isc" "registry.redhat.io"
assert_contains "Operator hint names the anonymous community catalog" "$_isc" "^#  - catalog: registry.access.redhat.com/redhat/community-operator-index:v4.21$"
[[ $VERBOSE -eq 1 ]] && echo "--- ISC ---" && cat "$_isc" && echo "---"

# ============================================================================
echo ""
echo "=== Test 16: OKD ISC — release follows the selected version (not fixed) ==="
# ============================================================================
generate_isc "distribution=okd" "ocp_version=4.20.0-okd-scos.8" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "4.20 build digest" "$_isc" "^    release: quay.io/okd/scos-release@sha256:$(_okd_dg 4.20.0-okd-scos.8)$"
assert_not_contains "Not the 4.21 digest" "$_isc" "$(_okd_dg 4.21.0-okd-scos.11)"

generate_isc "distribution=okd" "ocp_version=5.0.0-okd-scos.5" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "5.x build digest" "$_isc" "^    release: quay.io/okd/scos-release@sha256:$(_okd_dg 5.0.0-okd-scos.5)$"

generate_isc "distribution=okd" "ocp_version=4.22.0-okd-scos.4" "ocp_channel=candidate" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "candidate channel build digest" "$_isc" "^    release: quay.io/okd/scos-release@sha256:$(_okd_dg 4.22.0-okd-scos.4)$"

generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.10" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "older build of the same minor" "$_isc" "^    release: quay.io/okd/scos-release@sha256:$(_okd_dg 4.21.0-okd-scos.10)$"

mkdir -p "$ABA_CACHE_DIR"
jq -nc --arg v 4.21.0-okd-scos.11 --arg p "quay.io/okd/scos-release@sha256:$(_okd_dg arm-4.21.0-okd-scos.11)" '{nodes:[{version:$v,payload:$p}],edges:[]}' > "$ABA_CACHE_DIR/graph_okd_stable-4.21_arm64.json"
OKD_TEST_UNAME_M=aarch64 generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.11" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "arm64 host: arm64 image digest" "$_isc" "^    release: quay.io/okd/scos-release@sha256:$(_okd_dg arm-4.21.0-okd-scos.11)$"
assert_contains "arm64 host: architectures lists arm64" "$_isc" "^    - arm64$"
assert_not_contains "arm64 host: amd64 not listed" "$_isc" "^    - amd64$"

# ============================================================================
echo ""
echo "=== Test 17: OKD excl_platform keeps additionalImages (range does not run to EOF) ==="
# ============================================================================
# images.conf is swapped in for the run and restored right after (like aba.conf)
_img_conf="$ABA_ROOT/images.conf"; _img_bak=$(mktemp); _img_had=0
[ -f "$_img_conf" ] && { _img_had=1; cp "$_img_conf" "$_img_bak"; }
_img_restore() { if [ $_img_had -eq 1 ]; then cp "$_img_bak" "$_img_conf"; else rm -f "$_img_conf"; fi; }
printf 'registry.access.redhat.com/ubi9/ubi:latest\nquay.io/openshift/hello-openshift:1.2.0\n' > "$_img_conf"
generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.11" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=true" "excl_operators=" "excl_additional="
_img_restore

assert_not_contains "No active platform key" "$_isc" "^  platform:"
assert_not_contains "No active release" "$_isc" "^    release:"
assert_not_contains "No active graph" "$_isc" "^    graph:"
assert_not_contains "No active architectures" "$_isc" "^    architectures:"
assert_contains "Platform block commented (release)" "$_isc" "^#    release: quay.io/okd/scos-release@sha256:"
assert_contains "Platform block commented (graph)" "$_isc" "^#    graph: false"
assert_contains "additionalImages still active" "$_isc" "^  additionalImages:"
assert_contains "First additional image kept" "$_isc" "^  - name: registry.access.redhat.com/ubi9/ubi:latest"
assert_contains "Second additional image kept" "$_isc" "^  - name: quay.io/openshift/hello-openshift:1.2.0"
assert_contains "Exclusion note added" "$_isc" "^# NOTE: Platform/release images excluded"

# same input without excl_platform: platform active and additionalImages after it
printf 'registry.access.redhat.com/ubi9/ubi:latest\n' > "$_img_conf"
generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.11" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
_img_restore; rm -f "$_img_bak"
assert_contains "Platform active with additionalImages" "$_isc" "^    graph: false"
assert_contains "additionalImages active" "$_isc" "^  additionalImages:"

# ============================================================================
echo ""
echo "=== Test 18: OKD excl_platform alone (nothing after the platform block) ==="
# ============================================================================
generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.11" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=true" "excl_operators=" "excl_additional="
assert_not_contains "No active key under mirror (only comments)" "$_isc" "^  [a-z]"
assert_contains "Platform commented" "$_isc" "^#  platform:"

# ============================================================================
echo ""
echo "=== Test 19: OKD without a release digest source fails, writes no ISC ==="
# ============================================================================
rm -f "$MIRROR_DIR/data/imageset-config.yaml"
if generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.99" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional=" 2>/dev/null; then
	FAIL=$(( FAIL + 1 )); echo "  FAIL: generation succeeded for a build with no digest"
else
	PASS=$(( PASS + 1 )); echo "  PASS: generation failed for a build with no digest"
fi
if [ -s "$MIRROR_DIR/data/imageset-config.yaml" ]; then
	FAIL=$(( FAIL + 1 )); echo "  FAIL: an ISC was written without a digest"
else
	PASS=$(( PASS + 1 )); echo "  PASS: no ISC written without a digest"
fi

# ============================================================================
echo ""
echo "=== Test 19a: OKD digest found but its manifest cannot be read ==="
# ============================================================================
rm -f "$MIRROR_DIR/data/imageset-config.yaml"
if OKD_TEST_SKOPEO_FAIL=1 generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.10" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional=" 2>/dev/null; then
	FAIL=$(( FAIL + 1 )); echo "  FAIL: generation succeeded although the release manifest is unreadable"
else
	PASS=$(( PASS + 1 )); echo "  PASS: generation failed when the release manifest is unreadable"
fi
assert_contains "Message names the manifest problem" "$_isc_stderr" "Cannot read the release image manifest of OKD 4.21.0-okd-scos.10"
assert_not_contains "Not reported as a missing digest" "$_isc_stderr" "Cannot find the release image digest"
[ -s "$MIRROR_DIR/data/imageset-config.yaml" ] && { FAIL=$(( FAIL + 1 )); echo "  FAIL: an ISC was written"; } || { PASS=$(( PASS + 1 )); echo "  PASS: no ISC written"; }
generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.99" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional=" 2>/dev/null
assert_contains "Unknown build is reported as a missing digest" "$_isc_stderr" "Cannot find the release image digest of OKD 4.21.0-okd-scos.99"

# ============================================================================
echo ""
echo "=== Test 19b: OKD with the platform excluded needs no digest ==="
# ============================================================================
generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.99" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=true" "excl_operators=" "excl_additional="
assert_not_contains "No active platform key" "$_isc" "^  platform:"
assert_not_contains "No active release" "$_isc" "^    release:"
assert_contains "Platform commented" "$_isc" "^#  platform:"

# ============================================================================
echo ""
echo "=== Test 19c: OKD operators come from the anonymous community catalog only ==="
# ============================================================================
# Catalog index fixtures for 4.21 in mirror/.index; the originals are put back afterwards.
_idx="$MIRROR_DIR/.index"; _idx_bak=$(mktemp -d); _cleanup_files+=("$_idx_bak"); mkdir -p "$_idx"
_idx_save() { local f; for f in redhat-operator certified-operator community-operator; do
	if [ -e "$_idx/${f}-index-v4.21" ]; then cp -p "$_idx/${f}-index-v4.21" "$_idx_bak/"; else touch "$_idx_bak/${f}-index-v4.21.absent"; fi; done; }
_idx_restore() { local f; for f in redhat-operator certified-operator community-operator; do
	rm -f "$_idx/${f}-index-v4.21"; [ -e "$_idx_bak/${f}-index-v4.21" ] && cp -p "$_idx_bak/${f}-index-v4.21" "$_idx/"; done; }
_idx_put() { printf '%s\n' "${@:2}" > "$_idx/${1}-index-v4.21"; }
_idx_save
_okd_ops() { generate_isc "distribution=okd" "ocp_version=4.21.0-okd-scos.11" "ocp_channel=stable" "op_sets=${2:-}" "ops=$1" "excl_platform=" "excl_operators=" "excl_additional="; }

# only the community index is on disk (what OKD downloads)
rm -f "$_idx/redhat-operator-index-v4.21" "$_idx/certified-operator-index-v4.21"
_idx_put community-operator "zz-community-one Community One alpha" "zz-community-two Community Two stable"
_okd_ops "zz-community-one,zz-community-two"; rc=$?
assert_eq "community operators: generation succeeds" "0" "$rc"
assert_contains "community catalog from the anonymous host" "$_isc" "^  - catalog: registry.access.redhat.com/redhat/community-operator-index:v4.21$"
assert_contains "first operator listed" "$_isc" "name: zz-community-one"
assert_contains "second operator listed" "$_isc" "name: zz-community-two"
assert_contains "operator channel taken from the index" "$_isc" 'name: "alpha"'
assert_not_contains "no registry.redhat.io (needs an account)" "$_isc" "registry.redhat.io"
assert_not_contains "no redhat-operator catalog" "$_isc" "redhat-operator-index"
assert_not_contains "no certified-operator catalog" "$_isc" "certified-operator-index"
assert_eq "exactly one catalog entry" "1" "$(grep -c '^  - catalog:' "$_isc")"
assert_file_valid_yaml_operators "one operators key" "$_isc"
assert_not_contains "no complaint about the redhat/certified index files" "$_isc_stderr" "Missing operator catalog file"

# an operator the community catalog lacks is skipped like any unknown operator
_okd_ops "zz-community-one,zz-not-anywhere"
assert_contains "known operator kept" "$_isc" "name: zz-community-one"
assert_not_contains "unknown operator skipped" "$_isc" "zz-not-anywhere"

# the shipped redhat/certified indexes are on disk as well: an operator found only there is refused
_idx_put redhat-operator "zz-redhat-only Red Hat Only stable" "zz-both Both stable-r"
_idx_put certified-operator "zz-certified-only Certified Only fast"
_idx_put community-operator "zz-community-one Community One alpha" "zz-both Both community-ch"
rm -f "$MIRROR_DIR/data/imageset-config.yaml"
if _okd_ops "zz-redhat-only" 2>/dev/null; then FAIL=$(( FAIL + 1 )); echo "  FAIL: a redhat-only operator was accepted on OKD"; else PASS=$(( PASS + 1 )); echo "  PASS: a redhat-only operator is refused on OKD"; fi
assert_contains "refusal names the operator" "$_isc_stderr" "zz-redhat-only"
assert_contains "refusal explains the account requirement" "$_isc_stderr" "Red Hat account"
[ -s "$MIRROR_DIR/data/imageset-config.yaml" ] && { FAIL=$(( FAIL + 1 )); echo "  FAIL: an ISC was written"; } || { PASS=$(( PASS + 1 )); echo "  PASS: no ISC written"; }
rm -f "$MIRROR_DIR/data/imageset-config.yaml"
if _okd_ops "zz-certified-only" 2>/dev/null; then FAIL=$(( FAIL + 1 )); echo "  FAIL: a certified-only operator was accepted on OKD"; else PASS=$(( PASS + 1 )); echo "  PASS: a certified-only operator is refused on OKD"; fi
# an operator in both catalogs resolves to the community one
_okd_ops "zz-both"
assert_contains "operator in both: community catalog" "$_isc" "^  - catalog: registry.access.redhat.com/redhat/community-operator-index:v4.21$"
assert_contains "operator in both: community channel" "$_isc" 'name: "community-ch"'
assert_not_contains "operator in both: not the redhat channel" "$_isc" 'name: "stable-r"'
assert_not_contains "operator in both: no redhat catalog" "$_isc" "registry.redhat.io"
# op_sets=all is the whole redhat catalog
rm -f "$MIRROR_DIR/data/imageset-config.yaml"
if _okd_ops "" "all" 2>/dev/null; then FAIL=$(( FAIL + 1 )); echo "  FAIL: op_sets=all accepted on OKD"; else PASS=$(( PASS + 1 )); echo "  PASS: op_sets=all refused on OKD"; fi
assert_not_contains "op_sets=all: nothing from registry.redhat.io written" "$MIRROR_DIR/data/imageset-config.yaml" "registry.redhat.io"

# no community index on disk: the message names that file, not the redhat one
rm -f "$_idx/redhat-operator-index-v4.21" "$_idx/certified-operator-index-v4.21" "$_idx/community-operator-index-v4.21"
rm -f "$MIRROR_DIR/data/imageset-config.yaml"
if _okd_ops "zz-community-one" 2>/dev/null; then FAIL=$(( FAIL + 1 )); echo "  FAIL: generation succeeded without the community index"; else PASS=$(( PASS + 1 )); echo "  PASS: generation fails without the community index"; fi
assert_contains "message names the community index file" "$_isc_stderr" "community-operator-index-v4.21"
assert_not_contains "message does not ask for the redhat index" "$_isc_stderr" "redhat-operator-index-v4.21"
assert_not_contains "message does not point at registry.redhat.io" "$_isc_stderr" "registry.redhat.io"

# OCP with the same kind of fixtures keeps all three catalogs on registry.redhat.io
_idx_put redhat-operator "zz-redhat-only Red Hat Only stable"
_idx_put certified-operator "zz-certified-only Certified Only fast"
_idx_put community-operator "zz-community-one Community One alpha"
generate_isc "ocp_version=4.21.0" "ocp_channel=stable" "op_sets=" "ops=zz-redhat-only,zz-certified-only,zz-community-one" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "ocp: redhat catalog on registry.redhat.io" "$_isc" "^  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21$"
assert_contains "ocp: certified catalog on registry.redhat.io" "$_isc" "^  - catalog: registry.redhat.io/redhat/certified-operator-index:v4.21$"
assert_contains "ocp: community catalog on registry.redhat.io" "$_isc" "^  - catalog: registry.redhat.io/redhat/community-operator-index:v4.21$"
assert_not_contains "ocp: nothing from registry.access.redhat.com" "$_isc" "registry.access.redhat.com"
_idx_restore

# ============================================================================
echo ""
echo "=== Test 20: OCP generation does not look at OKD data ==="
# ============================================================================
rm -rf "$ABA_CACHE_DIR"; : > "$_okd_curl_log"
generate_isc "ocp_version=$OCP_VER" "ocp_channel=stable" "op_sets=" "ops=" "excl_platform=" "excl_operators=" "excl_additional="
assert_contains "OCP still has channels" "$_isc" "name: stable-${OCP_MAJOR}"
assert_contains "OCP still graph true" "$_isc" "graph: true"
assert_not_contains "OCP has no release key" "$_isc" "^    release:"
assert_eq "No OKD cache created by an OCP run" "0" "$(ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c okd)"
assert_eq "No lookup made by an OCP run" "0" "$(wc -l < "$_okd_curl_log" | tr -d ' ')"

export PATH="$_okd_old_path"
unset ABA_CACHE_DIR

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================"
echo "  ISC Generation Tests: $PASS passed, $FAIL failed"
echo "========================================"

[ $FAIL -gt 0 ] && exit 1
exit 0
