#!/bin/bash -e
# test-mtv.sh -- Migration Toolkit for Virtualization operator + ForkliftController operand

source "$(dirname "$0")/bundle-test-lib.sh"

NS=openshift-mtv

echo_step "Checking operator mtv-operator in package manifest"
oc get packagemanifests | grep mtv-operator

cat << EOF | oc apply -f -
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: $NS
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: migration
  namespace: $NS
spec:
  targetNamespaces:
    - $NS
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: $NS
spec:
  installPlanApproval: Automatic
  name: mtv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_for_csv "mtv-operator"

result_out "MTV Operator installation test: ok"

echo_step "Install MTV operand (ForkliftController)"

cat << EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: $NS
spec:
  olm_managed: true
EOF

wait_for_operand ForkliftController forklift-controller $NS \
	'{.status.conditions[?(@.type=="Running")].status}' '^[Tt]rue$'

sleep 20

# Wait specifically for forklift pods
echo_step "Waiting for forklift pods"
until ! oc get po -A | awk '{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print}' | grep forklift; do
	sleep 5
	echo -n .
done

wait_all_pods openshift-cnv

echo_step "Showing MTV pods"
echo
oc get po -n $NS
echo

result_out "MTV installation test: ok"
