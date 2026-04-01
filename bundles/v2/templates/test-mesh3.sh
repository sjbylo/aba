#!/bin/bash -e
# test-mesh3.sh -- OpenShift Service Mesh 3 + Kiali operators + Istio/IstioCNI operands

source "$(dirname "$0")/bundle-test-lib.sh"

OP_NAME=(servicemeshoperator3 kiali-ossm)
OP_CSV=(servicemeshoperator3 kiali-operator)

echo_step "Checking operator package manifests exist"
for op in "${OP_NAME[@]}"; do
	oc get packagemanifests | grep "$op"
done

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kiali-ossm
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kiali-ossm
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

sleep 1

for i in "${!OP_NAME[@]}"; do
	oc get Subscription "${OP_NAME[$i]}" -n openshift-operators -o yaml
done

echo_step "Waiting for operators to install"

for csv in "${OP_CSV[@]}"; do
	wait_for_csv "$csv"
	result_out "OpenShift Service Mesh ($csv) Operator installation test: ok"
done

echo_step "Showing operator pods"
wait_all_pods openshift-operators
oc get po -n openshift-operators

echo_step "Detecting latest supported Istio version from CRD"

ISTIO_VERSION=$(oc get crd istios.sailoperator.io -o json | \
	jq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.version.enum[]' | \
	grep -- '-latest$' | sort -V | tail -1)

[ -z "$ISTIO_VERSION" ] && { echo "ERROR: could not detect supported Istio version from CRD" >&2; exit 1; }

echo "Using Istio version: $ISTIO_VERSION"

echo_step "Install Service Mesh operands (Istio + IstioCNI)"

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
---
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  namespace: istio-system
  updateStrategy:
    type: InPlace
    inactiveRevisionDeletionGracePeriodSeconds: 30
  version: $ISTIO_VERSION
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-cni
---
kind: IstioCNI
apiVersion: sailoperator.io/v1
metadata:
  name: default
spec:
  namespace: istio-cni
  version: $ISTIO_VERSION
EOF

OPERAND_KIND=(Istio IstioCNI)
OPERAND_NAME=(default default)
OPERAND_NS=(istio-system istio-system)
OPERAND_STATUS=('^Healthy$' '^Healthy$')

for i in "${!OPERAND_KIND[@]}"; do
	wait_for_operand "${OPERAND_KIND[$i]}" "${OPERAND_NAME[$i]}" "${OPERAND_NS[$i]}" \
		'{.status.state}' "${OPERAND_STATUS[$i]}"
	result_out "OpenShift Service Mesh (${OPERAND_KIND[$i]}/${OPERAND_NAME[$i]}) Operand installation test: ok"
done

echo_step "Showing operand status"
wait_all_pods istio-system

for i in "${!OPERAND_KIND[@]}"; do
	k=${OPERAND_KIND[$i]}
	n=${OPERAND_NAME[$i]}
	ns=${OPERAND_NS[$i]}

	echo "Kind: $k  Name: $n  Namespace: $ns"
	echo

	echo_step "oc get po -n $ns"
	oc get po -n "$ns"

	echo_step "oc get $k $n -n $ns"
	oc get "$k" "$n" -n "$ns"

	echo_step "oc get $k $n -n $ns -o yaml"
	oc get "$k" "$n" -n "$ns" -o yaml
done

echo "Done $0"
