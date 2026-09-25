#!/bin/bash
# =============================================================================
# Functional test: operator set validation
# =============================================================================
# Verifies:
#   1. All operator-set-* files parse correctly (no empty lines after stripping)
#   2. Every operator name exists in at least one shipped catalog index
#   3. All sets include cincinnati-operator
#   4. No duplicate operators within a single set
#   5. Set names are valid (lowercase, digits, hyphens)
#   6. Every set has a "# Name:" header
#   7. Operator dependency check (if catalog configs are available on disk)
#
# Uses shipped catalog indexes in catalogs/ (no podman needed for steps 1-6).
# Step 7 uses pre-extracted configs-*-operator-* dirs if present (optional).
#
# Usage:  test-operator-sets.sh [version]
#   version   OCP minor version for catalog lookup (default: auto-detect latest GA)
#
# Exit code: 0 if all pass, 1 if any fail.
# =============================================================================

set -o pipefail

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

failed=0
pass() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; failed=1; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }

# Auto-detect latest GA catalog (100+ entries)
if [ -n "$1" ]; then
	ver="$1"
else
	ver=""
	for f in $(ls catalogs/redhat-operator-index-v4.* 2>/dev/null | sort -rV); do
		[ "$(wc -l < "$f")" -ge 100 ] && ver=$(echo "$f" | grep -oE 'v[0-9]+\.[0-9]+' | sed 's/^v//') && break
	done
fi

if [ -z "$ver" ]; then
	echo -e "${RED}No suitable catalog index found in catalogs/${NC}"
	exit 1
fi

echo -e "${YELLOW}=== Operator Set Tests (catalog v${ver}) ===${NC}\n"

# Build lookup of all catalog operators
all_catalog_ops=$(mktemp)
trap "rm -f $all_catalog_ops" EXIT
cat catalogs/redhat-operator-index-v${ver} \
    catalogs/certified-operator-index-v${ver} \
    catalogs/community-operator-index-v${ver} 2>/dev/null | awk '{print $1}' | sort -u > "$all_catalog_ops"

catalog_count=$(wc -l < "$all_catalog_ops")
echo -e "Catalog operators (v${ver}): ${catalog_count}\n"

# Collect all set files
set_files=$(ls templates/operator-set-* 2>/dev/null)
set_count=$(echo "$set_files" | wc -l)

# ─── Test 1: Set file structure ───────────────────────────────────────────────
echo -e "${YELLOW}[1/7] Set file structure...${NC}"
for f in $set_files; do
	name="${f##*operator-set-}"

	# Must have # Name: header
	if ! head -1 "$f" | grep -q '^# Name:'; then
		fail "$name: missing '# Name:' header on line 1"
	fi

	# Set name must be valid (lowercase, digits, hyphens)
	if ! echo "$name" | grep -qE '^[a-z0-9][-a-z0-9]*$'; then
		fail "$name: invalid set name (must be lowercase letters, digits, hyphens)"
	fi
done
[ $failed -eq 0 ] && pass "All $set_count sets have valid structure"

# ─── Test 2: Operator names exist in catalogs ────────────────────────────────
echo -e "${YELLOW}[2/7] Operator names in catalogs...${NC}"
t2_bad=0
t2_total=0
for f in $set_files; do
	name="${f##*operator-set-}"
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "$line" ]] && continue
		op="${line%%#*}"
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		[[ -z "$op" ]] && continue
		t2_total=$(( t2_total + 1 ))
		if ! grep -qx "$op" "$all_catalog_ops"; then
			warn "'$op' (in set '$name') not in v${ver} catalog"
			t2_bad=$(( t2_bad + 1 ))
		fi
	done < "$f"
done
if [ $t2_bad -eq 0 ]; then
	pass "All $t2_total operators found in v${ver} catalogs"
else
	warn "$t2_bad of $t2_total operators not in v${ver} catalogs (may be valid for older versions)"
fi

# ─── Test 3: All sets include cincinnati-operator ─────────────────────────────
echo -e "${YELLOW}[3/7] cincinnati-operator in all sets...${NC}"
t3_missing=""
for f in $set_files; do
	name="${f##*operator-set-}"
	if ! grep -q 'cincinnati-operator' "$f"; then
		t3_missing="$t3_missing $name"
	fi
done
if [ -z "$t3_missing" ]; then
	pass "All $set_count sets include cincinnati-operator"
else
	fail "Sets missing cincinnati-operator:$t3_missing"
fi

# ─── Test 4: No duplicates within a single set ───────────────────────────────
echo -e "${YELLOW}[4/7] No duplicate operators within sets...${NC}"
t4_bad=0
for f in $set_files; do
	name="${f##*operator-set-}"
	dups=$(grep -v '^#' "$f" | grep -v '^$' | awk '{print $1}' | sort | uniq -d)
	if [ -n "$dups" ]; then
		fail "$name: duplicate operators: $dups"
		t4_bad=1
	fi
done
[ $t4_bad -eq 0 ] && pass "No duplicates within any set"

# ─── Test 5: Operator extraction from set files ──────────────────────────────
echo -e "${YELLOW}[5/7] Set file parsing (comments, whitespace, inline comments)...${NC}"
t5_bad=0
for f in $set_files; do
	name="${f##*operator-set-}"
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "$line" ]] && continue
		op="${line%%#*}"
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		[[ -z "$op" ]] && continue
		# Operator name must not contain spaces or special chars
		if echo "$op" | grep -qE '[[:space:]]|[^a-z0-9._-]'; then
			fail "$name: bad operator name after parsing: '$op'"
			t5_bad=1
		fi
	done < "$f"
done
[ $t5_bad -eq 0 ] && pass "All set files parse cleanly"

# ─── Test 6: Set names match aba.sh regex ────────────────────────────────────
echo -e "${YELLOW}[6/7] Set names match aba.conf op_sets validation...${NC}"
t6_bad=0
for f in $set_files; do
	name="${f##*operator-set-}"
	if ! echo "$name" | grep -qE '^[a-z0-9][-a-z0-9]*$'; then
		fail "Set name '$name' would fail aba.conf validation"
		t6_bad=1
	fi
done
[ $t6_bad -eq 0 ] && pass "All set names pass validation regex"

# ─── Test 7: Dependency check (optional — needs extracted configs) ────────────
echo -e "${YELLOW}[7/7] Operator dependencies...${NC}"
configs_rh="/tmp/aba-configs-redhat-operator-${ver}"
configs_cert="/tmp/aba-configs-certified-operator-${ver}"

if [ -d "$configs_rh" ]; then
	_get_deps() {
		local op="$1" op_dir
		for cdir in "$configs_rh" "$configs_cert"; do
			op_dir="$cdir/$op"
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

	t7_missing=0

	for _setfile in $set_files; do
		_setname="${_setfile##*operator-set-}"
		# Collect operators in THIS set
		set_ops=$(grep -v '^#' "$_setfile" | grep -v '^$' | awk '{print $1}' | sort -u)

		for op in $set_ops; do
			# Recursive BFS within this set
			declare -A _vis=()
			_q=("$op")
			while [ ${#_q[@]} -gt 0 ]; do
				_cur="${_q[0]}"
				_q=("${_q[@]:1}")
				[ -n "${_vis[$_cur]:-}" ] && continue
				_vis["$_cur"]=1
				deps=$(_get_deps "$_cur")
				for dep in $deps; do
					if [ -z "${_vis[$dep]:-}" ]; then
						_q+=("$dep")
						if ! echo "$set_ops" | grep -qx "$dep"; then
							fail "set '$_setname': '$op' requires '$dep' — missing from this set"
							t7_missing=$(( t7_missing + 1 ))
						fi
					fi
				done
			done
			unset _vis
		done
	done

	if [ $t7_missing -eq 0 ]; then
		pass "All operator dependencies satisfied within each set"
	fi
else
	warn "Skipped (no extracted catalog configs at $configs_rh — run tools/verify-operator-deps.sh first)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
if [ $failed -eq 0 ]; then
	echo -e "${GREEN}=== All operator set tests passed ===${NC}"
	exit 0
else
	echo -e "${RED}=== Some operator set tests FAILED ===${NC}"
	exit 1
fi
