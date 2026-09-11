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
result_out "OpenShift AI installation test: ok"
