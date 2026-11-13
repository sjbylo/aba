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

# Skip release-image probe (local mirror may not hold current ocp_version).
# verify_conf=off skips connectivity check in verify-release-image.sh; empty does not.
_orig_verify=$(grep '^verify_conf=' "$PWD/aba.conf" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')
replace-value-conf -q -n verify_conf -v off -f aba.conf

# Create a minimal cluster directory
if ! aba cluster --name "$CLUSTER_DIR" --type sno -Y 2>/dev/null; then
	test_fail "aba cluster failed to create $CLUSTER_DIR"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi
cd "$CLUSTER_DIR" || {
	test_fail "cluster dir $CLUSTER_DIR missing after aba cluster"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
}

# Ensure network fields are consistent (cross-validation catches mismatches)
replace-value-conf -q -n machine_network -v 10.0.1.0 -f cluster.conf
replace-value-conf -q -n prefix_length -v 24 -f cluster.conf
replace-value-conf -q -n next_hop_address -v 10.0.1.1 -f cluster.conf
replace-value-conf -q -n starting_ip -v 10.0.1.10 -f cluster.conf
replace-value-conf -q -n dns_servers -v 10.0.1.1 -f cluster.conf

# Ensure we have a clean state
rm -f install-config.yaml agent-config.yaml

# --- Test 1: Generate with image_source=direct ---
replace-value-conf -n image_source -v direct -f cluster.conf
if ! make -s install-config.yaml; then
	test_fail "make install-config.yaml failed (direct mode)"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

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
replace-value-conf -n image_source -v mirror -f cluster.conf

# verify-release-image.sh requires an executable ~/bin/openshift-install
# before it will use the mirror stub below. cli-install-all --wait trusts a
# finished run_once record and will not replace a missing or empty file.
if ! "$HOME/bin/openshift-install" version >/dev/null 2>&1; then
	rm -f "$HOME/bin/openshift-install"
	run_once -r -i "cli:install:openshift-install" 2>/dev/null || true
	if ! make -C ../cli openshift-install; then
		test_fail "could not install ~/bin/openshift-install for mirror mode"
		echo -e "\n=== Results: $pass pass, $fail fail ==="
		exit 1
	fi
fi

# Mirror install-config runs verify-release-image.sh, which extracts
# openshift-install from the registry. Stub that binary so the test does
# not require the current aba.conf ocp_version to be loaded in the mirror.
_reg_host=$(grep '^reg_host=' ../mirror/mirror.conf 2>/dev/null | cut -d= -f2 | awk '{print $1}')
_reg_port=$(grep '^reg_port=' ../mirror/mirror.conf 2>/dev/null | cut -d= -f2 | awk '{print $1}')
_ocp_ver=$(grep '^ocp_version=' ../aba.conf 2>/dev/null | cut -d= -f2 | awk '{print $1}')
if [ -n "$_reg_host" ] && [ -n "$_reg_port" ] && [ -n "$_ocp_ver" ]; then
	_stub="./openshift-install-mirror-${_ocp_ver}-${_reg_host}-${_reg_port}"
	touch "$_stub" && chmod +x "$_stub"
fi

# Do NOT manually rm install-config.yaml — Make should detect cluster.conf is newer
if ! make -s install-config.yaml; then
	test_fail "make install-config.yaml failed (mirror mode)"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

# mirror mode: must have additionalTrustBundle or ImageDigestSources
if grep -q "additionalTrustBundle\|ImageDigestSources\|imageContentSources" install-config.yaml; then
	test_pass "mirror mode: has mirror artifacts (regenerated correctly)"
else
	test_fail "mirror mode: missing mirror artifacts — Make did NOT regenerate"
fi

# --- Test 3: Change back to direct, confirm regeneration again ---
sleep 1
replace-value-conf -n image_source -v direct -f cluster.conf
if ! make -s install-config.yaml; then
	test_fail "make install-config.yaml failed (direct mode round 2)"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

if grep -q "additionalTrustBundle\|ImageDigestSources\|imageContentSources" install-config.yaml; then
	test_fail "direct mode (round 2): still has mirror artifacts — stale"
else
	test_pass "direct mode (round 2): no mirror artifacts (regenerated correctly)"
fi

echo
echo -e "=== Results: $pass pass, $fail fail ==="
[ "$fail" -gt 0 ] && exit 1
exit 0
