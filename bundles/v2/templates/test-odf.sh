#!/bin/bash -e
# test-odf.sh -- LSO + ODF operators + StorageCluster + PVC operand test

source "$(dirname "$0")/bundle-test-lib.sh"

###### Install LSO #######

echo_step "Checking operator package manifests"
oc get packagemanifests | grep odf-operator
oc get packagemanifests | grep local-storage-operator

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
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

###### Install ODF Operator #######

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
  installPlanApproval: Automatic
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo_step "Waiting for LSO and ODF operators to install"

wait_for_csv "local-storage-operator"
result_out "Local Storage Operator installation test: ok"

wait_for_csv "odf-operator"
wait_for_csv "rook-ceph-operator"

echo_step "Showing state of CSVs"
oc get csv -A

result_out "ODF Operator installation test: ok"

###### Install Local Volume Set #######

echo_step "Install Local Volume Set onto 3-node cluster"

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

wait_for_operand LocalVolumeSet localvolumeset openshift-local-storage \
	'{.status.totalProvisionedDeviceCount}' '^3$'

wait_all_pods openshift-local-storage

echo
oc get po -n openshift-local-storage
echo
oc get pv -A
echo

result_out "Local Volume Set installation test: ok"

###### Install StorageCluster #######

echo_step "Adding storage label to nodes"
oc get nodes -o name | xargs -I {} oc patch {} --type=json \
	-p='[{"op": "add", "path": "/metadata/labels/cluster.ocs.openshift.io~1openshift-storage", "value": ""}]'

echo_step "Create StorageCluster Resource"

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

wait_for_operand StorageCluster ocs-storagecluster openshift-storage \
	'{.status.phase}' '^[Rr]eady$' 1800

wait_all_pods openshift-storage

echo_step "Showing pods in openshift-storage namespace"
echo
oc get po -n openshift-storage
echo

echo_step "Showing StorageCluster yaml"
oc get StorageCluster ocs-storagecluster -o yaml -n openshift-storage

result_out "Storage Cluster installation test: ok"

###### Test PVC creation #######

echo_step "Test PVC creation"

cat << EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odf-test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 1Gi
EOF

echo_step "Waiting for PVC to bind"

wait_for_operand PersistentVolumeClaim odf-test-pvc default \
	'{.status.phase}' '^Bound$' 120

oc get pvc

result_out "PVC creation test: ok"

echo_step "OpenShift Data Foundation install Succeeded"
result_out "OpenShift Data Foundation installation test: ok"
