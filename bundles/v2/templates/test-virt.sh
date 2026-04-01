#!/bin/bash -e
# test-virt.sh -- OCP Virtualization operator + HyperConverged operand

source "$(dirname "$0")/bundle-test-lib.sh"

NS=openshift-cnv

echo_step "Checking operator kubevirt-hyperconverged in package manifest"
oc get packagemanifests | grep kubevirt-hyperconverged

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: $NS
spec:
  targetNamespaces:
    - $NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: $NS
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: "stable"
EOF

wait_for_csv "kubevirt-hyperconverged"

result_out "OpenShift Virt Operator installation test: ok"

echo_step "Install OCP-V operand (HyperConverged)"

cat << EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: $NS
spec:
EOF

wait_for_operand HyperConverged kubevirt-hyperconverged $NS \
	'{.status.systemHealthStatus}' '^healthy$'

wait_all_pods $NS

echo_step "Showing OCP-V pods"
echo
oc get po -n $NS
echo

result_out "OpenShift Virt installation test: ok"
