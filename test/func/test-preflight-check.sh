#!/bin/bash
# Test: Verify scripts/preflight-check.sh structure and coding standards
# Unit test (fast, static, no network)

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }

SCRIPT="scripts/preflight-check.sh"

echo
echo "=== Testing: $SCRIPT ==="
echo

# 1. Script exists
[ -f "$SCRIPT" ] && test_pass "Script exists" || test_fail "Script not found: $SCRIPT"

# 2. Syntax check
bash -n "$SCRIPT" && test_pass "Syntax check passed" || test_fail "Syntax check failed"

# 3. Contains expected functions
for func in preflight_check_dns preflight_check_ntp preflight_check_ip_conflicts; do
	grep -q "^${func}()" "$SCRIPT" && test_pass "Contains function: $func" || test_fail "Missing function: $func"
done

# 4. Sources include_all.sh
grep -q 'source scripts/include_all.sh' "$SCRIPT" && test_pass "Sources scripts/include_all.sh" || test_fail "Does not source scripts/include_all.sh"

# 5. Uses tabs for indentation (not spaces)
# Match lines that start with one or more spaces but are NOT pure comment lines.
# The -P regex anchors at start-of-line: leading spaces followed by a non-# character.
# This correctly excludes lines like "  # comment" (space + # immediately) while still
# catching "  somevar=1" or "  if [..." (space-indented code).
if grep -Pn '^ +[^#]' "$SCRIPT" >/dev/null 2>&1; then
	test_fail "Uses spaces for indentation (should use tabs)"
else
	test_pass "Uses tabs for indentation"
fi

# 6. No $ABA_ROOT usage
if grep -q '^\s*[^#]*\$ABA_ROOT' "$SCRIPT" 2>/dev/null; then
	test_fail "Contains \$ABA_ROOT usage (should use relative paths)"
else
	test_pass "No \$ABA_ROOT usage (relative paths only)"
fi

# 7. Does not use $(<file 2>/dev/null) pattern (bash 5.1.8+ bug)
if grep -q '\$(<.*2>/dev/null)' "$SCRIPT" 2>/dev/null; then
	test_fail "Uses broken \$(<file 2>/dev/null) pattern"
else
	test_pass "No broken \$(<file 2>/dev/null) pattern"
fi

# 8. Script is executable
[ -x "$SCRIPT" ] && test_pass "Script is executable" || test_fail "Script is not executable"

# 9. Has extensibility hook for vSphere (IICCCN-55)
grep -q 'preflight-check-vsphere' "$SCRIPT" && test_pass "Has vSphere extensibility hook" || test_fail "Missing vSphere extensibility hook"

# 10. Uses shared counters for extensibility
grep -q '_preflight_warnings' "$SCRIPT" && grep -q '_preflight_errors' "$SCRIPT" && \
	test_pass "Uses shared warning/error counters" || test_fail "Missing shared counters"

# 11. Counters are initialised to zero at global scope (not just referenced)
grep -q '^_preflight_warnings=0' "$SCRIPT" && grep -q '^_preflight_errors=0' "$SCRIPT" && \
	test_pass "Counters initialised to zero at global scope" || test_fail "Counters not initialised to zero"

# 12. No trailing whitespace on any line (project coding standard)
if grep -Pn '\s+$' "$SCRIPT" >/dev/null 2>&1; then
	test_fail "Contains lines with trailing whitespace"
else
	test_pass "No trailing whitespace on any line"
fi

echo
echo -e "${GREEN}=== All Tests Passed ===${NC}"
echo
