#!/bin/bash
# Canary test: verify operator catalog extraction works for recent OCP versions.
#
# Calls the production entry point (download-catalog-index.sh) to test the full
# code path including wrapper logic, caching, and fallback. Auto-detects available
# OCP catalog versions (4.16+).
#
# Usage:
#   test-catalog-canary.sh                    # test the 3 most recent versions
#   test-catalog-canary.sh --recent 5         # test the 5 most recent versions
#   test-catalog-canary.sh --all              # test all available versions (4.16+)
#   test-catalog-canary.sh 4.20 4.21          # test specific versions only
#
# Exit code: 0 if all pass, 1 if any fail.

set -eo pipefail

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CATALOGS="redhat-operator certified-operator community-operator"
MIN_OPERATORS=5
INDEX_DIR=".index"
RECENT=3

passed=0
failed=0
results=()

# --- Version detection ---

_detect_versions() {
	local versions=()
	local minor=16
	while true; do
		local ver="4.${minor}"
		if skopeo inspect --raw "docker://registry.redhat.io/redhat/redhat-operator-index:v${ver}" >/dev/null 2>&1; then
			versions+=("$ver")
			minor=$(( minor + 1 ))
		else
			break
		fi
	done
	echo "${versions[*]}"
}

# --- Argument parsing ---

EXPLICIT_VERSIONS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--recent|-r)  RECENT="$2"; shift 2 ;;
		--all|-a)     RECENT=0; shift ;;
		-*)           echo "Unknown option: $1"; exit 1 ;;
		*)            EXPLICIT_VERSIONS+=("$1"); shift ;;
	esac
done

if [[ ${#EXPLICIT_VERSIONS[@]} -gt 0 ]]; then
	VERSIONS="${EXPLICIT_VERSIONS[*]}"
	echo -e "${CYAN}=== Testing specified versions: ${VERSIONS} ===${NC}"
else
	echo -e "${CYAN}=== Detecting available catalog versions ... ===${NC}"
	ALL_VERSIONS=$(_detect_versions)
	if [[ -z "$ALL_VERSIONS" ]]; then
		echo -e "${RED}ERROR: Could not detect any catalog versions${NC}"
		exit 1
	fi
	read -ra _ver_arr <<< "$ALL_VERSIONS"
	if (( RECENT > 0 && ${#_ver_arr[@]} > RECENT )); then
		_ver_arr=("${_ver_arr[@]: -$RECENT}")
		echo -e "${CYAN}=== Testing ${RECENT} most recent of: ${ALL_VERSIONS} ===${NC}"
	else
		echo -e "${CYAN}=== Testing all detected versions: ${ALL_VERSIONS} ===${NC}"
	fi
	VERSIONS="${_ver_arr[*]}"
fi
echo -e "${CYAN}=== Versions under test: ${VERSIONS} ===${NC}"
echo

# --- Per-combo test ---

_test_combo() {
	local catalog="$1" ver="$2"
	local index_file="${INDEX_DIR}/${catalog}-index-v${ver}"
	local expected_count_file="${INDEX_DIR}/.${catalog}-index-v${ver}.expected-count"
	local yaml_file="mirror/imageset-config-${catalog}-catalog-v${ver}.yaml"
	local tag="${catalog} v${ver}"
	local errors=()

	# Clean previous results for this combo
	rm -f "$index_file" "$expected_count_file" "$yaml_file"

	echo -e "${CYAN}--- ${tag} ---${NC}"

	# Run the production entry point (download-catalog-index.sh)
	# This tests the full code path that ABA core uses
	if ! scripts/download-catalog-index.sh "$catalog" "$ver" >/dev/null 2>&1; then
		echo -e "  ${RED}FAIL${NC}: download-catalog-index.sh returned non-zero exit code"
		results+=("FAIL  ${tag}  extraction error")
		((failed++)) || true
		return
	fi

	# Non-empty check
	if [[ ! -s "$index_file" ]]; then
		errors+=("empty output")
	fi

	local count=0
	[[ -s "$index_file" ]] && count=$(wc -l < "$index_file")

	# Sane count
	if (( count < MIN_OPERATORS )); then
		errors+=("only ${count} operators (min ${MIN_OPERATORS})")
	fi

	# Completeness check: compare extracted count against /configs/ directory count
	# (download-catalog-index.sh writes .expected-count as a hidden file)
	local expected=0
	if [[ -f "$expected_count_file" ]]; then
		expected=$(< "$expected_count_file")
		if (( expected > 0 && count != expected )); then
			errors+=("extracted ${count} but catalog has ${expected} operator dirs")
		fi
	fi

	# Format check: every line must have non-empty $1 and $NF
	local bad_lines=0
	if [[ -s "$index_file" ]]; then
		bad_lines=$(awk '{if ($1 == "" || $NF == "") print}' "$index_file" | wc -l)
		if (( bad_lines > 0 )); then
			errors+=("${bad_lines} lines with blank name or channel")
		fi
	fi

	# Display name coverage
	local with_display=0
	if [[ -s "$index_file" ]]; then
		with_display=$(awk '{$1=""; $NF=""; gsub(/^ +| +$/, ""); if ($0 != "" && $0 != "-") count++} END {print count+0}' "$index_file")
	fi
	local missing_display=$(( count - with_display ))
	if (( missing_display > 0 )); then
		errors+=("${missing_display} operators missing display names")
		echo -e "  ${YELLOW}Missing display names:${NC}"
		awk '{dn=$0; sub(/^[^ ]+ +/,"",dn); sub(/ +[^ ]+$/,"",dn); gsub(/^ +| +$/,"",dn); if (dn == "" || dn == "-") print "    "$1}' "$index_file"
	fi

	# Clean up test artifacts and cached image
	rm -f "$index_file" "$expected_count_file" "$done_file" "$yaml_file"
	podman rmi "registry.redhat.io/redhat/${catalog}-index:v${ver}" >/dev/null 2>&1 || true

	if [[ ${#errors[@]} -gt 0 ]]; then
		local err_msg
		err_msg=$(IFS=', '; echo "${errors[*]}")
		echo -e "  ${RED}FAIL${NC}: ${err_msg}"
		results+=("FAIL  ${tag}  ${err_msg}")
		((failed++)) || true
	else
		local pct=0
		(( count > 0 )) && pct=$(( with_display * 100 / count ))
		local count_display="${count}"
		(( expected > 0 )) && count_display="${count}/${expected}"
		echo -e "  ${GREEN}PASS${NC}: ${count_display} operators, display names: ${with_display}/${count} (${pct}%), format: OK"
		results+=("PASS  ${tag}  ops=${count_display}  display=${pct}%")
		((passed++)) || true
	fi
}

# --- Main loop ---

for ver in $VERSIONS; do
	for catalog in $CATALOGS; do
		_test_combo "$catalog" "$ver"
	done
	echo
done

# --- Summary ---

echo -e "${CYAN}=== Summary ===${NC}"
echo
for r in "${results[@]}"; do
	if [[ "$r" == PASS* ]]; then
		echo -e "  ${GREEN}${r}${NC}"
	else
		echo -e "  ${RED}${r}${NC}"
	fi
done
echo
total=$(( passed + failed ))
echo -e "  Total: ${total} tested -- ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}"
echo

exit $(( failed > 0 ? 1 : 0 ))
