#!/bin/bash -e
# Log into a cluster and run this test script to install OpenShift Service Mesh

oc whoami || . <(aba login) 

FEATURE_NAME="OpenShift Service Mesh"
OP_NAME=(servicemeshoperator3 kiali-ossm)
OP_CSV=(servicemeshoperator3 kiali-operator)
OP_NS=istio-system

OPERAND_KIND=(Istio IstioCNI)
OPERAND_NAME=(default default)
OPERAND_NS=(istio-system istio-system)
OPERAND_STATUS=(^healthy$ ^healthy$)

waitAllPodsInNamespace() {
	echo "Waiting for all pods to become ready in namespace $1 ..."
	list=$(oc get po --no-headers -n $1 2>/dev/null | awk '{split($2, arr, "/"); if (arr[1] != arr[2] && $3 != "Completed") print};')
	until [ ! "$list" ]; do
		list=$(oc get po --no-headers -n $1 2>/dev/null | awk '{split($2, arr, "/"); if (arr[1] != arr[2] && $3 != "Completed") print};')
		sleep 10
	done
	echo All pods ready in namespace $1
}

#echo_green() { [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }

echo_step() {
	echo
	echo ##################
	echo $@
	echo ##################
	echo
}

testResultOut() {
	echo_step $*
	echo $* >&3
}

operatorIsUp() {
	for csv in ${OP_CSV[@]}
	do
		echo Waiting for CSV: $csv
		until oc get csv -n openshift-operators | grep $csv.*Succeeded
		do
			sleep 5
			echo -n .
		done

		testResultOut "$FEATURE_NAME ($csv) Operator installation test: ok"
	done
}

operandIsUp() {
	timeout_s=600   # try for this number of seconds

	for i in ${!OPERAND_KIND[@]}
	do
		start_s=$(date +%s)
		failed=

		k=${OPERAND_KIND[$i]}
		n=${OPERAND_NAME[$i]}
		ns=${OPERAND_NS[$i]}
		s=${OPERAND_STATUS[$i]}

		echo
		echo "Inspecting kind: $k name: $n namespace: $ns for status: $s"
		echo

		until oc get $k $n -n $ns -o jsonpath={.status.state} | grep -i "$s"
		do
			sleep 5
			echo -n .

			now_s=$(date +%s)
			diff_s=$(expr $now_s - $start_s)
			[ $diff_s -gt $timeout_s ] && failed="failed (timeout)" && break
		done

		if [ "$failed" ]; then
			testResultOut "$FEATURE_NAME ($k/$n) Operand installation test: $failed"
			exit 1
		else
			testResultOut "$FEATURE_NAME ($k/$n) Operand installation test: ok"
		fi
	done
}

operandShow() {
	for i in ${OPERAND_KIND[@]}
	do
		k=${OPERAND_KIND[$i]}
		n=${OPERAND_NAME[$i]}
		ns=${OPERAND_NS[$i]}

		echo Kind: $k  Name: $n  Namespace: $ns
		echo

		waitAllPodsInNamespace $ns

		echo_step "oc get po -n $ns"
		oc get po -n $ns

		echo_step "oc get $k $n -n $ns"
		oc get $k $n -n $ns 

		echo_step "oc get $k $n -n $ns -o yaml"
		oc get $k $n -n $ns -o yaml 
	done
}

{ true >&3; } 2>/dev/null || exec 3>&1  # If channel 3 not open, then open it

###### Install Operator #######

echo_step "Checking operator package manifest(s) exist"

for op in ${OP[@]}
do
	oc get packagemanifests | grep $op
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
#  v1.26-latest 
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

# Output the result
for i in ${!OP_NAME[@]}
do
	oc get Subscription ${OP_NAME[$i]} -n openshift-operators -o yaml
done

echo_step "Waiting for operator to install"

#operatorIsUp && testResultOut $FEATURE_NAME Operator installation test: ok || testResultOut $FEATURE_NAME Operator installation test: failed
operatorIsUp 

echo_step Showing operator pods:

waitAllPodsInNamespace openshift-operators

oc get po -n openshift-operators

#testResultOut $FEATURE_NAME Operator installation test: ok
#testResultOut Kiali Operator installation test: ok

echo_step Install $FEATURE_NAME operand:

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
  version: v1.24.6
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
  version: v1.24.6
EOF

#operandIsUp && testResultOut $FEATURE_NAME operand installation test: ok || testResultOut $FEATURE_NAME operand installation test: failed >&2
operandIsUp 

echo_step "Showing operand status"

waitAllPodsInNamespace istio-system

operandShow

echo Done $0
