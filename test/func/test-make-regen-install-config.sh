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
# Own HOME for the mirror-mode run: synthetic mirror credentials, so the mirror
# render path does not depend on the host having a registered mirror.
MIRROR_HOME=$(mktemp -d)

cleanup() {
	cd "$OLDPWD"
	rm -rf "$CLUSTER_DIR" "$MIRROR_HOME"
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

# Fixture mirror.conf, so mirror mode works on any checkout: without
# mirror/mirror.conf the cluster dir gets only an empty one (Makefile.cluster).
# A regular file also keeps installed registry state (state.sh) out of it.
rm -f mirror.conf
printf 'reg_host=registry.example.com\nreg_port=8443\nreg_path=/ocp4/openshift4\n' > mirror.conf

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

# direct mode: no mirror artifacts (no additionalTrustBundle, no imageDigestSources).
# [Ii]: older templates wrote ImageDigestSources; match both so the check cannot pass for nothing.
if grep -q "additionalTrustBundle\|[Ii]mageDigestSources\|imageContentSources" install-config.yaml; then
	test_fail "direct mode: should NOT have mirror artifacts"
else
	test_pass "direct mode: no mirror artifacts (correct)"
fi

# --- Test 2: Change to mirror mode, verify Make regenerates ---
sleep 1  # ensure filesystem timestamp advances
replace-value-conf -n image_source -v mirror -f cluster.conf

# Synthetic mirror pull secret for the fixture registry. Without a mirror pull
# secret create-install-config.sh uses the public one and writes no
# imageDigestSources. No rootCA.pem on purpose: without additionalTrustBundle
# create-install-config.sh skips verify-release-image.sh, which runs
# cli-install-all.sh (oc, openshift-install) and could start downloads.
_mirror_creds="$MIRROR_HOME/.aba/mirror/mirror"
mkdir -p "$_mirror_creds"
mkdir -m 700 "$MIRROR_HOME/run"
# ssh_key_file=~/.ssh/id_rsa expands under MIRROR_HOME; ssh-keygen cannot create a missing parent dir.
mkdir -m 700 "$MIRROR_HOME/.ssh"
printf '{"auths":{"registry.example.com:8443":{"auth":"%s"}}}\n' "$(printf init:dummy | base64)" > "$_mirror_creds/pull-secret-mirror.json"

if make -n install-config.yaml 2>&1 | grep -q 'cli-install-all'; then
	test_fail "mirror mode: make would install CLIs"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

# Do NOT manually rm install-config.yaml — Make should detect cluster.conf is newer
# RUN_ONCE_DIR set here: a value exported by the caller would move run_once tasks
# away from the dir checked below.
if ! HOME="$MIRROR_HOME" XDG_RUNTIME_DIR="$MIRROR_HOME/run" RUN_ONCE_DIR="$MIRROR_HOME/.aba/runner" make -s install-config.yaml; then
	test_fail "make install-config.yaml failed (mirror mode)"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

# run_once keeps every task (CLI download or install) under RUN_ONCE_DIR.
if [ -e "$MIRROR_HOME/.aba/runner" ]; then
	test_fail "mirror mode: a run_once task (CLI download or install) started"
else
	test_pass "mirror mode: no CLI download or install started"
fi

# mirror mode: must have additionalTrustBundle or imageDigestSources
if grep -q "additionalTrustBundle\|[Ii]mageDigestSources\|imageContentSources" install-config.yaml; then
	test_pass "mirror mode: has mirror artifacts (regenerated correctly)"
else
	test_fail "mirror mode: missing mirror artifacts — Make did NOT regenerate"
fi

# The install-config schema spells the key imageDigestSources.
if grep -q '^imageDigestSources:' install-config.yaml; then
	test_pass "mirror mode: key is spelled imageDigestSources"
else
	test_fail "mirror mode: no '^imageDigestSources:' key (old spelling ImageDigestSources?)"
fi

# --- Test 3: Change back to direct, confirm regeneration again ---
sleep 1
replace-value-conf -n image_source -v direct -f cluster.conf
if ! make -s install-config.yaml; then
	test_fail "make install-config.yaml failed (direct mode round 2)"
	echo -e "\n=== Results: $pass pass, $fail fail ==="
	exit 1
fi

if grep -q "additionalTrustBundle\|[Ii]mageDigestSources\|imageContentSources" install-config.yaml; then
	test_fail "direct mode (round 2): still has mirror artifacts — stale"
else
	test_pass "direct mode (round 2): no mirror artifacts (regenerated correctly)"
fi

echo
echo -e "=== Results: $pass pass, $fail fail ==="
[ "$fail" -gt 0 ] && exit 1
exit 0
