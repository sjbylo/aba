#!/bin/bash -e

source scripts/include_all.sh

aba_debug "Starting: $0 $*"



umask 077

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-cluster-conf || exit 1
verify-mirror-conf || exit 1

NAME=osus
NAMESPACE=openshift-update-service

#####################
aba_info "Accessing the cluster ..."

[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!
! oc whoami && aba_abort "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

#####################
if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
	if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
		aba_abort "cincinnati-operator not available in OperatorHub for this cluster.  Load the operator into your registry and run 'aba day2' again?"
	fi
fi

#####################
aba_info -n "Adding cluster ingress CA cert to the CA trust bundle ... "

ingress_cert="$(oc get secret -n openshift-ingress-operator router-ca -o jsonpath="{.data['tls\.crt']}"| base64 -d)"
echo "$ingress_cert" > .openshift-ingress.cacert.pem
ingress_cert_json="$(echo "$ingress_cert" | sed ':a;N;$!ba;s/\n/\\n/g')"   # Replace all new-lines with '\n'
ca_bundle_crt=$(oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' | sed ':a;N;$!ba;s/\n/\\n/g')

# Check if cert already added. 
# If these two lines already exist then it's safe to assume the cert is already in the bundle!
tmp_line8=$(echo "$ingress_cert" | head -8 | tail -1)
tmp_line12=$(echo "$ingress_cert" | head -12 | tail -1)

if echo "$ca_bundle_crt" | grep -q "$tmp_line8" && echo "$ca_bundle_crt" | grep -q "$tmp_line12"; then
	aba_info "CA cert already added"
else
	ca_bundle_crt="$ca_bundle_crt\n$ingress_cert_json"
	oc patch cm user-ca-bundle -n openshift-config --type='merge' -p '{"data":{"ca-bundle.crt":"'"$ca_bundle_crt"'"}}'
	aba_info_ok CA cert added
fi

aba_info Adding trustedCA to cluster proxy ...
oc patch proxy cluster --type=merge -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'

#####################
aba_info "Adding mirror registry CA cert to registry config ..."

if [ -s regcreds/rootCA.pem ]; then
        ca_cert="$(cat regcreds/rootCA.pem | sed ':a;N;$!ba;s/\n/\\n/g')"
        aba_info "Using root CA file at $PWD/mirror/regcreds/rootCA.pem"
	kubectl patch configmap registry-config -n openshift-config --type='merge' -p '{"data":{"updateservice-registry":"'"$ca_cert"'"}}'
else
	aba_abort "No root CA file found at $PWD/regcreds/rootCA.pem.  Is the mirror registry available?"
fi

#####################
aba_info "Provisioning OpenShift Update Service Operator ..."

oc apply -f - <<END
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  annotations:
    openshift.io/node-selector: ""
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: update-service-operator-group
  namespace: $NAMESPACE
spec:
  targetNamespaces:
  - $NAMESPACE
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: update-service-subscription
  namespace: $NAMESPACE
spec:
  channel: v1
  installPlanApproval: "Automatic"
  source: "redhat-operators"
  sourceNamespace: "openshift-marketplace"
  name: "cincinnati-operator"
END

#####################
aba_info "Waiting for operator to be installed (this can take up to 3 minutes)..."

csv_cmd="oc get subscription -n $NAMESPACE update-service-subscription -o jsonpath='{.status.installedCSV}'"
CSV=$(eval $csv_cmd)
until [ "$CSV" ]
do
	echo -n .
	sleep 10
	CSV=$(oc get subscription -n $NAMESPACE update-service-subscription -o jsonpath='{.status.installedCSV}')
	CSV=$(eval $csv_cmd)
done

while ! oc get csv -n $NAMESPACE $CSV -o jsonpath='{.status.phase}' | grep Succeeded 
do
	echo -n .
	sleep 10
done

#####################
aba_info "Deploying OpenShift Update Service ..."

graph_image=$reg_host:$reg_port$reg_path/openshift/graph-image:latest
release_repo=$reg_host:$reg_port$reg_path/openshift/release-images

aba_debug graph_image=$graph_image
aba_debug release_repo=$release_repo

oc apply -f - <<END
apiVersion: updateservice.operator.openshift.io/v1
kind: UpdateService
metadata:
  name: $NAME
  namespace: $NAMESPACE
spec:
  graphDataImage: "$graph_image"
  releases: "$release_repo"
  replicas: 1
END

#####################
aba_info -n "Obtaining the policy engine route ... "

while sleep 1; do POLICY_ENGINE_GRAPH_URI="$(oc -n "${NAMESPACE}" get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph{"\n"}' updateservice "${NAME}")"; SCHEME="${POLICY_ENGINE_GRAPH_URI%%:*}"; if test "${SCHEME}" = http -o "${SCHEME}" = https; then break; fi; done

aba_info_ok $POLICY_ENGINE_GRAPH_URI

CH=$(kubectl get clusterversion version -o jsonpath='{.spec.channel}')
aba_debug CH=$CH

aba_info "Checking access to $POLICY_ENGINE_GRAPH_URI/?channel=$CH (this can take 1-2 minutes) ..."

while true; do HTTP_CODE="$(curl --cacert .openshift-ingress.cacert.pem --header Accept:application/json -s --output /dev/null --write-out "%{http_code}" "${POLICY_ENGINE_GRAPH_URI}?channel=$CH")"; if test "${HTTP_CODE}" -eq 200; then break; fi; echo -n .; sleep 10; done
echo_green Available # No aba_info_ok!

#####################
aba_info "Updating cluster version with $POLICY_ENGINE_GRAPH_URI ..."

PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"
oc patch clusterversion version -p $PATCH --type merge

aba_info_ok "Update Service configuration completed successfully!"
aba_info "Please wait about *10 MINUTES* for the OpenShift Console to show the 'Update Graph' under 'Administration -> Cluster Settings' ..."

