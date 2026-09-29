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

# --- Boot source verification (day2-virt) ---
echo_step "Verifying boot source mirror configuration (day2-virt)"

aba day2-virt

# Check that ITMS entries exist for containerdisk images (CentOS/Fedora)
_itms_count=$(oc get imagetagmirrorset -o jsonpath='{range .items[*].spec.imageTagMirrors[*]}{.source}{"\n"}{end}' 2>/dev/null | grep -c 'containerdisks' || true)
if [ "$_itms_count" -lt 1 ]; then
	echo "ERROR: No ITMS entries found for containerdisk boot source images" >&2
	exit 1
fi

# Check that custom ImageStreams exist for RHEL images
_is_count=$(oc get imagestream -n openshift-virtualization-os-images -l app.kubernetes.io/managed-by=aba-day2-virt --no-headers 2>/dev/null | wc -l)
echo "  Custom mirror-backed ImageStreams found: $_is_count"
if [ "$_is_count" -lt 1 ]; then
	echo "ERROR: No custom ImageStreams created by day2-virt" >&2
	exit 1
fi

# Verify DataImportCrons exist
_dic_count=$(oc get dataimportcron -n openshift-virtualization-os-images --no-headers 2>/dev/null | wc -l)
echo "  DataImportCrons found: $_dic_count"
[ "$_dic_count" -ge 3 ] || { echo "ERROR: Expected at least 3 DataImportCrons, got $_dic_count" >&2; exit 1; }

# Wait for at least one containerdisk DataImportCron to show UpToDate=True (import succeeded)
echo "  Waiting for boot source imports (max 10m)..."
_bs_start=$(date +%s)
_bs_ok=
until oc get dataimportcron -n openshift-virtualization-os-images \
	-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="UpToDate")].status}{"\n"}{end}' 2>/dev/null \
	| grep -q "True"; do
	sleep 15
	echo -n .
	_bs_elapsed=$(( $(date +%s) - _bs_start ))
	if [ "$_bs_elapsed" -gt 600 ]; then
		echo
		echo "WARNING: Boot source imports did not complete within 10m" >&2
		oc get dataimportcron -n openshift-virtualization-os-images >&2
		break
	fi
done
[ -z "$_bs_ok" ] && oc get dataimportcron -n openshift-virtualization-os-images \
	-o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="UpToDate")].status}{"\n"}{end}' 2>/dev/null \
	| grep -q "True" && _bs_ok=1
echo

oc get dataimportcron -n openshift-virtualization-os-images \
	-o custom-columns='NAME:.metadata.name,UP-TO-DATE:.status.conditions[?(@.type=="UpToDate")].status,LAST-IMPORT:.status.lastImportedPVC.name'

if [ "$_bs_ok" ]; then
	result_out "Boot source mirror verification (day2-virt): ok"
else
	echo "ERROR: No boot source import succeeded — cannot verify boot source VM" >&2
	exit 1
fi

# --- RHEL VM boot test ---
echo_step "Creating RHEL VM from boot source to verify end-to-end import"

oc new-project test-virt-bootsource || true

# Use centos-stream9 DataSource (from containerdisk import — always available)
# This verifies the full chain: mirror → ITMS → node pull → DataVolume → VM
cat << EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-bootsource-vm
  namespace: test-virt-bootsource
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
        resources:
          requests:
            memory: 1Gi
      volumes:
      - name: rootdisk
        dataVolume:
          name: test-bootsource-dv
  dataVolumeTemplates:
  - metadata:
      name: test-bootsource-dv
    spec:
      sourceRef:
        kind: DataSource
        name: centos-stream9
        namespace: openshift-virtualization-os-images
      storage:
        resources:
          requests:
            storage: 35Gi
EOF

wait_for_operand VirtualMachineInstance test-bootsource-vm test-virt-bootsource \
	'{.status.conditions[?(@.type=="Ready")].status}' '^True$' 600

echo_step "Showing boot source VM status"
oc get vm,vmi -n test-virt-bootsource

result_out "VM boot source (centos-stream9 via mirror) start: ok"

echo_step "Cleaning up boot source test VM"
oc delete project test-virt-bootsource --wait=false
