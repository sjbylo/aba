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

result_out "OpenShift AI installation test: ok"
