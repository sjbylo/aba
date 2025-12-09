#!/bin/bash -e
# Log into a cluster and run this test script to install OCP-V and MTV

#echo_green()    { [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_step() {
	echo ##################
	echo $@
	echo ##################
}

{ true >&3; } 2>/dev/null || exec 3>&1  # If channel 3 not open, then open it

waitAllPodsInNamespace() {
	echo "Waiting for all pods to become ready in namespace $1 ..."
	list=$(oc get po --no-headers -n $1 2>/dev/null | awk '{split($2, arr, "/"); if (arr[1] != arr[2] && $3 != "Completed") print};')
	until [ ! "$list" ]; do
		list=$(oc get po --no-headers -n $1 2>/dev/null | awk '{split($2, arr, "/"); if (arr[1] != arr[2] && $3 != "Completed") print};')
		sleep 10
	done
	echo All pods ready in namespace $1
}

###### Install OCP-V #######

echo_step Checking op. package manifest
oc get packagemanifests| grep kubevirt-hyperconverged

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
#  startingCSV: kubevirt-hyperconverged-operator.v4.15.10
  channel: "stable" 
EOF

echo_step "Waiting for op. to install"

until oc get csv -A | grep openshift-cnv.*Succeeded
do
	sleep 5
	echo -n .
done

echo OpenShift Virt Operator installation test: ok >&3

echo_step "Op install Succeeded"

echo_step Install OCP-V Operands 

#oc apply -f  ~/tmp/install-ocpv.yaml

cat << EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
EOF

until oc get HyperConverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath={.status.systemHealthStatus} | grep "^healthy$"
do
	sleep 5
	echo -n .
done

waitAllPodsInNamespace openshift-cnv

echo
oc get po -n openshift-cnv
echo

echo OpenShift Virt installation test: ok >&3

###### Install MTV #######

echo_step Checking op. package manifest
oc get packagemanifests| grep mtv-operator

cat << EOF | oc apply -f -
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: openshift-mtv
EOF


cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: migration
  namespace: openshift-mtv
spec:
  targetNamespaces:
    - openshift-mtv
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: openshift-mtv
spec:
#  channel: release-v2.9
  installPlanApproval: Automatic
  name: mtv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
#  startingCSV: "mtv-operator.v2.6.7"
EOF

echo_step "Waiting for op. to install"

until oc get csv -A | grep openshift-mtv.*Succeeded
do
	sleep 5
	echo -n .
done

echo MTV Operator installation test: ok >&3

echo_step "Op install Succeeded"

echo_step Install MTV Operands 

cat << EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  olm_managed: true
EOF

echo_step Waiting for MTV Operands 

until oc get ForkliftController forklift-controller -n openshift-mtv -o jsonpath='{.status.conditions[?(@.type=="Running")].status}' | grep -i ^true$
do
	sleep 5
	echo -n .
done

sleep 20 # Wait for forklift pods to show up ...

# List all pending pods and check the MTV pods
until ! oc get po -A | awk  '{split($3, arr, "/"); if (arr[1] != arr[2] && $4 != "Completed") print};' | grep forklift
do
	sleep 5
	echo -n .
done

waitAllPodsInNamespace openshift-cnv

echo
oc get po -n openshift-mtv
echo

echo_step MTV install Succeeded

echo MTV installation test: ok >&3

