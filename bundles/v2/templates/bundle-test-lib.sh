#!/bin/bash
# bundle-test-lib.sh -- shared functions for modular bundle test scripts
# Sourced by each test-*.sh module. Must NOT be executed directly.

set -e

# Ensure cluster login
oc whoami || . <(aba login)

# Open fd 3 for structured test-result output (used by the 06d harness).
# The fd check is the ONLY place 2>/dev/null is acceptable -- it tests
# whether fd 3 was pre-opened by the caller.
{ true >&3; } 2>/dev/null || exec 3>&1

echo_step() {
	echo
	echo "###########################################################"
	echo "$@"
	echo "###########################################################"
	echo
}

result_out() {
	echo_step "$@"
	echo "$@" >&3
}

# Wait for a CSV name-prefix to reach "Succeeded" phase.
# Usage: wait_for_csv <csv-prefix> [timeout_s]
wait_for_csv() {
	local csv_prefix="$1"
	local timeout_s="${2:-600}"
	local start_s elapsed_s

	echo_step "Waiting for CSV $csv_prefix to succeed (timeout ${timeout_s}s)"
	start_s=$(date +%s)

	until oc get csv -A | grep "$csv_prefix.*Succeeded"; do
		sleep 5
		echo -n .
		elapsed_s=$(( $(date +%s) - start_s ))
		if [ "$elapsed_s" -gt "$timeout_s" ]; then
			echo
			echo "ERROR: CSV $csv_prefix did not reach Succeeded within ${timeout_s}s" >&2
			oc get csv -A >&2
			exit 1
		fi
	done
}

# Wait until every pod in a namespace is ready (or Completed).
# stderr is NOT suppressed -- auth failures and missing namespaces surface immediately.
# Usage: wait_all_pods <namespace> [timeout_s]
wait_all_pods() {
	local ns="$1"
	local timeout_s="${2:-600}"
	local start_s elapsed_s list

	echo "Waiting for all pods to become ready in namespace $ns ..."
	start_s=$(date +%s)

	list=$(oc get po --no-headers -n "$ns" \
		| awk '{split($2,a,"/"); if (a[1]!=a[2] && $3!="Completed") print}')
	until [ -z "$list" ]; do
		sleep 10
		elapsed_s=$(( $(date +%s) - start_s ))
		if [ "$elapsed_s" -gt "$timeout_s" ]; then
			echo
			echo "ERROR: pods in $ns not all ready within ${timeout_s}s" >&2
			oc get po -n "$ns" >&2
			exit 1
		fi
		list=$(oc get po --no-headers -n "$ns" \
			| awk '{split($2,a,"/"); if (a[1]!=a[2] && $3!="Completed") print}')
	done
	echo "All pods ready in namespace $ns"
}

# Generic operand status wait.
# Usage: wait_for_operand <kind> <name> <namespace> <jsonpath> <grep-pattern> [timeout_s]
# Example: wait_for_operand HyperConverged kubevirt-hyperconverged openshift-cnv \
#              '{.status.systemHealthStatus}' '^healthy$'
wait_for_operand() {
	local kind="$1" name="$2" ns="$3" field="$4" pattern="$5"
	local timeout_s="${6:-600}"
	local start_s elapsed_s

	echo_step "Waiting for $kind/$name in $ns (pattern: $pattern, timeout ${timeout_s}s)"
	start_s=$(date +%s)

	until oc get "$kind" "$name" -n "$ns" -o "jsonpath=$field" | grep -q "$pattern"; do
		sleep 5
		echo -n .
		elapsed_s=$(( $(date +%s) - start_s ))
		if [ "$elapsed_s" -gt "$timeout_s" ]; then
			echo
			echo "ERROR: $kind/$name in $ns did not match '$pattern' within ${timeout_s}s" >&2
			oc get "$kind" "$name" -n "$ns" -o yaml >&2
			exit 1
		fi
	done
	echo
}
