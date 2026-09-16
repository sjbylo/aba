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

result_out "OpenShift Virt operand installation test: ok"

echo_step "Verifying HyperConverged conditions"

for cond in Available ReconcileComplete; do
	val=$(oc get HyperConverged kubevirt-hyperconverged -n $NS \
		-o jsonpath="{.status.conditions[?(@.type==\"$cond\")].status}")
	echo "  $cond = $val"
	[ "$val" = "True" ] || { echo "ERROR: HyperConverged condition $cond is not True (got: $val)" >&2; exit 1; }
done
for cond in Degraded; do
	val=$(oc get HyperConverged kubevirt-hyperconverged -n $NS \
		-o jsonpath="{.status.conditions[?(@.type==\"$cond\")].status}")
	echo "  $cond = $val"
	[ "$val" = "False" ] || { echo "ERROR: HyperConverged condition $cond is not False (got: $val)" >&2; exit 1; }
done

result_out "HyperConverged conditions verification: ok"

echo_step "Verifying key deployments in $NS"

for dep in virt-api virt-controller virt-operator ssp-operator \
           cdi-operator cdi-apiserver cdi-deployment cdi-uploadproxy; do
	oc get deployment "$dep" -n $NS --no-headers || \
		{ echo "ERROR: deployment $dep missing" >&2; exit 1; }
done

oc get daemonset virt-handler -n $NS --no-headers || \
	{ echo "ERROR: daemonset virt-handler missing" >&2; exit 1; }

echo
oc get deployment -n $NS
echo

result_out "OpenShift Virt key deployments verification: ok"

echo_step "Creating minimal VM to verify containerDisk image is pullable"

oc new-project test-cnv-vm || true

# Equivalent to: virtctl create vm --name test-vm --memory 1Gi \
#   --volume-containerdisk=src:quay.io/containerdisks/centos-stream:9
cat << EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm
  namespace: test-cnv-vm
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          disks:
          - name: containerdisk
            disk:
              bus: virtio
        resources:
          requests:
            memory: 1Gi
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/centos-stream:9
EOF

wait_for_operand VirtualMachineInstance test-vm test-cnv-vm \
	'{.status.conditions[?(@.type=="Ready")].status}' '^True$' 300

echo_step "Showing VM status"
oc get vm,vmi -n test-cnv-vm

result_out "VM containerDisk image pull and start: ok"

echo_step "Cleaning up test VM"
oc delete project test-cnv-vm --wait=false

result_out "OpenShift Virt installation test: ok"
