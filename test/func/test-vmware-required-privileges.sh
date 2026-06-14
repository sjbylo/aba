#!/bin/bash
# Test: Verify scripts/vmware-required-privileges.sh structure and contents.
# Unit test (fast, static + in-subshell source; no network).

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }

PRIVS="scripts/vmware-required-privileges.sh"

echo
echo "=== Testing: $PRIVS ==="
echo

# 1. File exists
[ -f "$PRIVS" ] && test_pass "File exists" || test_fail "File not found: $PRIVS"

# 2. NOT executable (sourced data file)
if [ -x "$PRIVS" ]; then
	test_fail "Sourced data file must not be executable"
else
	test_pass "Not executable (sourced data file)"
fi

# 3. NO shebang as first line
first_line=$(head -1 "$PRIVS")
case "$first_line" in
	'#!'*) test_fail "Sourced data file must not have a shebang (got: $first_line)" ;;
	*) test_pass "No shebang (sourced data file)" ;;
esac

# 4. Header references the OpenShift docs canonical URL (PRIV-03, D-05)
if grep -q 'github.com/openshift/installer/blob/main/docs/user/vsphere/privileges.md' "$PRIVS"; then
	test_pass "Header links to upstream OpenShift docs"
else
	test_fail "Header missing upstream OpenShift docs URL"
fi

# 5. TABS for indentation (project standard)
if grep -Pn '^ +[^#]' "$PRIVS" >/dev/null; then
	test_fail "Uses spaces for indentation (should use tabs)"
else
	test_pass "Uses tabs for indentation"
fi

# 6. No trailing whitespace
if grep -Pn '\s+$' "$PRIVS" >/dev/null; then
	test_fail "Contains lines with trailing whitespace"
else
	test_pass "No trailing whitespace on any line"
fi

# 7. No internal-ticket tokens in the shipped code (DOC-03)
# Matches JIRA-style IDs: 4-7 uppercase letters, a dash, and digits (e.g. PROJ-123)
if grep -Eq '\b[A-Z]{4,7}-[0-9]+\b' "$PRIVS"; then
	test_fail "Contains internal-ticket reference (matched [A-Z]{4,7}-[0-9]+)"
else
	test_pass "No internal-ticket references"
fi

# 8. Syntax check via sourcing in a pristine subshell
if bash -c "source $PRIVS"; then
	test_pass "Sources cleanly in a subshell"
else
	test_fail "Failed to source cleanly"
fi

# 9. All seven VSPHERE_PRIVS_* arrays are declared (D-04)
for arr in VSPHERE_PRIVS_ROOT VSPHERE_PRIVS_DATACENTER VSPHERE_PRIVS_CLUSTER \
		VSPHERE_PRIVS_DATASTORE VSPHERE_PRIVS_NETWORK VSPHERE_PRIVS_FOLDER \
		VSPHERE_PRIVS_RESOURCE_POOL; do
	if grep -q "^${arr}=" "$PRIVS"; then
		test_pass "Declares array: $arr"
	else
		test_fail "Missing array declaration: $arr"
	fi
done

# 10. Array counts match the upstream list (RESEARCH.md R1)
# Source in a subshell so we don't leak into this script's scope,
# then query ${#NAME[@]} for each array.
counts=$(bash -c "source $PRIVS; \
	printf '%s\n' \
	\"ROOT=\${#VSPHERE_PRIVS_ROOT[@]}\" \
	\"DATACENTER=\${#VSPHERE_PRIVS_DATACENTER[@]}\" \
	\"CLUSTER=\${#VSPHERE_PRIVS_CLUSTER[@]}\" \
	\"DATASTORE=\${#VSPHERE_PRIVS_DATASTORE[@]}\" \
	\"NETWORK=\${#VSPHERE_PRIVS_NETWORK[@]}\" \
	\"FOLDER=\${#VSPHERE_PRIVS_FOLDER[@]}\" \
	\"RESOURCE_POOL=\${#VSPHERE_PRIVS_RESOURCE_POOL[@]}\"")

check_count() {
	local name="$1" want="$2"
	local line got
	line=$(echo "$counts" | grep "^${name}=")
	got="${line#*=}"
	if [ "$got" = "$want" ]; then
		test_pass "VSPHERE_PRIVS_${name} has $want elements"
	else
		test_fail "VSPHERE_PRIVS_${name}: expected $want, got $got"
	fi
}

check_count ROOT           11
check_count DATACENTER     30
check_count CLUSTER         5
check_count DATASTORE       3
check_count NETWORK         1
check_count FOLDER         28
check_count RESOURCE_POOL   5

# 11. Specific privilege strings are present (spot-check against upstream)
for priv in \
		'Cns.Searchable' \
		'Sessions.ValidateSession' \
		'Datastore.AllocateSpace' \
		'Datastore.Browse' \
		'Datastore.FileManagement' \
		'Network.Assign' \
		'Folder.Create' \
		'Folder.Delete' \
		'VirtualMachine.Inventory.Create' \
		'VirtualMachine.Provisioning.Clone'; do
	if grep -qF "$priv" "$PRIVS"; then
		test_pass "Contains privilege: $priv"
	else
		test_fail "Missing privilege: $priv"
	fi
done

echo
echo -e "${GREEN}=== All Tests Passed ===${NC}"
echo
