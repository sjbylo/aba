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
#set +o pipefail

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

echo "Accessing the cluster ..."

if ! oc whoami --request-timeout='20s' >/dev/null 2>/dev/null; then
	[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!
	if ! oc whoami; then
		echo_red "Unable to access the cluster using KUBECONFIG=$KUBECONFIG" >&2

		. <(aba login)

		if ! oc whoami --request-timeout='20s' >/dev/null; then
			echo_red "Unable to log into the cluster" >&2
			exit 1
		fi
	fi
fi

echo_white "What this 'day2' script does:"
echo_white "- Add the internal mirror registry's Root CA to the cluster trust store."
echo_white "- Configure OperatorHub to integrate with the internal mirror registry."
echo_white "- Apply any/all idms/itms resource files under working-dir/cluster-resources that were created by oc-mirror (aba -d mirror sync/load)."
echo_white "- For fully disconnected environments, disable online public catalog sources."
echo_white "- Install any CatalogSources found under working-dir/cluster-resources."
echo_white "- Apply any release image signatures found under working-dir/cluster-resources."
echo


echo_green For disconnected environments, disabling online public catalog sources

# Check if the default catalog sources need to be disabled (e.g. air-gapped)
if [ ! "$int_connection" ]; then
	echo "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'"
	oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' && \
       		echo "Patched OperatorHub, disabled Red Hat default catalog sources"
else
	echo "Assuming internet connection (e.g. proxy) in use, not disabling default catalog sources"
fi


echo_white "Adding workaround for 'Imagestream openshift/oauth-proxy shows x509 certificate signed by unknown authority error while accessing mirror registry'"
echo_white "and 'Image pull backoff for 'registry.redhat.io/openshift4/ose-oauth-proxy:<tag> image'."
echo_white "Adding registry CA to the cluster.  See workaround: https://access.redhat.com/solutions/5514331 for more."
echo
cm_existing=$(oc get cm registry-config -n openshift-config || true)
# If installed from mirror reg. and trust CA missing (cm/registry-config) does not exist...
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

####################################
# Only oc-mirror v2 is supported now

# For oc-mirror v2
# Note for oc-mirror v2:
# resources/idms-oc-mirror.yaml
# mirror/sync/working-dir/cluster-resources/itms-oc-mirror.yaml
# ls mirror/{save,sync}/working-dir/cluster-resources/{idms,itms}*yaml

latest_working_dir=$(ls -dt mirror/{save,sync}/working-dir 2>/dev/null | head -1 || true)  # One of these should exist!
# FIXME: Since v2, use just one dir, e.g. "aba/mirror/data" 

ns=openshift-marketplace

if [ "$latest_working_dir" ]; then
	# Apply any idms/itms files created by oc-mirror v2
	for f in $(ls $latest_working_dir/cluster-resources/{idms,itms}*yaml 2>/dev/null || true) 
	do
		if [ -s $f ]; then
			echo oc apply -f $f
			oc apply -f $f
		else
			echo_red "Warning: no such file: $f" >&2
		fi
	done

	# Apply any CatalogSource files created by oc-mirror v2

	##f=$(ls -t1 $latest_working_dir/cluster-resources/cs-redhat-operator-index*yaml | head -1)
	cs_file_list=$(ls $latest_working_dir/cluster-resources/cs-*-index*yaml 2>/dev/null || true)

	[ ! "$cs_file_list" ] && echo_red "Warning: No CatalogSource files in $latest_working_dir/cluster-resources to process" >&2

	for f in $cs_file_list
	do
		if [ ! -s "$f" ]; then
			echo_red "Error: CatalogSource file does not exist: [$f]" >&2
			
			continue
		fi

		# Fetch the catalog (index) names and adjust them to suit the standard names
		# Extract the base catalog name and normalize it
		# Example filename: cs-redhat-operator-index.yaml
		cs_name=${f#*cs-}            # remove everything up to 'cs-'
		cs_name=${cs_name%-index*}    # remove everything from '-index' onward

		# Normalize standard names
		case "$cs_name" in
    			redhat-operator)	cs_name="redhat-operators" ;;
    			certified-operator)	cs_name="certified-operators" ;;
    			community-operator)	cs_name="community-operators" ;;
		esac

		# FIXME: delete
		#cs_name=$(echo $f | sed "s/.*cs-\(.*\)-index.*/\1/g")
		#cs_name=$(echo $cs_name | \
			#sed \
				#-e "s/^redhat-operator$/redhat-operators/g" \
				#-e "s/^certified-operator$/certified-operators/g" \
				#-e "s/^community-operator$/community-operators/g" \
			#)

		if [ ! "$cs_name" ]; then
			echo_red "Error: Cannot parse CatalogSource name: [$f]" >&2

			continue
		fi

		echo Applying CatalogSource: $cs_name
	       	cat $f | sed "s/name: cs-.*-index.*/name: $cs_name/g" | oc apply -f - # 2>/dev/null

		echo "Patching CatalogSource display name for $cs_name: $cs_name ($reg_host)"
		oc patch CatalogSource $cs_name  -n $ns --type merge -p '{"spec": {"displayName": "'$cs_name' ('$reg_host')"}}'

		echo "Patching CatalogSource poll interval for $cs_name to 2m"
		oc patch CatalogSource $cs_name  -n $ns --type merge -p '{"spec": {"updateStrategy": {"registryPoll": {"interval": "2m"}}}}'

		wait_for_cs=true

		# Start a sub-process to wait for CatalogSource 'ready'
		( 
			sleep 1

			until oc -n "$ns" get catalogsource "$cs_name" >/dev/null; do sleep 1; done

			for _ in {1..60}; do
				state=$(oc -n "$ns" get catalogsource "$cs_name" -o jsonpath='{.status.connectionState.lastObservedState}')

				if [ "$state" = "READY" ]; then
					echo "CatalogSource $cs_name is ready!"

					break
				fi
				[ "$state" ] && echo "Waiting for CatalogSource $cs_name... (current state: $state)"

				sleep 5
			done
		) &
	done

	# Wait for all sub-processes
	[ "$wait_for_cs" ] && wait

	sig_file=$latest_working_dir/cluster-resources/signature-configmap.json
	if [ -s $sig_file ]; then
		echo "Applying signatures from: $sig_file ..."
		oc apply -f $sig_file
	else
		echo_white "No Signature files found in $latest_working_dir/cluster-resources" >&2
	fi
else
	# FIXME: Only show warning IF the mirror has been used for this cluster
	echo_red "Warning: missing directory $PWD/mirror/save/working-dir and/or $PWD/mirror/sync/working-dir" >&2
fi

# Note that if any operators fail to install after 600 seconds ... need to read this: https://access.redhat.com/solutions/6459071 

exit 0

