#!/bin/bash
# Test: Verify $ABA_ROOT is ONLY used in aba.sh and TUI
# 
# Architecture Rule:
#   $ABA_ROOT must ONLY be used in:
#     - scripts/aba.sh
#     - tui/abatui.sh
#
#   All other scripts must:
#     1. cd "$(dirname "$0")/.." || exit 1
#     2. Use relative paths (e.g., mirror/.index, scripts/include_all.sh)
#
# Rationale:
#   - aba.sh sets $ABA_ROOT and changes to it before calling other scripts
#   - Other scripts may be called via make (from subdirs) without $ABA_ROOT set
#   - Using relative paths after cd to aba root ensures consistency

set -e

cd "$(dirname "$0")/../.."

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }
test_warn() { echo -e "${YELLOW}⚠ WARN${NC}: $1"; }

echo
echo "=== Testing: \$ABA_ROOT usage is restricted to aba.sh and TUI only ==="
echo

# Allowed files (exceptions to the rule)
ALLOWED_FILES=(
	"scripts/aba.sh"
	"tui/abatui.sh"
)

# Find all shell scripts that contain $ABA_ROOT
# Exclude comments that are just explaining the variable (e.g., "# Note: aba.sh changes to $ABA_ROOT...")
violators=()
while IFS= read -r file; do
	# Skip if it's an allowed file
	is_allowed=0
	for allowed in "${ALLOWED_FILES[@]}"; do
		if [[ "$file" == "$allowed" ]]; then
			is_allowed=1
			break
		fi
	done
	
	if [[ $is_allowed -eq 0 ]]; then
		# Check if the file has actual $ABA_ROOT usage (not just comments)
		if grep -q '^\s*[^#]*\$ABA_ROOT' "$file" 2>/dev/null; then
			violators+=("$file")
		fi
	fi
done < <(grep -l '\$ABA_ROOT' scripts/*.sh tui/*.sh 2>/dev/null || true)

# Report results
if [[ ${#violators[@]} -eq 0 ]]; then
	test_pass "No unauthorized \$ABA_ROOT usage found"
	echo
	echo "Allowed files (verified):"
	for file in "${ALLOWED_FILES[@]}"; do
		if [[ -f "$file" ]]; then
			count=$(grep -c '\$ABA_ROOT' "$file" 2>/dev/null || echo "0")
			echo "  ✓ $file ($count usages)"
		fi
	done
	echo
	test_pass "Architecture rule enforced: \$ABA_ROOT only in aba.sh and TUI"
else
	echo -e "${RED}✗ FAIL: Unauthorized \$ABA_ROOT usage detected!${NC}"
	echo
	echo "The following files violate the architecture rule:"
	for file in "${violators[@]}"; do
		echo -e "  ${RED}✗ $file${NC}"
		echo "    Lines:"
		grep -n '^\s*[^#]*\$ABA_ROOT' "$file" | sed 's/^/      /'
	done
	echo
	echo "Architecture Rule Violation:"
	echo "  \$ABA_ROOT must ONLY be used in:"
	echo "    - scripts/aba.sh"
	echo "    - tui/abatui.sh"
	echo
	echo "Fix by:"
	echo "  1. Add at script start: cd \"\$(dirname \"\$0\")/..\" || exit 1"
	echo "  2. Replace \$ABA_ROOT/scripts/... with scripts/..."
	echo "  3. Replace \$ABA_ROOT/mirror/... with mirror/..."
	echo "  4. Replace \$ABA_ROOT/templates/... with templates/..."
	echo
	test_fail "Architecture rule violated"
fi

echo
echo -e "${GREEN}=== Test Complete ===${NC}"
echo
