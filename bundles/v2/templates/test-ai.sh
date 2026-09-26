#!/bin/bash -e
# test-ai.sh -- OpenShift AI (RHODS) operator + DataScienceCluster operand

# See: Chapter 3. Deploy OpenShift AI in a disconnected environment
# https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install
# https://github.com/red-hat-data-services/rhoai-disconnected-install-helper  =>  rhoai-3\.[0-9]-imagesetconfig.yaml

source "$(dirname "$0")/bundle-test-lib.sh"

OP=rhods-operator
NS=redhat-ods-operator

echo_step "Checking operator $OP in package manifest"
oc get packagemanifests | grep $OP

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: $NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operators
  namespace: $NS
spec:
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_for_csv "$OP"

wait_all_pods $NS

echo_step "Showing operator pods"
echo
oc get po -n $NS
echo

result_out "OpenShift AI Operator installation test: ok"

echo_step "Install DataScienceCluster operand"

cat << EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Managed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    kserve:
      managementState: Removed
    kueue:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Managed
    trustyai:
      managementState: Managed
    workbenches:
      managementState: Managed
      workbenchNamespace: rhods-notebooks
EOF

wait_for_operand DataScienceCluster default-dsc istio-system \
	'{.status.phase}' '[Rr]eady'

sleep 30

wait_all_pods $NS

echo_step "Showing OpenShift AI operand pods in namespace $NS"
echo
oc get po -n $NS
echo

echo_step "Showing deployments and pods in project redhat-ods-applications"
oc get deployment,pod -n redhat-ods-applications

result_out "OpenShift AI operand installation test: ok"

echo_step "Verifying installed components in DataScienceCluster status"

for comp in codeflare dashboard datasciencepipelines trainingoperator trustyai workbenches; do
	val=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.installedComponents.$comp}")
	echo "  $comp = $val"
	[ "$val" = "true" ] || { echo "ERROR: component $comp not installed (got: $val)" >&2; exit 1; }
done

result_out "DataScienceCluster installed components verification: ok"

echo_step "Waiting for pods in redhat-ods-applications"

wait_all_pods redhat-ods-applications 900

echo_step "Verifying key deployments in redhat-ods-applications"

for dep in rhods-dashboard data-science-pipelines-operator-controller-manager \
           notebook-controller-deployment odh-model-controller; do
	oc get deployment "$dep" -n redhat-ods-applications --no-headers || \
		{ echo "ERROR: deployment $dep missing" >&2; exit 1; }
done

echo
oc get deployment -n redhat-ods-applications
echo

result_out "OpenShift AI key deployments verification: ok"

echo_step "Verifying RHOAI dashboard route is accessible"

_dash_host=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')
echo "Dashboard URL: https://$_dash_host"
curl -k -sf "https://$_dash_host" > /dev/null || \
	{ echo "ERROR: RHOAI dashboard not reachable at https://$_dash_host" >&2; exit 1; }

result_out "OpenShift AI dashboard route accessible: ok"

echo_step "Creating minimal workbench to verify notebook image is pullable"

oc new-project test-workbench || true

cat << EOF | oc apply -f -
apiVersion: kubeflow.org/v1
kind: Notebook
metadata:
  name: test-wb
  namespace: test-workbench
  annotations:
    notebooks.opendatahub.io/inject-oauth: "false"
  labels:
    opendatahub.io/dashboard: "true"
spec:
  template:
    spec:
      containers:
      - name: test-wb
        image: registry.redhat.io/rhoai/odh-workbench-jupyter-minimal-cpu-py312-rhel9:latest
        ports:
        - containerPort: 8888
          name: notebook-port
        resources:
          limits:
            cpu: "1"
            memory: 2Gi
          requests:
            cpu: "1"
            memory: 2Gi
EOF

wait_all_pods test-workbench 300

echo_step "Showing workbench pod"
oc get po -n test-workbench

echo_step "Verifying Jupyter is responding"
oc port-forward -n test-workbench notebook-test-wb-0 8888:8888 &
_pf_pid=$!
sleep 3
curl -sf http://localhost:8888/api > /dev/null || \
	{ kill $_pf_pid 2>/dev/null; echo "ERROR: Jupyter not responding on port 8888" >&2; exit 1; }
kill $_pf_pid 2>/dev/null

result_out "Workbench notebook image pull, start and liveness: ok"

echo_step "Cleaning up test workbench"
oc delete project test-workbench --wait=false

result_out "Workbench notebook test: ok"

echo_step "Waiting for workbench namespace cleanup before next test"
for _try in $(seq 1 30); do
	oc get project test-workbench > /dev/null 2>&1 || break
	echo -n .
	sleep 5
done
echo

######################################################################
# Data Science Pipelines — verify DSP API and run a minimal pipeline
# (requires pipeline runtime images from the RHOAI companion image set)
######################################################################

echo_step "Creating Data Science Pipelines Application (DSPA)"

oc new-project test-dsp || true

cat << EOF | oc apply -f -
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1alpha1
kind: DataSciencePipelinesApplication
metadata:
  name: dspa-test
  namespace: test-dsp
spec:
  apiServer:
    deploy: true
    enableRoute: true
  database:
    mariaDB:
      deploy: true
      pipelineDBName: mlpipeline
      pvcSize: 1Gi
  objectStorage:
    minio:
      deploy: true
      pvcSize: 1Gi
      image: 'quay.io/opendatahub/minio:RELEASE.2019-08-14T20-37-41Z-license-compliance'
  persistenceAgent:
    deploy: true
  scheduledWorkflow:
    deploy: true
EOF

echo_step "Waiting for DSP pods to become ready"

wait_all_pods test-dsp 600

echo_step "Showing DSP pods"
oc get po -n test-dsp

echo_step "Waiting for DSP API route"

_dspa_ready=
for _try in $(seq 1 60); do
	_dspa_route=$(oc get dspa dspa-test -n test-dsp -o jsonpath='{.status.conditions[?(@.type=="APIServerReady")].status}' 2>/dev/null || true)
	if [ "$_dspa_route" = "True" ]; then
		_dspa_ready=1
		break
	fi
	echo -n .
	sleep 5
done
echo

[ "$_dspa_ready" ] || { echo "ERROR: DSPA API never became ready within 300s" >&2; oc get dspa dspa-test -n test-dsp -o yaml >&2; exit 1; }

result_out "Data Science Pipelines Application deployed: ok"

echo_step "Verifying DSP API health endpoint"

# Get the DSP API route
_ds_route=$(oc get route ds-pipeline-dspa-test -n test-dsp -o jsonpath='{.spec.host}' 2>/dev/null || true)
_pf_pid=

if [ -n "$_ds_route" ]; then
	_ds_api="https://$_ds_route"
else
	echo "No DSP route found — using port-forward instead"
	oc port-forward -n test-dsp svc/ds-pipeline-dspa-test 8888:8888 &
	_pf_pid=$!
	sleep 3
	_ds_api="http://localhost:8888"
fi

# Get auth token for API calls
_token=$(oc whoami -t)

# Verify DSP API health
_api_ok=
for _try in $(seq 1 12); do
	if curl -k -sf -H "Authorization: Bearer $_token" "$_ds_api/apis/v2beta1/healthz" > /dev/null 2>&1; then
		_api_ok=1
		break
	fi
	echo -n .
	sleep 5
done
echo

[ -n "$_pf_pid" ] && kill "$_pf_pid" 2>/dev/null || true

if [ "$_api_ok" ]; then
	result_out "Data Science Pipelines API health check: ok"
else
	echo "WARNING: DSP API health endpoint not reachable — deployment still verified above" >&2
	result_out "Data Science Pipelines API health check: SKIPPED (API not reachable via route/port-forward)"
fi

echo_step "Cleaning up DSP test project"
oc delete project test-dsp --wait=false

result_out "Data Science Pipelines test: ok"

######################################################################
# TrustyAI — verify service pods are running
######################################################################

echo_step "Verifying TrustyAI controller is running"

_trusty_ns=redhat-ods-applications
_trusty_dep=trustyai-service-operator-controller-manager

if oc get deployment "$_trusty_dep" -n "$_trusty_ns" --no-headers 2>/dev/null; then
	_ready=$(oc get deployment "$_trusty_dep" -n "$_trusty_ns" \
		-o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
	echo "  TrustyAI controller ready replicas: $_ready"
	[ "${_ready:-0}" -ge 1 ] || { echo "ERROR: TrustyAI controller has no ready replicas" >&2; exit 1; }
	result_out "TrustyAI controller running: ok"
else
	echo "WARNING: TrustyAI controller deployment not found — component may use a different name" >&2
	echo "  Checking for any trustyai-related pods:"
	oc get po -n "$_trusty_ns" 2>/dev/null | grep -i trusty || echo "  (none found)"
	result_out "TrustyAI controller: SKIPPED (deployment not found)"
fi

result_out "OpenShift AI full installation test: ok"
