#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

#source <(normalize-aba-conf)
#source <(normalize-aba-conf)
source <(normalize-mirror-conf)

export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig
	
# Add registry CA to the cluster.  See workaround: https://access.redhat.com/solutions/5514331
# "Service Mesh Jaeger and Prometheus can't start in disconnected environment"
if [ -s regcreds/rootCA.pem ]; then
	echo "Adding the trust CA of the registry ($reg_host) ..."
	export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
	echo "Using root CA file at regcreds/rootCA.pem"

	# To fix https://access.redhat.com/solutions/5514331
	scripts/j2 templates/cm-additional-trust-bundle.j2 | oc apply -f -

	echo "Running: oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'"
	oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'

else	
	echo "Warning: No file regcreds/rootCA.pem.  Assuming mirror registry is using http."
fi

echo "############################"
# Try to apply the imageContentSourcePolicy resource files that were created by oc-mirror!
# If one should have the same name, change its name by incrementing the value (-x) and try to apply again.
for f in $(find mirror/s*/oc-* | grep /imageContentSourcePolicy.yaml$)
do
	echo Applying file $f
	oc create -f $f && continue   # If it can be created, move to the next file

	# If it can't be created....
	# If it's different, then apply a seperate resource with a different name
	while ! oc diff -f $f
	do
		# oc-mirror creates resources with names xxx-0 fetch the digit after the '-' and increment.
		# head needed since soemtimes the files have more than one resource!
		v=$(cat $f | grep "^  name: .*" | cut -d- -f2 | head -1)
		let v=$v+1
		echo $v | grep -E "^[0-9]+$" || continue  # Check $v is an integer

		echo "Applying resource(s):" 
		grep -E -o 'name: [^-]+' $f

		sed -i "s/^\(  name: [^-]*\)-[0-9]\{1,\}/\1-$v/g" $f
		oc create -f $f
	done
done
echo "############################"

# For disconnected environment, disable to online public catalog sources
ret=$(curl -ILsk --connect-timeout 10 -o /dev/null -w "%{http_code}\n" https://registry.redhat.io/ || true)
[ "$ret" != "200" ] && \
	echo "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'" && \
	oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' && \
       		echo "Patched OperatorHub, disabled Red Hat public catalog sources"

# Install any CatalogSources
list=$(find mirror/sync/oc-mirror-workspace/results-* mirror/save/oc-mirror-workspace/results-* -name catalogSource*.yaml 2>/dev/null || true)
if [ "$list" ]; then
	cs_file=$(ls -tr $list | tail -1)
	echo "Running: oc apply -f $cs_file"
	oc apply -f $cs_file
fi

# Note that if any operators fail to install after 600 seconds ... need to read this: https://access.redhat.com/solutions/6459071 

echo "Waiting for CatalogSource to become 'ready' ..."
i=5
time while ! oc get catalogsources.operators.coreos.com  cs-redhat-operator-index -n openshift-marketplace -o json | jq -r .status.connectionState.lastObservedState | grep -i ^ready$
do
	echo Sleeping $i
	sleep $i
	let i=$i+3
	[ $i -gt 20 ] && echo "Giving up waiting ..." && break
done

