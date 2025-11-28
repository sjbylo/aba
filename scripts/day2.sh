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

aba_debug "Starting: $0 $*"



umask 077

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

aba_info "Accessing the cluster ..."

if ! oc whoami --request-timeout='20s' >/dev/null 2>/dev/null; then
	[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!
	if ! oc whoami; then
		aba_warning "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

		. <(aba login)

		if ! oc whoami --request-timeout='20s' >/dev/null; then
			aba_abort "Unable to log into the cluster" 
		fi
	fi
fi

aba_info "What this 'day2' script does:"
aba_info "- Add the internal mirror registry's Root CA to the cluster trust store."
aba_info "- Configure OperatorHub to integrate with the internal mirror registry."
aba_info "- Apply any/all idms/itms resource files under aba/mirror/save/working-dir/cluster-resources that were created by oc-mirror (aba -d mirror sync/load)."
aba_info "- For fully disconnected environments, disable online public catalog sources."
aba_info "- Install any CatalogSources found under working-dir/cluster-resources."
aba_info "- Apply any release image signatures found under working-dir/cluster-resources."
echo


aba_info_ok For disconnected environments, disabling online public catalog sources

# Check if the default catalog sources need to be disabled (e.g. air-gapped)
if [ ! "$int_connection" ]; then
	aba_info "Running: oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'"
	oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' && \
       		aba_info "Patched OperatorHub, disabled Red Hat default catalog sources"
else
	aba_info "Assuming internet connection (e.g. proxy) in use, not disabling default catalog sources"
fi


aba_info "Adding workaround for 'Imagestream openshift/oauth-proxy shows x509 certificate signed by unknown authority error while accessing mirror registry'"
aba_info "and 'Image pull backoff for 'registry.redhat.io/openshift4/ose-oauth-proxy:<tag> image'."
aba_info "Adding registry CA to the cluster.  See workaround: https://access.redhat.com/solutions/5514331 for more."
echo
cm_existing=$(oc get cm registry-config -n openshift-config || true)
# If installed from mirror reg. and trust CA missing (cm/registry-config) does not exist...
if [ -s regcreds/rootCA.pem -a ! "$cm_existing" ]; then
	aba_info "Adding the trust CA of the registry ($reg_host) ..."
	aba_info "To fix https://access.redhat.com/solutions/5514331 and solve 'image pull errors in disconnected environment'."
	export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
	aba_info "Using root CA file at regcreds/rootCA.pem"

	scripts/j2 templates/cm-additional-trust-bundle.j2 | oc apply -f -

	aba_info "Running: oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'"
	try_cmd 5 5 15 "oc patch image.config.openshift.io cluster --type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'"

	# Sometimes see: 'error: the server doesn't have a resource type "imagestream"' ... so, need to check and wait! ...
	aba_info "Ensuring 'imagestream' resource is available!" 
	try_cmd 5 5 20 oc get imagestream 

	# The above workaround describes re-creating the is/oauth-proxy 
	if oc get imagestream -n openshift oauth-proxy -o yaml | grep -qi "unknown authority"; then
		try_cmd 5 5 15 oc delete imagestream -n openshift oauth-proxy

		echo_red Waiting for imagestream oauth-proxy in namespace openshift to be created.  This can take 2 to 3 minutes.

		sleep 30

		# Assume once it's re-created then it's working
		while ! oc get imagestream -n openshift oauth-proxy 2>/dev/null
		do
			sleep 10
		done
	else
		aba_info "'unknown authority' not found in imagestream/oauth-proxy -n openshift.  Assuming already fixed."
	fi
	# Note, might still need to restart operators, e.g. 'oc delete pod -l name=jaeger-operator -n openshift-distributed-tracing'
else	
	aba_info "Registry trust bundle already added (cm registry-config -n openshift-config). Assuming workaround has already been applied or not necessary."
fi

####################################
# Only oc-mirror v2 is supported now
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
			aba_info oc apply -f $f
			oc apply -f $f
		else
			aba_warning "no such file: $f"
		fi
	done

	# Apply any CatalogSource files created by oc-mirror v2

	##f=$(ls -t1 $latest_working_dir/cluster-resources/cs-redhat-operator-index*yaml | head -1)
	cs_file_list=$(ls $latest_working_dir/cluster-resources/cs-*-index*yaml 2>/dev/null || true)

	[ ! "$cs_file_list" ] && \
		aba_warning -p IMPORANT \
			"No CatalogSource files found under $latest_working_dir/cluster-resources" \
			"This usually means that Aba has not yet pushed any operator images to your mirror registry." \
			"If your mirror registry was populated with images separately, you will need to create and apply your own CatalogSources."

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

		if [ ! "$cs_name" ]; then
			echo_red "Error: Cannot parse CatalogSource name: [$f]" >&2

			continue
		fi

		aba_info Applying CatalogSource: $cs_name
	       	cat $f | sed "s/name: cs-.*-index.*/name: $cs_name/g" | oc apply -f - # 2>/dev/null

		aba_info "Patching CatalogSource display name for $cs_name: $cs_name ($reg_host)"
		oc patch CatalogSource $cs_name  -n $ns --type merge -p '{"spec": {"displayName": "'$cs_name' ('$reg_host')"}}'

		aba_info "Patching CatalogSource poll interval for $cs_name to 2m"
		oc patch CatalogSource $cs_name  -n $ns --type merge -p '{"spec": {"updateStrategy": {"registryPoll": {"interval": "2m"}}}}'

		wait_for_cs=true

		# Start a sub-process to wait for CatalogSource 'ready'
		( 
			sleep 1

			until oc -n "$ns" get catalogsource "$cs_name" >/dev/null; do sleep 1; done

			#aba_info "Waiting for CatalogSource $cs_name to become 'ready' ... (note that a state of 'TRANSIENT_FAILURE' usually resolves itself within a few moments!)"
			aba_info "Waiting for CatalogSource $cs_name to become 'ready' ... "

			for _ in {1..80}; do
				state=$(oc -n "$ns" get catalogsource "$cs_name" -o jsonpath='{.status.connectionState.lastObservedState}')

				if [ "$state" = "READY" ]; then
					aba_info "CatalogSource $cs_name is ready!"

					exit 0  # exit the process
				fi
				[ "$state" ] && aba_info "$cs_name state: $state (working on it!)"

				sleep 5
			done

			aba_abort "catalog source $cs_name failed to become 'ready'.  Ensure the cluster is stable and try again."
		) &
	done

	# Wait for all sub-processes
	[ "$wait_for_cs" ] && wait

	sig_file=$latest_working_dir/cluster-resources/signature-configmap.json
	if [ -s $sig_file ]; then
		aba_info "Applying signatures from: $sig_file ..."
		oc apply -f $sig_file
	else
		aba_info "No Signature files found in $latest_working_dir/cluster-resources" >&2
	fi
else
	# FIXME: Only show warning IF the mirror has been used for this cluster
	aba_warning "missing directory $PWD/mirror/save/working-dir and/or $PWD/mirror/sync/working-dir"
fi

# Note that if any operators fail to install after 600 seconds ... need to read this: https://access.redhat.com/solutions/6459071 

exit 0

