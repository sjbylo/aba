#!/bin/bash -e
# Log into a cluster and run this test script to install $NAME

NAME="Web Terminal"
OP=web-terminal
NS=openshift-operators
OPERAND=
OPERAND_NS=
OPERAND_NAME=

echo_green()    { [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_step() {
	echo_green ##################
	echo_green $@
}

resultOut() {
	echo_step $*
	echo $* >&3
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

###### Install Operator #######

echo_step Checking operator $OP in package manifest

oc get packagemanifests| grep $OP

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
#apiVersion: operators.coreos.com/v1
#kind: OperatorGroup
#metadata:
#  name: rhods-operator
#  namespace: $NS
#---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: web-terminal
  namespace: $NS
spec:
  channel: fast
  name: web-terminal
  source: redhat-operators
  sourceNamespace: openshift-marketplace
#  startingCSV: web-terminal.v1.13.0
EOF

echo_step "Waiting for operator to install"

until oc get csv -n openshift-operators | grep $OP.*Succeeded
do
	sleep 5
	echo -n .
done

waitAllPodsInNamespace $NS

echo_step Showing operator pods 
echo
oc get po -n $NS
echo

resultOut $NAME Operator installation test: ok

#exit   # Only install the op. for now

#echo_step Install Operands 

#cat << EOF | oc apply -f -
#apiVersion: datasciencecluster.opendatahub.io/v1
#kind: DataScienceCluster
#metadata:
#EOF

OperandUp() {
	until oc get $OPERAND $OPERAND_NAME -n istio-system -o jsonpath={.status.phase} | grep -i "ready"
	do
		sleep 5
		echo -n .
	done
}
# default-dsc

#OperandUp && resultOut $NAME operand installation test: ok || resultOut $NAME operand installation test: failed 

#sleep 30 # Give pods time to start

#waitAllPodsInNamespace $NS

#echo_step "Showing $NAME operand pods in namespace $NS"
#echo
#oc get po -n $NS
#echo

#echo_step "Showing deployments and pods in project redhat-ods-applications:"
#oc get deployment,pod -n redhat-ods-applications

#resultOut $NAME installation test: ok

