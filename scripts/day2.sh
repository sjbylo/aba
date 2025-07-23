#!/bin/bash -e
# Run some day 2 changes
# Set up cluster trust CA with the internal registry's Root CA
# Configure OperatorHub using the internal mirror registry. 
# Apply the imageContentSourcePolicy resource files that were created by oc-mirror (make sync/load)
## This script also solves the problem that multiple sync/save runs do not containing all ICSPs. See: https://github.com/openshift/oc-mirror/issues/597 
# For disconnected environments, disable online public catalog sources
# Install any CatalogSources
# Note: https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/registry/index#images-configuration-cas_configuring-registry-operator 

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!
	
echo_white "What this 'day2' script does:"
echo_white "- Add the internal mirror registry's Root CA to the cluster trust store."
echo_white "- Configure OperatorHub to integrate with the internal mirror registry."
echo_white "- Apply any/all imageContentSourcePolicy resource files under mirror/{save,sync}/oc-mirror-workspace that were created by oc-mirror (aba sync/load)."
echo_white "- For fully disconnected environments, disable online public catalog sources."
echo_white "- Install any CatalogSources found under mirror/{save,sync}/oc-mirror-workspace."
echo_white "- Apply any release image signatures found under mirror/{save,sync}/oc-mirror-workspace."
echo


echo For disconnected environments, disabling online public catalog sources
echo

# Check if the default catalog sources need to be disabled (e.g. air-gapped)
if [ ! "$int_connection" ]; then
	echo "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'"
	oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' && \
       		echo "Patched OperatorHub, disabled Red Hat default catalog sources"
else
	echo "Assuming internet connection (proxy) in use, not disabling default catalog sources"
fi


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
	try_cmd 5 5 15 "oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'"

	# Sometimes see the error 'error: the server doesn't have a resource type "imagestream"' ... so , need to check and wait...
	echo "Ensuring 'imagestream' resource is available!" 
	try_cmd 5 5 20 oc get imagestream 

	# The above workaround describes re-creating the is/oauth-proxy 
	if oc get imagestream -n openshift oauth-proxy -o yaml | grep -qi "unknown authority"; then
		try_cmd 5 5 15 oc delete imagestream -n openshift oauth-proxy

		echo Waiting for imagestream oauth-proxy in namespace openshift to be created.  This can take 2 to 3 minutes.

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
	echo_cyan "Registry trust bundle already added (cm registry-config -n openshift-config). Assuming workaround has already been applied or not necessary."
fi

############### v1 ##################
if [ "$oc_mirror_version" = "v1" ]; then
############### v1 ##################

	file_list=$(ls mirror/{sync,save}/oc-mirror-workspace 2>/dev/null || true)
	if [ ! "$file_list" ]; then
		echo
		echo_red "Missing oc-mirror meta-data (mirror/{save,sync}/oc-mirror-workspace* not be available). Please copy this directory from where it was created to this location and try again!" >&2
		echo
	fi

	echo
	echo "Applying any imageContentSourcePolicy resource files that were created by oc-mirror under mirror/{save,sync}/oc-mirror-workspace* (aba sync/load)"
	echo

	# If one should clash with an existing ICSP resource, change its name by incrementing the value (-x) and try to apply it again.
	# See this issue: https://github.com/openshift/oc-mirror/issues/597
	# "|| true" needed in case no "oc-mirror-workspace" dir exist (e.g. no mirror meta data available) 
	file_list=$(find mirror/{save,sync}/oc-mirror-workspace* -type f 2> /dev/null | grep /imageContentSourcePolicy.yaml$ || true)
	if [ "$file_list" ]; then
		for f in $file_list
		do
			echo "Running: oc create -f $f"
			oc create -f $f 2>/dev/null && continue   # If it can be created, move to the next file

			# If it can't be created....
			# If it's different, then apply the resource with a different name
			v=$(cat $f | grep "^  name: .*" | head -1 | cut -d- -f2)
			while ! oc diff -f $f > /dev/null
			do
				# oc-mirror creates resources with names xxx-0 fetch the digit after the '-' and increment.
				# head needed since sometimes the files have more than one resource!
				let v=$v+1
				###echo $v | grep -E "^[0-9]+$" || continue  # Check $v is an integer

				echo "Applying resource(s):" 
				grep -E -o 'name: [^-]+' $f

				# Adjust the name: in the file
				sed -i "s/^\(  name: [^-]*\)-[0-9]\{1,\}/\1-$v/g" $f
				echo "Running: oc create -f $f"
				oc create -f $f 2>/dev/null || true
			done
		done
	else
		echo_cyan "No imageContentSourcePolicy.yaml files found under 'mirror/{save,sync}/oc-mirror-workspace*' (no operators mirrored?)."
	fi
else

############### v2 ################## START

	# For oc-mirror v2
	# note for oc-mirror v2
	# resources/idms-oc-mirror.yaml
	# mirror/sync/working-dir/cluster-resources/itms-oc-mirror.yaml
	# ls mirror/{save,sync}/working-dir/cluster-resources/{idms,itms}*yaml

	latest_dir=$(ls -dt mirror/{save,sync} 2>/dev/null | head -1)  # One of these should exist!

	if [ "$latest_dir" ]; then
		for f in $(ls -t $latest_dir/working-dir/cluster-resources/{idms,itms}*yaml 2>/dev/null) 
		do
			echo oc apply -f $f
			oc apply -f $f
		done

		f=$(ls -t1 $latest_dir/working-dir/cluster-resources/cs-redhat-operator-index*yaml | head -1)
		echo "###########"
		[ -s "$f" ] && cat $f | sed "s/name: cs-redhat-operator-index.*/name: redhat-operators/g" 
		echo "###########"
		#oc delete CatalogSource redhat-operators  -n openshift-marketplace 2>/dev/null || true
		# FIXME: Can apply and need to delete?
		if [ -s "$f" ] && cat $f | sed "s/name: cs-redhat-operator-index.*/name: redhat-operators/g" | oc apply -f - 2>/dev/null; then
	
			echo "Patching registry display name: 'Private Catalog ($reg_host)' for CatalogSource redhat-operators"
			oc patch CatalogSource redhat-operators  -n openshift-marketplace --type merge -p '{"spec": {"displayName": "Private Catalog ('$reg_host')"}}'
	
			echo "Patching registry poll interval for CatalogSource redhat-operators"
			oc patch CatalogSource redhat-operators  -n openshift-marketplace --type merge -p '{"spec": {"updateStrategy": {"registryPoll": {"interval": "2m"}}}}'
			echo Pausing 30s ...
			sleep 30
		fi

		echo "Waiting for CatalogSource 'redhat-operators' to become 'ready' ..."
		i=2
		time while ! oc get catalogsources.operators.coreos.com  redhat-operators -n openshift-marketplace -o json | jq -r .status.connectionState.lastObservedState | grep -qi ^ready$
		do
			echo -n .
			sleep $i
			let i=$i+1
			[ $i -gt 40 ] && echo_red "Warning: Giving up waiting ..." >&2 && break
		done

		oc get catalogsources.operators.coreos.com  redhat-operators -n openshift-marketplace -o json | jq -r .status.connectionState.lastObservedState | grep -qi ^ready$ && \
			echo "The CatalogSource is 'ready'"

		sig_file=$latest_dir/working-dir/cluster-resources/signature-configmap.json
		echo "Applying signatures from: $sig_file ..."
		[ -s $sig_file ] && oc apply -f $sig_file
	else
		echo_red "Warning: missing directory $PWD/mirror/save and/or $PWD/mirror/sync" >&2
	fi

	exit 0
############### v2 ################## END
fi


echo
echo "Applying any CatalogSources resources found under mirror/{save,sync}/oc-mirror-workspace/results-*"
echo
file_list=$(find mirror/{save,sync}/oc-mirror-workspace/results-* -type f -name catalogSource*.yaml 2>/dev/null || true)
if [ "$file_list" ]; then
	cs_file=$(ls -tr $file_list | tail -1)
	##sed -i "s/name: cs-redhat-operator-index/name: redhat-operators/g" $cs_file  # Change to a better name
	echo Looking for latest CatalogSource file:
	echo "Running: oc apply -f $cs_file"

	##if oc create -f $cs_file 2>/dev/null; then
	if cat $cs_file | sed "s/name: cs-redhat-operator-index/name: redhat-operators/g" | oc apply -f - 2>/dev/null; then
		# Setting: displayName: Private Catalog (registry.example.com)
		echo "Patching registry display name: 'Private Catalog ($reg_host)' for CatalogSource redhat-operators"
		oc patch CatalogSource redhat-operators  -n openshift-marketplace --type merge -p '{"spec": {"displayName": "Private Catalog ('$reg_host')"}}'

		echo "Patching registry poll interval for CatalogSource redhat-operators"
		oc patch CatalogSource redhat-operators  -n openshift-marketplace --type merge -p '{"spec": {"updateStrategy": {"registryPoll": {"interval": "2m"}}}}'
		echo Pausing ...
		sleep 60
	else
		:
	fi

	echo "Waiting for CatalogSource 'redhat-operators' to become 'ready' ..."
	i=2
	time while ! oc get catalogsources.operators.coreos.com  redhat-operators -n openshift-marketplace -o json | jq -r .status.connectionState.lastObservedState | grep -qi ^ready$
	do
		echo -n .
		sleep $i
		let i=$i+1
		[ $i -gt 40 ] && echo_red "Warning: Giving up waiting ..." >&2 && break
	done

	oc get catalogsources.operators.coreos.com  redhat-operators -n openshift-marketplace -o json | jq -r .status.connectionState.lastObservedState | grep -qi ^ready$ && \
		echo "The CatalogSource is 'ready'"
	###echo "The CatalogSource is 'ready'"

	#### Force all default sources to be disabled, since we use the internal mirror.
	###echo "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'" 
	###oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' 

	# Now add any signatures
	echo "Applying any signature files under: mirror/{sync,save}/oc-mirror-workspace/results-*/release-signatures:"
	file_list=$(find mirror/{sync,save}/oc-mirror-workspace/results-*/release-signatures -type f -name signature*json 2>/dev/null || true)
	if [ "$file_list" ]; then
		for f in $file_list
		do
			echo Applying: $f
			oc apply -f $f 2>/dev/null
		done
	else
		echo_cyan "No release signatures found in mirror/{sync,save}/oc-mirror-workspace/results-*/release-signatures (no new OCP versions mirrored?)."
	fi
else
	echo
	echo_cyan "No Operator CatalogSources found under mirror/{save,sync}/oc-mirror-workspace (no operators mirrored?)."
	echo_cyan "Operator images can be loaded into the mirror registry first by a) editing the mirror/save/imageset-config-save.yaml file and b) running 'aba save/load'. See the README.md for more."
	echo
fi

# Note that if any operators fail to install after 600 seconds ... need to read this: https://access.redhat.com/solutions/6459071 

exit 0

