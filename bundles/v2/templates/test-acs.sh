#!/bin/bash -e
# test-acs.sh -- Advanced Cluster Security (RHACS) operator + Central operand

source "$(dirname "$0")/bundle-test-lib.sh"

NS=stackrox

echo_step "Checking operator rhacs-operator in package manifest"
oc get packagemanifests | grep rhacs-operator

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: $NS
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhacs-operator
  namespace: $NS
spec:
  name: rhacs-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

wait_for_csv "rhacs-operator"

result_out "ACS Operator installation test: ok"

echo_step "Install Central operand"

cat << EOF | oc apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: Central
metadata:
  name: stackrox-central-services
  namespace: $NS
spec:
  central:
    exposure:
      route:
        enabled: true
    persistence:
      ephemeral: {}
EOF

wait_for_operand Central stackrox-central-services $NS \
	'{.status.conditions[?(@.type=="Deployed")].status}' '^True$' 600

wait_all_pods $NS

echo_step "Showing ACS pods"
echo
oc get po -n $NS
echo

result_out "ACS Central installation test: ok"
