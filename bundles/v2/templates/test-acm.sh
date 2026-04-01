#!/bin/bash -e
# test-acm.sh -- Advanced Cluster Management operator + MultiClusterHub operand

source "$(dirname "$0")/bundle-test-lib.sh"

NS=open-cluster-management

echo_step "Checking operator advanced-cluster-management in package manifest"
oc get packagemanifests | grep advanced-cluster-management

cat << EOF | oc apply -f -
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: $NS
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm-operator-group
  namespace: $NS
spec:
  targetNamespaces:
  - $NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: $NS
spec:
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_for_csv "advanced-cluster-management"

result_out "ACM Operator installation test: ok"

echo_step "Install MultiClusterHub operand"

cat << EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  annotations:
    installer.open-cluster-management.io/mce-subscription-spec: '{"source": "redhat-operators"}'
  name: multiclusterhub
  namespace: $NS
spec:
  availabilityConfig: Basic
EOF

wait_for_operand MultiClusterHub multiclusterhub $NS \
	'{.status.phase}' '[Rr]unning' 600

wait_all_pods $NS

echo_step "Showing ACM pods"
echo
oc get po -n $NS
echo

result_out "ACM MultiClusterHub installation test: ok"
