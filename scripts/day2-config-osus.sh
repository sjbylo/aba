#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

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
echo "Logging into cluster ..."
. <(aba shell)

#####################
echo -n "Adding cluster ingress CA cert to the CA trust bundle ... "

cert="$(oc get secret -n openshift-ingress-operator router-ca -o jsonpath="{.data['tls\.crt']}"| base64 -d)"
ingress_cert="$(echo "$cert" | sed ':a;N;$!ba;s/\n/\\n/g')"
ca_bundle_crt=$(oc get cm user-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' | sed ':a;N;$!ba;s/\n/\\n/g')

# Check if already added
tmp_line2=$(echo "$cert" | head -2 | tail -1)

if echo "$ingress_cert" | grep -q "$tmp_line2"; then
	echo_cyan "already added"
else
	ca_bundle_crt="$ca_bundle_crt\n$ingress_cert"
	oc patch cm user-ca-bundle -n openshift-config --type='merge' -p '{"data":{"ca-bundle.crt":"'"$ca_bundle_crt"'"}}'
	echo_green added
fi

oc patch proxy cluster --type=merge -p '{"spec":{"trustedCA":{"name":"user-ca-bundle"}}}'

#####################
echo "Adding mirror registry CA cert to config ..."

if [ -s regcreds/rootCA.pem ]; then
        ca_cert="$(cat regcreds/rootCA.pem | sed ':a;N;$!ba;s/\n/\\n/g')"
        echo "Using root CA file at $PWD/mirror/regcreds/rootCA.pem"
	kubectl patch configmap registry-config -n openshift-config --type='merge' -p '{"data":{"updateservice-registry":"'"$ca_cert"'"}}'
else
	echo_red "No root CA file found at $PWD/regcreds/rootCA.pem.  Is the mirror registry available?" >&2

	exit 1
fi

#####################
echo "Provisioning OpenShift Update Service Operator ..."

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
echo "Waiting for operator to be installed ..."

csv_cmd="oc get subscription -n $NAMESPACE update-service-subscription -o jsonpath='{.status.installedCSV}'"
CSV=$(eval $csv_cmd)
until [ "$CSV" ]
do
	echo -n .
	sleep 10
	CSV=$(oc get subscription -n $NAMESPACE update-service-subscription -o jsonpath='{.status.installedCSV}')
	CSV=$(eval $csv_cmd)
done

#echo CSV=$CSV

while ! oc get csv -n $NAMESPACE $CSV -o jsonpath='{.status.phase}' | grep Succeeded 
do
	echo -n .
	sleep 10
done

#####################
echo "Deploying OpenShift Update Service ..."

graph_image=$reg_host:$reg_port/$reg_path/openshift/graph-image:latest
release_repo=$reg_host:$reg_port/$reg_path/openshift/release-images

#echo graph_image=$graph_image
#echo release_repo=$release_repo

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
echo -n "Obtaining the policy engine route ... "

while sleep 1; do POLICY_ENGINE_GRAPH_URI="$(oc -n "${NAMESPACE}" get -o jsonpath='{.status.policyEngineURI}/api/upgrades_info/v1/graph{"\n"}' updateservice "${NAME}")"; SCHEME="${POLICY_ENGINE_GRAPH_URI%%:*}"; if test "${SCHEME}" = http -o "${SCHEME}" = https; then break; fi; done

echo_green $POLICY_ENGINE_GRAPH_URI

CH=$(kubectl get clusterversion version -o jsonpath='{.spec.channel}')
#echo CH=$CH

echo -n "Checking access to $POLICY_ENGINE_GRAPH_URI/?channel=$CH ... "

while true; do HTTP_CODE="$(curl -k --header Accept:application/json -s --output /dev/null --write-out "%{http_code}" "${POLICY_ENGINE_GRAPH_URI}?channel=$CH")"; if test "${HTTP_CODE}" -eq 200; then break; fi; echo -n .; sleep 10; done; echo_green available

#####################
echo "Updating cluster version with $POLICY_ENGINE_GRAPH_URI ..."

PATCH="{\"spec\":{\"upstream\":\"${POLICY_ENGINE_GRAPH_URI}\"}}"
oc patch clusterversion version -p $PATCH --type merge

echo_green "Update Service configuration completed successfully!"
echo_cyan "Please wait *15-20 MINUTES* for the Administration Console to show the 'Update status' ..."

