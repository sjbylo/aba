#!/bin/bash -e
# Phase 06d: Install test cluster and run integration tests

set -x

source "$(cd "$(dirname "$0")/.." && pwd)/common.sh"

# Ensure internet is down for disconnected testing. On re-runs, go.sh puts
# internet UP to fetch OCP versions, and Make skips step 05 (already done),
# so the internet would stay UP without this guard.
int_down

cd "$WORK_TEST_INSTALL/aba"

echo_step "Be sure to delete the cached agent ISO, otherwise we may mistakenly use the cached ISO instead of a possibly bad one from the release payload!"
rm -rf ~/.cache/agent

# Guard: aba and govc must be in PATH before any VM operations.
# A previous go.sh bug deleted ~/bin/* which caused silent delete failures.
for _tool in aba govc; do
	command -v "$_tool" >/dev/null 2>&1 || { echo "ERROR: $_tool not found in PATH! Cannot manage VMs safely." >&2; exit 1; }
done

_cluster_healthy=
if [ -d "$CLUSTER_NAME" ] && [ -f "$CLUSTER_NAME/iso-agent-based/auth/kubeconfig" ]; then
	export KUBECONFIG="$CLUSTER_NAME/iso-agent-based/auth/kubeconfig"
	echo_step "Checking if existing cluster is healthy and correct version ($VER) ..."
	_actual_ver=""
	if _actual_ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null); then
		if [ "$_actual_ver" != "$VER" ]; then
			echo_step "Cluster version mismatch (want $VER, got $_actual_ver) -- deleting and recreating"
			aba --dir "$CLUSTER_NAME" delete
		else
			_cv_available=$(oc get clusterversion version \
				-o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
			if [ "$_cv_available" = "True" ]; then
				echo_step "Cluster is healthy at version $_actual_ver (Available=True) -- reusing for tests"
				_cluster_healthy=1
			else
				echo "ERROR: Cluster is version $_actual_ver but ClusterVersion Available=$_cv_available (not True)." >&2
				echo "The cluster may still be installing. Wait for it to finish, then re-run." >&2
				oc get clusterversion >&2
				exit 1
			fi
		fi
	else
		echo_step "Cluster unreachable -- deleting and recreating"
		aba --dir "$CLUSTER_NAME" delete || true
	fi
	unset KUBECONFIG
elif [ -d "$CLUSTER_NAME" ]; then
	echo_step "Cluster dir exists but no kubeconfig -- deleting stale cluster"
	aba --dir "$CLUSTER_NAME" delete || true
fi

if [ -z "$_cluster_healthy" ]; then
	echo_step "Create the cluster ..."

	# Build cluster command based on type
	CLUSTER_CMD="aba cluster --name $CLUSTER_NAME --type $CLUSTER_TYPE --starting-ip $CLUSTER_STARTING_IP --mmem $CLUSTER_MEM --mcpu $CLUSTER_CPU --step install"
	[ "$CLUSTER_API_VIP" ] && CLUSTER_CMD="$CLUSTER_CMD --api-vip $CLUSTER_API_VIP"
	[ "$CLUSTER_INGRESS_VIP" ] && CLUSTER_CMD="$CLUSTER_CMD --ingress-vip $CLUSTER_INGRESS_VIP"

	$CLUSTER_CMD

	# Verify cluster was actually created
	[ -f "$CLUSTER_NAME/iso-agent-based/auth/kubeconfig" ] || { echo "ERROR: Cluster install failed - no kubeconfig found!"; exit 1; }
fi

TEST_LOG_06D="$WORK_BUNDLE_DIR_BUILD/tests-06d.txt"

# Truncate this phase's log (idempotent on retry)
: > "$TEST_LOG_06D"

# Run tests, then ALWAYS delete cluster VMs -- pass or fail.
# All bundles share the same cluster name/IPs, so leaving VMs behind
# would cause IP conflicts for the next bundle.
_test_rc=0
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

	# Run modular test scripts from bundles/v2/templates/
	V2_TEMPLATES="$V2_DIR/templates"

	cp -p "$V2_TEMPLATES/bundle-test-lib.sh" "$WORK_BUNDLE_DIR_BUILD/"

	echo "Running operator integration tests: ${TESTS:-none}"
	for test_module in $TESTS; do
		test_script="$V2_TEMPLATES/test-${test_module}.sh"
		if [ -x "$test_script" ]; then
			echo_step "Running test module: test-${test_module}.sh"
			cp -p "$test_script" "$WORK_BUNDLE_DIR_BUILD/"
			timeout 1800 "$WORK_BUNDLE_DIR_BUILD/test-${test_module}.sh" 3>> "$TEST_LOG_06D"
		else
			echo "WARNING: No test module for '$test_module' at $test_script -- skipping" >&2
		fi
	done

	set +x
) || _test_rc=$?

# Always delete the test cluster VMs -- they are no longer needed.
echo_step "Delete test cluster VMs ..."
aba --dir "$CLUSTER_NAME" delete || true

[ $_test_rc -ne 0 ] && exit $_test_rc

echo "All tests: passed" >> "$TEST_LOG_06D"
