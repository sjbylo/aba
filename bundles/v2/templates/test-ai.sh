#!/bin/bash -e
# test-ai.sh -- OpenShift AI (RHODS) operator + DataScienceCluster operand
# Usage: test-ai.sh [--dev]
#   --dev  Skip cleanup at the end so you can inspect/debug and re-run easily.

# See: Chapter 3. Deploy OpenShift AI in a disconnected environment
# https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/installing_and_uninstalling_openshift_ai_self-managed_in_a_disconnected_environment/deploying-openshift-ai-in-a-disconnected-environment_install
# https://github.com/red-hat-data-services/rhoai-disconnected-install-helper  =>  rhoai-3\.[0-9]-imagesetconfig.yaml

_DEV_MODE=
[ "${1:-}" = "--dev" ] && _DEV_MODE=1

source "$(dirname "$0")/bundle-test-lib.sh"

OP=rhods-operator
NS=redhat-ods-operator

echo_step "Checking operator $OP in package manifest"
oc get packagemanifests | grep $OP

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: $NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operators
  namespace: $NS
spec:
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_for_csv "$OP"

wait_all_pods $NS

echo_step "Showing operator pods"
echo
oc get po -n $NS
echo

result_out "OpenShift AI Operator installation test: ok"

echo_step "Install DataScienceCluster operand"

cat << EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    aipipelines:
      managementState: Managed
    dashboard:
      managementState: Managed
    kserve:
      managementState: Removed
    kueue:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Managed
    trustyai:
      managementState: Managed
    workbenches:
      managementState: Managed
      workbenchNamespace: rhods-notebooks
EOF

wait_for_operand DataScienceCluster default-dsc default \
	'{.status.phase}' '[Rr]eady'

sleep 30

wait_all_pods $NS

echo_step "Showing OpenShift AI operand pods in namespace $NS"
echo
oc get po -n $NS
echo

echo_step "Showing deployments and pods in project redhat-ods-applications"
oc get deployment,pod -n redhat-ods-applications

result_out "OpenShift AI operand installation test: ok"

echo_step "Verifying installed components in DataScienceCluster status"

for comp in dashboard aipipelines trainingoperator trustyai workbenches; do
	# RHOAI 3.5+: installedComponents removed; check .status.components instead
	val=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.components.$comp.managementState}" 2>/dev/null)
	[ "$val" = "Managed" ] && val="true"
	if [ -z "$val" ]; then
		val=$(oc get datasciencecluster default-dsc -o jsonpath="{.status.installedComponents.$comp}" 2>/dev/null)
	fi
	echo "  $comp = $val"
	[ "$val" = "true" ] || { echo "ERROR: component $comp not installed (got: $val)" >&2; exit 1; }
done

result_out "DataScienceCluster installed components verification: ok"

echo_step "Waiting for pods in redhat-ods-applications"

wait_all_pods redhat-ods-applications 900

echo_step "Verifying key deployments in redhat-ods-applications"

for dep in rhods-dashboard data-science-pipelines-operator-controller-manager \
           notebook-controller-deployment odh-notebook-controller-manager; do
	oc get deployment "$dep" -n redhat-ods-applications --no-headers || \
		{ echo "ERROR: deployment $dep missing" >&2; exit 1; }
done

echo
oc get deployment -n redhat-ods-applications
echo

result_out "OpenShift AI key deployments verification: ok"

echo_step "Verifying RHOAI dashboard service is accessible"

# RHOAI 3.5+: dashboard route may not exist; verify service is serving
_dash_ok=
if _dash_host=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null) && [ -n "$_dash_host" ]; then
	echo "Dashboard URL: https://$_dash_host"
	curl -k -sf "https://$_dash_host" > /dev/null && _dash_ok=1
else
	echo "No dashboard route — checking service endpoint directly"
	oc get svc rhods-dashboard -n redhat-ods-applications --no-headers || \
		{ echo "ERROR: rhods-dashboard service not found" >&2; exit 1; }
	# Verify dashboard pod is serving (liveness via localhost inside pod)
	oc exec -n redhat-ods-applications deployment/rhods-dashboard -c rhods-dashboard -- \
		curl -sf http://localhost:8080/ > /dev/null 2>&1 && _dash_ok=1
fi

[ "$_dash_ok" ] || { echo "ERROR: RHOAI dashboard not reachable" >&2; exit 1; }

result_out "OpenShift AI dashboard accessible: ok"

######################################################################
# Data Science Pipelines — verify DSPA deploys and API is healthy
# All images (mariadb, minio, DSP controllers) are relatedImages in
# the RHOAI operator CSV — mirrored via the catalog, mapped via IDMS.
######################################################################

echo_step "Creating Data Science Pipelines Application (DSPA)"

# DSP requires PVCs for mariadb and minio. The bundle test cluster is
# agent-based bare metal — no CSI driver, no StorageClass. Create a
# temporary hostPath SC and static PVs so the DSP test actually runs.
echo "Creating temporary hostPath StorageClass for DSP test"
cat << 'SCEOF' | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hostpath-test
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
reclaimPolicy: Delete
SCEOF

oc new-project test-dsp || true

# mariadb/minio pods need write access to hostPath-backed PVs.
# Grant anyuid SCC so the containers can write to the mounted directories.
oc adm policy add-scc-to-user anyuid -z default -n test-dsp

cat << EOF | oc apply -f -
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1
kind: DataSciencePipelinesApplication
metadata:
  name: dspa-test
  namespace: test-dsp
spec:
  apiServer:
    deploy: true
    enableRoute: true
  database:
    mariaDB:
      deploy: true
      pipelineDBName: mlpipeline
      pvcSize: 1Gi
  objectStorage:
    minio:
      deploy: true
      pvcSize: 1Gi
      image: 'quay.io/opendatahub/minio:RELEASE.2019-08-14T20-37-41Z-license-compliance'
  persistenceAgent:
    deploy: true
  scheduledWorkflow:
    deploy: true
EOF

# Wait for the DSPA controller to create PVCs, then create a matching
# hostPath PV for each one with explicit claimRef for deterministic binding.
echo "Waiting for DSPA PVCs to appear ..."
_pvcs_found=
for _try in $(seq 1 30); do
	_pvc_count=$(oc get pvc -n test-dsp --no-headers 2>/dev/null | wc -l)
	if [ "$_pvc_count" -ge 2 ]; then
		_pvcs_found=1
		break
	fi
	echo -n .
	sleep 5
done
echo

[ "$_pvcs_found" ] || { echo "ERROR: Expected >=2 PVCs but only ${_pvc_count:-0} appeared within 150s" >&2; exit 1; }

echo "Creating hostPath PVs for each Pending PVC ..."
_pv_idx=0
while IFS= read -r _pvc_name; do
	_pv_idx=$(( _pv_idx + 1 ))
	_pvc_uid=$(oc get pvc "$_pvc_name" -n test-dsp -o jsonpath='{.metadata.uid}')
	cat << PVEOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: hostpath-dsp-${_pv_idx}
spec:
  capacity:
    storage: 2Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: hostpath-test
  claimRef:
    namespace: test-dsp
    name: ${_pvc_name}
    uid: ${_pvc_uid}
  hostPath:
    path: /tmp/dsp-test-pv-${_pv_idx}
    type: DirectoryOrCreate
PVEOF
done < <(oc get pvc -n test-dsp --no-headers -o custom-columns=NAME:.metadata.name)
echo "Created $_pv_idx hostPath PV(s) with explicit claimRef binding"

echo_step "Waiting for DSP pods to appear"

# The DSPA controller needs time to create pods after the CR is applied.
# wait_all_pods returns instantly if 0 pods exist, so wait for at least one.
_pods_found=
for _try in $(seq 1 60); do
	_pod_count=$(oc get po -n test-dsp --no-headers 2>/dev/null | wc -l)
	if [ "$_pod_count" -ge 2 ]; then
		_pods_found=1
		break
	fi
	echo -n .
	sleep 5
done
echo

[ "$_pods_found" ] || { echo "ERROR: DSP pods never appeared in test-dsp namespace within 300s" >&2; oc get po -n test-dsp >&2; exit 1; }

echo_step "Waiting for DSP pods to become ready"

wait_all_pods test-dsp 600

echo_step "Showing DSP pods"
oc get po -n test-dsp

result_out "Data Science Pipelines Application deployed: ok"

echo_step "Waiting for DSP API route"

_dspa_ready=
for _try in $(seq 1 60); do
	_dspa_status=$(oc get dspa dspa-test -n test-dsp -o jsonpath='{.status.conditions[?(@.type=="APIServerReady")].status}' 2>/dev/null || true)
	if [ "$_dspa_status" = "True" ]; then
		_dspa_ready=1
		break
	fi
	echo -n .
	sleep 5
done
echo

[ "$_dspa_ready" ] || { echo "ERROR: DSPA API never became ready within 300s" >&2; oc get dspa dspa-test -n test-dsp -o yaml >&2; exit 1; }

echo_step "Verifying DSP API health endpoint"

_ds_route=$(oc get route ds-pipeline-dspa-test -n test-dsp -o jsonpath='{.spec.host}' 2>/dev/null || true)
_pf_pid=

if [ -n "$_ds_route" ]; then
	_ds_api="https://$_ds_route"
else
	echo "No DSP route found — using port-forward instead"
	oc port-forward -n test-dsp svc/ds-pipeline-dspa-test 8888:8888 &
	_pf_pid=$!
	sleep 3
	_ds_api="http://localhost:8888"
fi

_token=$(oc whoami -t)

_api_ok=
for _try in $(seq 1 12); do
	if curl -k -sf -H "Authorization: Bearer $_token" "$_ds_api/apis/v2beta1/healthz" > /dev/null 2>&1; then
		_api_ok=1
		break
	fi
	echo -n .
	sleep 5
done
echo

[ -n "$_pf_pid" ] && kill "$_pf_pid" 2>/dev/null || true

[ "$_api_ok" ] || { echo "ERROR: DSP API health endpoint not reachable" >&2; exit 1; }

result_out "Data Science Pipelines API health check: ok"

if [ "$_DEV_MODE" ]; then
	echo "Dev mode: skipping cleanup (test-dsp project, hostPath SC/PVs left in place)"
else
	echo_step "Cleaning up DSP test project"
	oc delete project test-dsp --wait=false

	echo "Cleaning up hostPath SC and PVs ..."
	oc delete pv hostpath-dsp-1 hostpath-dsp-2 --wait=false 2>/dev/null || true
	oc delete sc hostpath-test 2>/dev/null || true
fi

result_out "Data Science Pipelines test: ok"

result_out "OpenShift AI full installation test: ok"
