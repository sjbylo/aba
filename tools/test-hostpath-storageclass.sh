#!/bin/bash

set -eo pipefail

NAMESPACE="${NAMESPACE:-default}"
SC_NAME="${SC_NAME:-hostpath-test}"
HOSTPATH_ROOT="${HOSTPATH_ROOT:-/tmp/test-pv}"
POLL_SECONDS="${POLL_SECONDS:-2}"

CREATED_PVS=()

cleanup()
{
    echo
    echo "Cleaning up test PVs..."

    for pv in "${CREATED_PVS[@]}"; do
        oc delete pv "${pv}" --ignore-not-found
    done

    oc delete storageclass "${SC_NAME}" --ignore-not-found
}

trap cleanup EXIT

echo "Creating StorageClass: ${SC_NAME}"

cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NAME}
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
EOF

echo
echo "Waiting for PVCs in namespace: ${NAMESPACE}"
echo
echo "Create a PVC with:"
echo
echo "  oc create -f pvc.yaml"
echo
echo "or:"
echo
echo "  oc create -n ${NAMESPACE} -f - <<EOF"
echo "  apiVersion: v1"
echo "  kind: PersistentVolumeClaim"
echo "  metadata:"
echo "    name: my-pvc"
echo "  spec:"
echo "    accessModes:"
echo "      - ReadWriteOnce"
echo "    resources:"
echo "      requests:"
echo "        storage: 1Gi"
echo "EOF"
echo

while true; do

    PVCs=$(oc get pvc -n "${NAMESPACE}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    for pvc in ${PVCs}; do

        # Skip PVCs we have already handled.
        pv="hostpath-${pvc}"

        if oc get pv "${pv}" >/dev/null 2>&1; then
            continue
        fi

        echo
        echo "Found new PVC: ${pvc}"

        pvc_uid=$(oc get pvc "${pvc}" -n "${NAMESPACE}" \
            -o jsonpath='{.metadata.uid}')

        requested_size=$(oc get pvc "${pvc}" -n "${NAMESPACE}" \
            -o jsonpath='{.spec.resources.requests.storage}')

        hostpath="${HOSTPATH_ROOT}/${pvc}"

        echo "  UID:       ${pvc_uid}"
        echo "  Size:      ${requested_size}"
        echo "  PV:        ${pv}"
        echo "  hostPath:  ${hostpath}"

        # This simple test assumes a single-node cluster.
        NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')

        echo "  Node:      ${NODE}"

        # Create the directory on the node.
        oc debug "node/${NODE}" \
            -- chroot /host mkdir -p "${hostpath}" \
            >/dev/null

        cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv}
spec:
  capacity:
    storage: ${requested_size}
  accessModes:
    - ReadWriteOnce
  storageClassName: ${SC_NAME}
  persistentVolumeReclaimPolicy: Delete
  hostPath:
    path: ${hostpath}
    type: DirectoryOrCreate
  claimRef:
    namespace: ${NAMESPACE}
    name: ${pvc}
    uid: ${pvc_uid}
EOF

        CREATED_PVS+=("${pv}")

        echo
        echo "Created PV: ${pv}"
        echo
        oc get pvc "${pvc}" -n "${NAMESPACE}"
        echo

    done

    sleep "${POLL_SECONDS}"

done
