#!/bin/bash -e
# Phase 06d: Install test cluster and run integration tests

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

cd "$WORK_TEST_INSTALL/aba"

echo_step "Be sure to delete the cached agent ISO, otherwise we may mistakenly use the cached ISO instead of a possibly bad one from the release payload!"
rm -rf ~/.cache/agent

if [ -d "$CLUSTER_NAME" ]; then
	echo_step "Deleting existing cluster from previous failed run ..."
	aba --dir "$CLUSTER_NAME" delete || true
fi

echo_step "Create the cluster ..."

# Build cluster command based on type
CLUSTER_CMD="aba cluster --name $CLUSTER_NAME --type $CLUSTER_TYPE --starting-ip $CLUSTER_STARTING_IP --mmem $CLUSTER_MEM --mcpu $CLUSTER_CPU --step install"
[ "$CLUSTER_API_VIP" ] && CLUSTER_CMD="$CLUSTER_CMD --api-vip $CLUSTER_API_VIP"
[ "$CLUSTER_INGRESS_VIP" ] && CLUSTER_CMD="$CLUSTER_CMD --ingress-vip $CLUSTER_INGRESS_VIP"

$CLUSTER_CMD

# Verify cluster was actually created
[ -f "$CLUSTER_NAME/iso-agent-based/auth/kubeconfig" ] || { echo "ERROR: Cluster install failed - no kubeconfig found!"; exit 1; }

TEST_LOG_06D="$WORK_BUNDLE_DIR_BUILD/tests-06d.txt"

# Truncate this phase's log (idempotent on retry)
: > "$TEST_LOG_06D"

# Test integrations
(
	cd "$CLUSTER_NAME"

	. <(aba shell)
	oc whoami
	. <(aba login)
	oc whoami

	aba day2-ntp
	aba day2

	echo_step "Test this cluster type: $NAME ..."

	echo "Cluster installation test: ok" >> "$TEST_LOG_06D"

	# OperatorHub + OSUS only make sense when operators are present
	if [ "$NAME" != "release" ]; then
		echo "Pausing 100s ..."
		mypause 100

		until oc get packagemanifests | grep cincinnati-operator; do echo -n .; mypause 10; done
		echo "OperatorHub integration test: ok" >> "$TEST_LOG_06D"

		mypause 10

		echo "List of packagemanifests:"
		oc get packagemanifests

		mypause 60

		aba day2-osus
		echo "OpenShift Update Service (OSUS) integration test: ok" >> "$TEST_LOG_06D"
	else
		echo "OperatorHub integration test: n/a" >> "$TEST_LOG_06D"
		echo "OpenShift Update Service (OSUS) integration test: n/a" >> "$TEST_LOG_06D"
	fi

	echo "Running specific tests for bundle type:"
	if [ -x "$TEMPLATES_DIR/${NAME}-test.sh" ]; then
		cp -p "$TEMPLATES_DIR/${NAME}-test.sh" "$WORK_BUNDLE_DIR_BUILD"
		timeout 1800 "$WORK_BUNDLE_DIR_BUILD/${NAME}-test.sh" 3>> "$TEST_LOG_06D"
	fi

	aba kill
	set +x
)

echo "All tests: passed" >> "$TEST_LOG_06D"
