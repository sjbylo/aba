#!/bin/bash -e
# test-ocp.sh -- Web Terminal operator + operand verification

source "$(dirname "$0")/bundle-test-lib.sh"

OP=web-terminal
NS=openshift-operators

echo_step "Checking operator $OP in package manifest"
oc get packagemanifests | grep $OP

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: web-terminal
  namespace: $NS
spec:
  name: web-terminal
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_for_csv "$OP"

wait_all_pods $NS

echo_step "Showing operator pods"
echo
oc get po -n $NS
echo

result_out "Web Terminal Operator installation test: ok"

echo_step "Verifying DevWorkspace CRD exists (operand readiness)"
oc get crd devworkspaces.workspace.devfile.io

result_out "Web Terminal operand verification test: ok"
