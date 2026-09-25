#!/bin/bash
# =============================================================================
# Verify all operator set dependencies are satisfied
# =============================================================================
# Checks that every operator in templates/operator-set-* has its dependencies
# (from the OLM catalog) also present in at least one operator set.
#
# Requires: podman, jq, access to registry.redhat.io
# Uses tools/listopdeps.sh to extract dependencies from catalog images.
#
# Usage: tools/verify-operator-deps.sh [version] [--fix]
#   version   OCP minor version (default: 4.22)
#   --fix     Print suggested additions (not yet implemented)
#
# Exit codes:
#   0 = All dependencies satisfied
#   1 = Missing dependencies found
# =============================================================================

set -e

cd "$(dirname "$0")/.." || exit 1

version="${1:-4.22}"
[[ "$version" == "--fix" ]] && version="4.22"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Operator Set Dependency Verification (OCP ${version}) ===${NC}\n"

# Collect all operators across all sets
all_ops=$(grep -hv '^#' templates/operator-set-* | grep -v '^$' | awk '{print $1}' | sort -u)
op_count=$(echo "$all_ops" | wc -l)
echo -e "Operators in sets: ${op_count}\n"

# Extract catalogs (reuses cache from previous runs)
echo -e "${YELLOW}Extracting catalog configs (cached if already present)...${NC}"
for catalog in redhat-operator certified-operator; do
	configs_dir="/tmp/aba-configs-${catalog}-${version}"
	if [ ! -d "$configs_dir" ] || [ "$(ls "$configs_dir" 2>/dev/null | head -1)" = "" ]; then
		echo "  Pulling ${catalog}-index:v${version}..."
		existing_id=$(podman ps -a | grep "registry.redhat.io/redhat/${catalog}-index:v${version}" | awk '{print $1}')
		if [ -z "$existing_id" ]; then
			podman create -q --replace --name "${catalog}-catalog" \
				"registry.redhat.io/redhat/${catalog}-index:v${version}" >/dev/null || {
				echo -e "${RED}Failed to pull ${catalog}-index:v${version}${NC}" >&2
				exit 1
			}
			existing_id=$(podman ps -a | grep "registry.redhat.io/redhat/${catalog}-index:v${version}" | awk '{print $1}')
		fi
		podman cp "${existing_id}:/configs" "$configs_dir"
	fi
	echo -e "  ${GREEN}✓ ${configs_dir} ready${NC}"
done
echo

# Helper: get direct deps for one operator
_get_deps() {
	local op="$1" op_dir
	for configs_dir in "/tmp/aba-configs-redhat-operator-${version}" "/tmp/aba-configs-certified-operator-${version}"; do
		op_dir="$configs_dir/$op"
		[ -d "$op_dir" ] || continue
		if [ -f "$op_dir/catalog.json" ]; then
			jq -r 'select(.package=="'"$op"'") | .properties[]? | select(.type=="olm.package.required") | .value.packageName' "$op_dir/catalog.json" 2>/dev/null | sort -u
			return
		elif [ -d "$op_dir/bundles" ]; then
			local latest
			latest=$(ls "$op_dir/bundles/" | sort -V | tail -1)
			[ -n "$latest" ] && jq -r '.properties[]? | select(.type=="olm.package.required") | .value.packageName' "$op_dir/bundles/$latest" 2>/dev/null | sort -u
			return
		fi
	done
}

# Check each set's operators have deps satisfied WITHIN that set
echo -e "${YELLOW}Checking per-set dependencies...${NC}\n"
missing_count=0
sets_checked=0

for setfile in templates/operator-set-*; do
	[ -f "$setfile" ] || continue
	setname="${setfile##*operator-set-}"
	set_ops=$(grep -v '^#' "$setfile" | grep -v '^$' | awk '{print $1}' | sort -u)
	sets_checked=$(( sets_checked + 1 ))

	for op in $set_ops; do
		# BFS recursive dep walk
		declare -A _visited=()
		_queue=("$op")
		while [ ${#_queue[@]} -gt 0 ]; do
			_current="${_queue[0]}"
			_queue=("${_queue[@]:1}")
			[ -n "${_visited[$_current]:-}" ] && continue
			_visited["$_current"]=1

			deps=$(_get_deps "$_current")
			for dep in $deps; do
				if [ -z "${_visited[$dep]:-}" ]; then
					_queue+=("$dep")
					if ! echo "$set_ops" | grep -qx "$dep"; then
						printf "  ${RED}⚠ set '%-12s  %-35s requires '%-25s — MISSING${NC}\n" "${setname}':" "$op" "${dep}'"
						missing_count=$(( missing_count + 1 ))
					fi
				fi
			done
		done
		unset _visited
	done
done

echo
if [ $missing_count -gt 0 ]; then
	echo -e "${RED}✗ Found $missing_count missing dependencies across $sets_checked sets${NC}"
	exit 1
else
	echo -e "${GREEN}✓ All dependencies satisfied within each of $sets_checked sets${NC}"
	exit 0
fi
