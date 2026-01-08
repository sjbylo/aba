#!/bin/bash -ex
# Log into a cluster and run this test script to install ODF on *non-sno* cluster

oc whoami || . <(aba login) 

echo_step() {
	set +x
	echo
	echo "###########################################################"
	echo $@
	echo "###########################################################"
	echo
	set -x
}

{ true >&3; } 2>/dev/null || exec 3>&1  # If channel 3 not open, then open it

waitAllPodsInNamespace() {
	set +x
	echo "Waiting for all pods to become ready in namespace $1 ..."
	list=$(oc get po --no-headers -n $1 2>/dev/null | awk '{split($2, arr, "/"); if (arr[1] != arr[2] && $3 != "Completed") print};')
	until [ ! "$list" ]; do
		list=$(oc get po --no-headers -n $1 2>/dev/null | awk '{split($2, arr, "/"); if (arr[1] != arr[2] && $3 != "Completed") print};')
		sleep 10
	done
	echo All pods ready in namespace $1
	set -x
}

waitForCSVSuccess() {
	set +x
	echo_step "Waiting for $1 to install"
	until oc get csv -A | grep $1.*Succeeded
	do
		sleep 5
		echo -n .
	done
	echo $1 installated ok 
	set -x
}

###### Install ODF  #######

echo_step Checking operator package manifest available
oc get packagemanifests| grep odf-operator
oc get packagemanifests| grep local-storage-operator


cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-local-storage-op-grp
  namespace: openshift-local-storage
spec:
  targetNamespaces:
  - openshift-local-storage
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/local-storage-operator.openshift-local-storage: ""
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
#  channel: stable
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
#  startingCSV: local-storage-operator.v4.20.0-202511252120
EOF

echo_step Checking operator package manifest
oc get packagemanifests| grep odf-operator

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-op-grp
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/odf-operator.openshift-storage: ""
  name: odf-operator
  namespace: openshift-storage
spec:
#  channel: stable-4.20
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
#  startingCSV: odf-operator.v4.20.4-rhodf
EOF

echo_step "Waiting for LSO and ODF operators to install"

waitForCSVSuccess local-storage-operator

echo Local Storage Operator installation test: ok >&3

waitForCSVSuccess odf-operator

waitForCSVSuccess rook-ceph-operator

echo_step Showing state of CSVs ...
oc get csv -A

echo ODF Operator installation test: ok >&3

echo_step "ODF Operator install Succeeded"

echo_step Install Local Volume Set onto 3-node cluster

cat << EOF | oc apply -f -
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: localvolumeset
  namespace: openshift-local-storage
spec:
  deviceInclusionSpec:
    deviceMechanicalProperties:
    - NonRotational
    deviceTypes:
    - disk
    - part
    minSize: 1Gi
  nodeSelector:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
        - master1
        - master2
        - master3
  storageClassName: localvolume-sc
  tolerations:
  - effect: NoSchedule
    key: node.ocs.openshift.io/storage
    operator: Equal
    value: "true"
  volumeMode: Block
EOF

set +x
until oc get LocalVolumeSet localvolumeset -n openshift-local-storage -o jsonpath={.status.totalProvisionedDeviceCount} | grep "^3$"
do
	sleep 5
	echo -n .
done
set -x

waitAllPodsInNamespace openshift-local-storage

echo
oc get po -n openshift-local-storage
echo
oc get pv -A
echo

echo Local Volume Set installation test: ok >&3

###### Install ODF #######

echo_step Install Storage Cluster resource


echo_step Adding storage label to nodes 

oc get nodes -o name | xargs -I {} oc patch {} --type=json -p='[{"op": "add", "path": "/metadata/labels/cluster.ocs.openshift.io~1openshift-storage", "value": ""}]'

echo_step Create StorageCluster Resource

cat << EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  annotations:
    cluster.ocs.openshift.io/local-devices: "true"
    uninstall.ocs.openshift.io/cleanup-policy: delete
    uninstall.ocs.openshift.io/mode: graceful
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  encryption:
    keyRotation:
      schedule: '@weekly'
  flexibleScaling: true
  managedResources:
    cephBlockPools:
      defaultStorageClass: true
      defaultVirtualizationStorageClass: true
  monDataDirHostPath: /var/lib/rook
  network:
    connections:
  resourceProfile: lean
  storageDeviceSets:
  - config: {}
    count: 3
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "1"
        storageClassName: localvolume-sc
        volumeMode: Block
    name: ocs-deviceset-localvolume-sc
    replica: 1
EOF

echo_step "Waiting for operand pods to install"

set +x
until oc get StorageCluster ocs-storagecluster -n openshift-storage -o jsonpath='{.status.phase}' | grep -i ^ready$
do
	sleep 5
	echo -n .
done
set -x

waitAllPodsInNamespace openshift-storage

echo_step "SHowing pods in openshift-storage namespace"

echo
oc get po -n openshift-storage
echo
echo_step "Showing StorageCluster ocs-storagecluster yaml"
oc get StorageCluster ocs-storagecluster -o yaml -n openshift-storage
echo

echo Storage Cluster installation test: ok >&3

echo_step Test PVC creation

cat << EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  # Change this to ocs-storagecluster-cephfs if you want to test Shared Filesystem
  storageClassName: ocs-storagecluster-ceph-rbd 
  resources:
    requests:
      storage: 1Gi
EOF

echo_step Showing PVC odf-test-pvc

set +x
until oc get pvc | grep Bound
do
	echo -n .
	sleep 5
done
set -x

oc get pvc 

echo PVC creation test: ok >&3

echo_step OpenShift Data Foundation install Succeeded
echo OpenShift Data Foundation installation test: ok >&3

