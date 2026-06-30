#!/bin/bash
# Test: Verify Make regenerates install-config.yaml when int_connection changes in cluster.conf.
# Proves Make's dependency chain handles connection mode switching without TUI intervention.

set -e

cd "$(dirname "$0")/../.."

source scripts/include_all.sh 1

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$((pass + 1)); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; fail=$((fail + 1)); }

CLUSTER_DIR="test-regen-$$"

cleanup() {
	cd "$OLDPWD"
	rm -rf "$CLUSTER_DIR"
	# Restore verify_conf
	if [ -n "$_orig_verify" ]; then
		replace-value-conf -q -n verify_conf -v "$_orig_verify" -f aba.conf
	else
		replace-value-conf -q -n verify_conf -v "" -f aba.conf
	fi
}
trap cleanup EXIT
OLDPWD="$PWD"

echo
echo "=== Test: Make regenerates install-config.yaml on int_connection change ==="
echo

# Skip network checks (DNS doesn't resolve for test cluster names)
_orig_verify=$(grep '^verify_conf=' "$PWD/aba.conf" 2>/dev/null | cut -d= -f2)
replace-value-conf -q -n verify_conf -v conf -f aba.conf

# Create a minimal cluster directory
aba cluster --name "$CLUSTER_DIR" --type sno -Y 2>/dev/null || true
cd "$CLUSTER_DIR"

# Ensure we have a clean state
rm -f install-config.yaml agent-config.yaml

# --- Test 1: Generate with int_connection=direct ---
replace-value-conf -n int_connection -v direct -f cluster.conf
make -s install-config.yaml 2>/dev/null

if [ ! -f install-config.yaml ]; then
	test_fail "install-config.yaml not generated (direct mode)"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

# direct mode: no mirror artifacts (no additionalTrustBundle, no ImageDigestSources)
if grep -q "additionalTrustBundle\|ImageDigestSources\|imageContentSources" install-config.yaml; then
	test_fail "direct mode: should NOT have mirror artifacts"
else
	test_pass "direct mode: no mirror artifacts (correct)"
fi

# --- Test 2: Change to mirror mode, verify Make regenerates ---
sleep 1  # ensure filesystem timestamp advances
replace-value-conf -n int_connection -v "" -f cluster.conf

# Do NOT manually rm install-config.yaml — Make should detect cluster.conf is newer
make -s install-config.yaml 2>/dev/null

# mirror mode: must have additionalTrustBundle or ImageDigestSources
if grep -q "additionalTrustBundle\|ImageDigestSources\|imageContentSources" install-config.yaml; then
	test_pass "mirror mode: has mirror artifacts (regenerated correctly)"
else
	test_fail "mirror mode: missing mirror artifacts — Make did NOT regenerate"
fi

# --- Test 3: Change back to direct, confirm regeneration again ---
sleep 1
replace-value-conf -n int_connection -v direct -f cluster.conf
make -s install-config.yaml 2>/dev/null

if grep -q "additionalTrustBundle\|ImageDigestSources\|imageContentSources" install-config.yaml; then
	test_fail "direct mode (round 2): still has mirror artifacts — stale"
else
	test_pass "direct mode (round 2): no mirror artifacts (regenerated correctly)"
fi

echo
echo -e "=== Results: $pass pass, $fail fail ==="
[ "$fail" -gt 0 ] && exit 1
exit 0
