#!/bin/bash -e
# Run some day 2 changes
# Set up cluster trust CA with the internal registry's Root CA
# Configure OperatorHub using the internal mirror registry. 
# Apply the imageContentSourcePolicy resource files that were created by oc-mirror (make sync/load)
## This script also solves the problem that multiple sync/save runs do not containing all ICSPs. See: https://github.com/openshift/oc-mirror/issues/597 
# For disconnected environments, disable online public catalog sources
# Install any CatalogSources

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-mirror-conf)

export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig
	
echo_white "What this 'day2' script does:"
echo_white "- Add the internal mirror registry's Root CA to the cluster trust store."
echo_white "- Configure OperatorHub to integrate with the internal mirror registry."
echo_white "- Apply any/all imageContentSourcePolicy resource files that were created by oc-mirror (make sync/load)."
echo_white "- For fully disconnected environments, disable online public catalog sources."
echo_white "- Install any CatalogSources."
echo_white "- Apply any signatures."

echo
echo_white "Adding workaround for 'Imagestream openshift/oauth-proxy shows x509 certificate signed by unknown authority error while accessing mirror registry'"
echo_white "and 'Image pull backoff for 'registry.redhat.io/openshift4/ose-oauth-proxy:<tag> image'."
echo_white "Adding registry CA to the cluster.  See workaround: https://access.redhat.com/solutions/5514331 for more."
echo_white "This CA problem might affect other applications in the cluster."
echo

cm_existing=$(oc get cm registry-config -n openshift-config || true)
if [ -s regcreds/rootCA.pem -a ! "$cm_existing" ]; then
	echo "Adding the trust CA of the registry ($reg_host) ..."
	echo "To fix https://access.redhat.com/solutions/5514331 and solve 'image pull errors in disconnected environment'."
	export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
	echo "Using root CA file at regcreds/rootCA.pem"

	scripts/j2 templates/cm-additional-trust-bundle.j2 | oc apply -f -

	echo "Running: oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'"
	try_cmd 5 5 10 "oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'"

	# Sometimes see the error 'error: the server doesn't have a resource type "imagestream"' ... so , need to check and wait...
	echo "Ensuring 'imagestream' resource is available!" 
	try_cmd 5 5 20 oc get imagestream 

	# The above workaround describes re-creating the is/oauth-proxy 
	if oc get imagestream -n openshift oauth-proxy -o yaml | grep -qi "unknown authority"; then
		try_cmd 5 5 10 oc delete imagestream -n openshift oauth-proxy

		echo Waiting for imagestream oauth-proxy in namespace openshift to be created.  This can take 2-3 minutes.

		sleep 30

		# Assume once it's re-created then it's working
		while ! oc get imagestream -n openshift oauth-proxy 2>/dev/null
		do
			sleep 10
		done
	else
		echo "'unknown authority' not found in imagestream/oauth-proxy -n openshift.  Assuming already fixed."
	fi
	# Note, might still need to restart operators, e.g. 'oc delete pod -l name=jaeger-operator -n openshift-distributed-tracing'
else	
	echo_red "Registry trust bundle already added. Assuming workaround has already been applied."
	### echo_red "         No cert file regcreds/rootCA.pem found (no mirror available?)."  # This is wrong statement
fi

#echo "############################"

echo
echo "Applying the imageContentSourcePolicy resource files that were created by oc-mirror (make sync/load)"
echo

# If one should clash with an existing ICSP resource, change its name by incrementing the value (-x) and try to apply it again.
# See this issue: https://github.com/openshift/oc-mirror/issues/597
# "|| true" needed in case no "oc-mirror-workspace" dir exist (e.g. no mirror meta data evailable) 
file_list=$(find mirror/{save,sync}/oc-mirror-workspace* -type f 2> /dev/null | grep /imageContentSourcePolicy.yaml$ || true)
if [ "$file_list" ]; then
	for f in $file_list
	do
		echo "Running: oc create -f $f"
		oc create -f $f && continue   # If it can be created, move to the next file

		# If it can't be created....
		# If it's different, then apply the resource with a different name
		v=$(cat $f | grep "^  name: .*" | head -1 | cut -d- -f2)
		while ! oc diff -f $f > /dev/null
		do
			# oc-mirror creates resources with names xxx-0 fetch the digit after the '-' and increment.
			# head needed since soemtimes the files have more than one resource!
			let v=$v+1
			###echo $v | grep -E "^[0-9]+$" || continue  # Check $v is an integer

			echo "Applying resource(s):" 
			grep -E -o 'name: [^-]+' $f

			# Adjust the name: in the file
			sed -i "s/^\(  name: [^-]*\)-[0-9]\{1,\}/\1-$v/g" $f
			echo "Running: oc create -f $f"
			oc create -f $f || true
		done
	done
else
	echo_magenta "No imageContentSourcePolicy.yaml files found under 'mirror/{save,sync}/oc-mirror-workspace*' (no mirror available?)"
fi

#echo "############################"

echo
echo For disconnected environments, disable online public catalog sources
echo

ret=$(curl --retry 3 -ILsk --connect-timeout 10 -o /dev/null -w "%{http_code}\n" https://registry.redhat.io/ || true)
if [ "$ret" != "200" ]; then
	echo "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'" && \
	oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' && \
       	echo "Patched OperatorHub, disabled Red Hat public catalog sources"

else
	echo "Access to the Internet from this host is working, not disabling public catalog sources"
fi

#echo "############################"

echo
echo Install any CatalogSources
echo
file_list=$(find mirror/{save,sync}/oc-mirror-workspace/results-* -type f -name catalogSource*.yaml 2>/dev/null || true)
if [ "$file_list" ]; then
	cs_file=$(ls -tr $file_list | tail -1)
	echo Looking for latest CatalogSource file:
	echo "Running: oc apply -f $cs_file"

	if oc create -f $cs_file; then
		# Setting: displayName: Private Catalog (registry.example.com)
		echo "Patching registry display name: 'Private Catalog ($reg_host)' for CatalogSource cs-redhat-operator-index"
		oc patch CatalogSource cs-redhat-operator-index  -n openshift-marketplace --type merge -p '{"spec": {"displayName": "Private Catalog ('$reg_host')"}}'

		echo "Patching registry poll interval for CatalogSource cs-redhat-operator-index"
		oc patch CatalogSource cs-redhat-operator-index  -n openshift-marketplace --type merge -p '{"spec": {"updateStrategy": {"registryPoll": {"interval": "2m"}}}}'
		echo Pausing ...
		sleep 60
	else
		:
	fi

	echo "Waiting for CatalogSource 'cs-redhat-operator-index' to become 'ready' ..."
	i=2
	time while ! oc get catalogsources.operators.coreos.com  cs-redhat-operator-index -n openshift-marketplace -o json | jq -r .status.connectionState.lastObservedState | grep -qi ^ready$
	do
		echo -n .
		sleep $i
		let i=$i+1
		[ $i -gt 25 ] && echo_red "Warning: Giving up waiting ..." && break
	done

	echo "The CatalogSource is 'ready'"

	# Force all default sources to be disabled, since we use the internal mirror.
	echo "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'" 
	oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' 
else
	echo_magenta "No Operator CatalogSources found under mirror/{save,sync}/oc-mirror-workspace. (no mirror available?)"
	echo_magenta "Operator images would need to be loaded into the mirror registry first by a) editing the mirror/save/imageset-config-save.yaml file and b) running 'make save/load'. See the README for more."
fi

# Note that if any operators fail to install after 600 seconds ... need to read this: https://access.redhat.com/solutions/6459071 

# Now add any signatures
echo "Applying any signatures:"
file_list=$(find mirror/{sync,save}/oc-mirror-workspace/results-* -type f -name catalogSource*.yaml 2>/dev/null || true)
if [ "$file_list" ]; then
	for f in $file_list
	do
		oc apply -f $f
		echo $f
	done
else
	echo_magenta "No Signatures available in mirror/{sync,save}/oc-mirror-workspace/results-* (no mirror available?)"
fi

exit 0

