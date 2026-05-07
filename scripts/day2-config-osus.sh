#!/bin/bash -e

source scripts/include_all.sh

aba_debug "Starting: $0 $*"



umask 077

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$mirror_name
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc

# Stop processing (CatalogSources and Signatires etc) if this cluster is a connected cluster!
if [ "$int_connection" ]; then
	aba_info "Your cluster is a 'connected cluster' since the value 'int_connection' is set to '$int_connection' in $PWD/cluster.conf"
	aba_info "There is nothing for 'aba day2-osus' to do and there is no need to run: aba day2 also!"

	exit 0
fi

NAME=osus
NAMESPACE=openshift-update-service

#####################
# Debug log for post-mortem analysis of OSUS subscription failures.
# Captures MCP, node, catalog, and subscription state on every poll iteration
# so we have a full timeline if something goes wrong.
_OSUS_LOG="$HOME/.aba/logs/.day2-osus.log"
mkdir -p "$(dirname "$_OSUS_LOG")"
: > "$_OSUS_LOG"
aba_info "OSUS debug log: $_OSUS_LOG"

# Logs cluster state to the debug file. Called every poll iteration for a full timeline.
_osus_log() {
	{
		echo "--- $(date) ---"
		echo "MCP status:"
		oc get mcp
		echo "Node status:"
		oc get nodes
		echo "CatalogSource status:"
		oc get catalogsource -n openshift-marketplace
		echo "Subscription status:"
		oc get sub -n $NAMESPACE update-service-subscription -o yaml || echo "(not found)"
		echo "Failed jobs in openshift-marketplace:"
		oc get jobs -n openshift-marketplace --field-selector=status.successful=0 || echo "(none)"
		echo ""
	} >> "$_OSUS_LOG" 2>&1
}

# Deletes the OSUS subscription, CSV, and any failed OLM unpack jobs so we can start fresh.
# OLM does not auto-retry after a failed unpack job -- the job must be deleted first.
# A stale CSV (non-Succeeded) can block OLM from reconciling a fresh subscription.
_osus_cleanup_sub() {
	oc delete sub update-service-subscription -n $NAMESPACE 2>&1 || true
	oc delete csv --all -n $NAMESPACE 2>&1 || true
	oc delete jobs --field-selector=status.successful=0 -n openshift-marketplace 2>&1 || true
}

# Creates the OSUS namespace, operatorgroup, and subscription.
_osus_apply_sub() {
	oc apply -f - <<END
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: update-service-subscription
  namespace: $NAMESPACE
spec:
  channel: v1
  installPlanApproval: "Automatic"
  source: "redhat-operators"
  sourceNamespace: "openshift-marketplace"
  name: "cincinnati-operator"
END
}

# Check functions for aba_wait_show -- each runs _osus_log for the debug
# timeline, then tests the condition.
_osus_check_csv_exists() {
	_osus_log
	local csv
	csv=$(oc get subscription -n $NAMESPACE update-service-subscription \
		-o jsonpath='{.status.installedCSV}' 2>/dev/null) || true
	[ "$csv" ]
}

_osus_check_csv_succeeded() {
	_osus_log
	oc get csv -n $NAMESPACE "$CSV" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Succeeded
}

# Waits up to ~10 minutes for the subscription to produce an installed CSV
# with phase Succeeded. Logs cluster state to $_OSUS_LOG on every iteration.
# Returns 0 on success, 1 on timeout.
_osus_wait_for_csv() {
	# Phase 1: wait for installedCSV to appear (up to 10 min)
	if ! aba_wait_show "Waiting for OSUS subscription" 10 600 _osus_check_csv_exists; then
		return 1
	fi

	# Re-read CSV name (aba_wait_show runs in a subshell, so side effects are lost)
	CSV=$(oc get subscription -n $NAMESPACE update-service-subscription \
		-o jsonpath='{.status.installedCSV}')

	# Phase 2: wait for CSV phase Succeeded (up to 10 min)
	if ! aba_wait_show "Waiting for CSV $CSV phase Succeeded" 10 600 _osus_check_csv_succeeded; then
		return 1
	fi

	return 0
}

#####################
aba_info "Accessing the cluster ..."

[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!
! oc whoami && aba_abort "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

warn_if_cluster_unstable

#####################
if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
	if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
		aba_abort \
			"cincinnati-operator not available in OperatorHub for this cluster." \
			"The CatalogSource may still be synchronizing -- wait a few minutes and try again:" \
			"  oc get catalogsource -n openshift-marketplace" \
			"  oc get packagemanifests | grep cincinnati" \
			"If the operator is not loaded, run: aba day2"
	fi
fi

#####################
aba_info -n "Adding cluster ingress CA cert to the CA trust bundle ... "

ingress_cert="$(oc get secret -n openshift-ingress-operator router-ca -o jsonpath="{.data['tls\.crt']}"| base64 -d)"
echo "$ingress_cert" > .openshift-ingress.cacert.pem
ingress_cert_json="$(echo "$ingress_cert" | sed ':a;N;$!ba;s/\n/\\n/g')"   # Replace all new-lines with '\n'
ca_bundle_crt=$(oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' | sed ':a;N;$!ba;s/\n/\\n/g')

# Check if cert already added. 
# If these two lines already exist then it's safe to assume the cert is already in the bundle!
tmp_line8=$(echo "$ingress_cert" | head -8 | tail -1)
tmp_line12=$(echo "$ingress_cert" | head -12 | tail -1)

if echo "$ca_bundle_crt" | grep -q "$tmp_line8" && echo "$ca_bundle_crt" | grep -q "$tmp_line12"; then
	echo_white "CA cert already added"
else
	ca_bundle_crt="$ca_bundle_crt\n$ingress_cert_json"
	oc patch cm user-ca-bundle -n openshift-config --type='merge' -p '{"data":{"ca-bundle.crt":"'"$ca_bundle_crt"'"}}'
	echo_green "CA cert added"
fi

aba_info Adding trustedCA to cluster proxy ...
oc patch proxy cluster --type=merge -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'

#####################
aba_info "Adding mirror registry CA cert to registry config ..."

if [ -s "$regcreds_dir/rootCA.pem" ]; then
        ca_cert="$(cat "$regcreds_dir/rootCA.pem" | sed ':a;N;$!ba;s/\n/\\n/g')"
        aba_info "Using root CA file at $regcreds_dir/rootCA.pem"
	kubectl patch configmap registry-config -n openshift-config --type='merge' -p '{"data":{"updateservice-registry":"'"$ca_cert"'"}}'
else
	aba_abort "No root CA file found at $regcreds_dir/rootCA.pem.  Is the mirror registry available?"
fi

#####################
# Pre-flight: if the OSUS operator is already installed and healthy, skip to deployment.
# If the subscription exists but is not healthy/complete (previous failed attempt, stuck,
# etc.), clean up so we can start fresh. This makes the script safely re-runnable.
_osus_installed=
_existing_csv=$(oc get sub update-service-subscription -n $NAMESPACE -o jsonpath='{.status.installedCSV}' || true)
if [ "$_existing_csv" ]; then
	_csv_phase=$(oc get csv "$_existing_csv" -n $NAMESPACE -o jsonpath='{.status.phase}' || true)
	if [ "$_csv_phase" = "Succeeded" ]; then
		aba_info "OSUS operator already installed ($_existing_csv) -- skipping to deployment"
		_osus_installed=1
	else
		aba_info "OSUS subscription not healthy/complete (CSV=$_existing_csv, phase=$_csv_phase) -- cleaning up"
		_osus_log
		_osus_cleanup_sub
	fi
elif oc get sub update-service-subscription -n $NAMESPACE >/dev/null 2>&1; then
	# Subscription exists but has no installedCSV at all (stuck/failed)
	aba_info "OSUS subscription exists but has no installedCSV -- cleaning up"
	_osus_log
	_osus_cleanup_sub
fi

#####################
if [ -z "$_osus_installed" ]; then
	aba_info "Provisioning OpenShift Update Service Operator ..."
	_osus_log
	_osus_apply_sub

	if ! _osus_wait_for_csv; then
		echo_yellow "[ABA] OSUS operator subscription did not complete in time. Retrying ... Hit Ctrl-C to stop."
		_osus_log
		_osus_cleanup_sub
		sleep 30
		_osus_apply_sub

		_osus_log

		if ! _osus_wait_for_csv; then
			_osus_log
			aba_abort "Timed out waiting for OSUS operator (retry exhausted)." \
				"See $_OSUS_LOG for cluster state during the wait."
		fi
	fi
fi

#####################
aba_info "Deploying OpenShift Update Service ..."

graph_image=$reg_host:$reg_port$reg_path/openshift/graph-image:latest
release_repo=$reg_host:$reg_port$reg_path/openshift/release-images

aba_debug graph_image=$graph_image
aba_debug release_repo=$release_repo

oc apply -f - <<END
apiVersion: updateservice.operator.openshift.io/v1
kind: UpdateService
metadata:
  name: $NAME
  namespace: $NAMESPACE
spec:
  graphDataImage: "$graph_image"
  releases: "$release_repo"
  replicas: 1
END

#####################
_osus_check_policy_engine_uri() {
	local uri scheme
	uri=$(oc -n "${NAMESPACE}" get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph' updateservice "${NAME}" 2>/dev/null) || return 1
	scheme="${uri%%:*}"
	test "$scheme" = http -o "$scheme" = https
}

if ! aba_wait_show "Obtaining the policy engine route" 2 900 _osus_check_policy_engine_uri; then
	aba_abort "Timed out waiting for the policy engine route (15 min)."
fi

POLICY_ENGINE_GRAPH_URI="$(oc -n "${NAMESPACE}" get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph' updateservice "${NAME}")"
aba_info_ok "Policy engine: $POLICY_ENGINE_GRAPH_URI"

CH=$(kubectl get clusterversion version -o jsonpath='{.spec.channel}')
aba_debug CH=$CH

_osus_check_graph_available() {
	local http_code
	http_code=$(curl --cacert .openshift-ingress.cacert.pem --header Accept:application/json \
		-s --connect-timeout 10 --output /dev/null --write-out "%{http_code}" \
		"${POLICY_ENGINE_GRAPH_URI}?channel=$CH") || return 1
	test "$http_code" -eq 200
}

if ! aba_wait_show "Checking graph endpoint (Ctrl-C to skip)" 10 900 _osus_check_graph_available; then
	aba_abort "Timed out waiting for graph endpoint (15 min): ${POLICY_ENGINE_GRAPH_URI}?channel=$CH"
fi
aba_info_ok "Graph endpoint available"

#####################
aba_info "Updating cluster version with $POLICY_ENGINE_GRAPH_URI ..."

PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"
oc patch clusterversion version -p $PATCH --type merge

aba_info_ok "Update Service configuration completed successfully!"
aba_info "Please wait about *10 MINUTES* for the OpenShift Console to show the 'Update Graph' under 'Administration -> Cluster Settings' ..."
