#!/bin/bash -e
# Run some day 2 changes
# Set up cluster trust CA with the internal registry's Root CA
# Configure OperatorHub using the internal mirror registry.
# Apply IDMS/ITMS resource files created by oc-mirror v2 (aba -d mirror sync or load)
# For disconnected environments, disable online public catalog sources
# Install any CatalogSources
# Apply any user-provided custom manifests from day2-custom-manifests/ in cluster folder
# Note: https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/registry/index#images-configuration-cas_configuring-registry-operator

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

umask 077

source <(normalize-aba-conf)
source <(normalize-cluster-conf)  # used to check int_connection value
export regcreds_dir=$HOME/.aba/mirror/$mirror_name
source <(normalize-mirror-conf)

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

# Stop processing (CatalogSources and Signatures etc) if this cluster is a connected cluster!
if [ "$int_connection" ]; then
	aba_info "This cluster connects directly to the internet (int_connection=$int_connection)."
	aba_info "OperatorHub is already configured to pull from public registries — no mirror integration needed."

	exit 0
fi

aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc

aba_info "Accessing the cluster ..."

aba_debug "Running: oc whoami --request-timeout=20s"
if ! oc whoami --request-timeout='20s' >/dev/null 2>/dev/null; then
	[ ! "$KUBECONFIG" ] && [ -s iso-agent-based/auth/kubeconfig ] && export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig # Can also apply this script to non-aba clusters!
	aba_debug "Running: oc whoami (with KUBECONFIG=$KUBECONFIG)"
	if ! oc whoami >/dev/null; then
		aba_warning "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

		. <(aba login)

		aba_debug "Running: oc whoami --request-timeout=20s (after login)"
		if ! oc whoami --request-timeout='20s' >/dev/null; then
			aba_abort "Unable to log into the cluster" 
		fi
	fi
fi

# Gate: ensure the cluster install completed (or let the user override)
if [ ! -f .install-complete ]; then
	if cluster_is_ready; then
		aba_info "Cluster is ready but .install-complete marker is missing — creating it now."
		touch .install-complete
		# Run monitor-install to externalize state (auth, backups) if not yet done
		if [ ! -L clusterstate ]; then
			aba_info "Externalizing cluster state ..."
			scripts/monitor-install.sh || true
		fi
	else
		aba_warning "The cluster install has not been finalized (aba install / aba mon has not completed)."
		ask "The cluster has not been finalized, continue anyway" || exit 1
	fi
fi

warn_if_cluster_unstable

aba_info "What this 'day2' script does:"
aba_info "- Add the internal mirror registry's Root CA to the cluster trust store."
aba_info "- Configure OperatorHub to integrate with the internal mirror registry."
aba_info "- Apply any/all idms/itms resource files under aba/mirror/data/working-dir/cluster-resources that were created by oc-mirror (aba -d mirror sync or load)."
aba_info "- For fully disconnected environments, disable online public catalog sources."
aba_info "- Install any CatalogSources found under working-dir/cluster-resources."
aba_info "- Apply any release image signatures found under working-dir/cluster-resources."
aba_info "- Apply any user-provided custom manifests from day2-custom-manifests/ directory."
echo


# Check if the default catalog sources need to be disabled (e.g. air-gapped)
if [ ! "$int_connection" ]; then
	aba_debug "Running: oc patch OperatorHub cluster --type json (disable default sources)"
	oc patch OperatorHub cluster --type json \
		-p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]' >/dev/null
	aba_info "Disabled default catalog sources (disconnected mode)"
else
	aba_info "Assuming internet connection (e.g. proxy) in use, not disabling default catalog sources"
fi


# Workaround: https://access.redhat.com/solutions/5514331
# Fixes 'Imagestream openshift/oauth-proxy x509 certificate signed by unknown authority'
aba_info "Adding mirror registry CA to cluster trust store"
aba_debug "Running: oc get cm registry-config -n openshift-config"
cm_existing=$(oc get cm registry-config -n openshift-config 2>/dev/null || true)
# If installed from mirror reg. and trust CA missing (cm/registry-config) does not exist...
if [ -s "$regcreds_dir/rootCA.pem" -a ! "$cm_existing" ]; then
	aba_info "Adding the trust CA of the registry ($reg_host) ..."
	export additional_trust_bundle=$(cat "$regcreds_dir/rootCA.pem")
	aba_info "Using root CA file at $regcreds_dir/rootCA.pem"

	aba_debug "Running: scripts/j2 ... | oc apply -f - (trust bundle configmap)"
	scripts/j2 templates/cm-additional-trust-bundle.j2 | oc apply -f -

	_day2_patch_additional_ca() {
		aba_debug "Running: oc patch image.config.openshift.io cluster (additionalTrustedCA)"
		oc patch image.config.openshift.io cluster \
			--type='json' \
			-p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]' \
			>/dev/null 2>&1
	}

	if ! aba_wait_show "Patching cluster trust CA" 5 180 _day2_patch_additional_ca; then
		aba_abort "Timed out patching cluster trust CA (3 min)"
	fi

	_day2_imagestream_available() {
		aba_debug "Running: oc get imagestream"
		oc get imagestream >/dev/null 2>&1
	}

	if ! aba_wait_show "Waiting for imagestream API" 5 180 _day2_imagestream_available; then
		aba_abort "Timed out waiting for imagestream API (3 min)"
	fi

	# The above workaround describes re-creating the is/oauth-proxy 
	aba_debug "Running: oc get imagestream -n openshift oauth-proxy -o yaml"
	if oc get imagestream -n openshift oauth-proxy -o yaml | grep -qi "unknown authority"; then
		aba_info "'Unknown authority' found in imagestream/oauth-proxy in namespace openshift."
		aba_debug "Running: oc delete imagestream -n openshift oauth-proxy"
		oc delete imagestream -n openshift oauth-proxy >/dev/null 2>&1 || true

		_day2_oauth_proxy_recreated() {
			aba_debug "Running: oc get imagestream -n openshift oauth-proxy"
			oc get imagestream -n openshift oauth-proxy >/dev/null 2>&1
		}

		if ! aba_wait_show "Waiting for oauth-proxy imagestream recreation" 10 360 _day2_oauth_proxy_recreated; then
			aba_abort "Timed out waiting for oauth-proxy imagestream recreation (6 min)"
		fi
	else
		aba_info "'Unknown authority' not found in imagestream/oauth-proxy -n openshift.  Assuming already fixed."
	fi
	# Note, might still need to restart operators, e.g. 'oc delete pod -l name=jaeger-operator -n openshift-distributed-tracing'
else
	aba_info "Registry trust bundle already added (cm registry-config -n openshift-config). Assuming workaround has already been applied or not necessary."
fi

apply_custom_manifests() {
	# Apply user-provided custom manifests from day2-custom-manifests/ in cluster folder
	# This function is called after signature application to allow users to deploy
	# additional resources (e.g., StorageClass, NetworkPolicy, custom operators, etc.)

	local custom_manifest_dir="$PWD/day2-custom-manifests"

	# Check if day2-custom-manifests directory exists
	if [ ! -d "$custom_manifest_dir" ]; then
		aba_info "No custom manifests directory found at $custom_manifest_dir (this is optional)"
		return 0
	fi

	# Recursively discover .yaml/.yml files; sort ensures deterministic alphabetical
	# order so users can control ordering via directory/file naming (e.g. 00-ns/, 01-app/)
	local found_files
	found_files="$(find "$custom_manifest_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"

	# Count matched files; grep -c exits 1 on zero matches, so suppress that with || true
	local file_count
	file_count="$(printf '%s\n' "$found_files" | grep -c . || true)"

	# If no files found, inform user and return
	if [ "$file_count" -eq 0 ]; then
		aba_debug "No custom manifest files (.yaml/.yml) found in $custom_manifest_dir"
		return 0
	fi

	# Show what we're doing
	aba_info "Found $file_count custom manifest file(s) in $custom_manifest_dir"
	aba_info "Applying user-provided custom manifests ..."

	# Track successes and failures
	local success_count=0
	local failure_count=0

	# Apply each file; while+read handles filenames that contain spaces
	while IFS= read -r manifest_file; do
		# Show path relative to the custom manifests directory for cleaner output
		local rel_path="${manifest_file#"$custom_manifest_dir"/}"

		# Verify file is not empty
		if [ ! -s "$manifest_file" ]; then
			aba_warning "Skipping empty file: $rel_path"
			failure_count=$((failure_count + 1))
			continue
		fi

		# Apply the manifest
		aba_info "oc apply -f $rel_path"
		aba_debug "Running: oc apply -f $manifest_file"
		if oc apply -f "$manifest_file"; then
			success_count=$((success_count + 1))
		else
			aba_warning "Failed to apply custom manifest: $rel_path (continuing with other files)"
			failure_count=$((failure_count + 1))
		fi
	done <<< "$found_files"

	# Show summary
	if [ $success_count -gt 0 ]; then
		aba_info_ok "Successfully applied $success_count custom manifest(s)"
	fi

	if [ $failure_count -gt 0 ]; then
		aba_warning "Failed to apply $failure_count custom manifest(s) - see warnings above"
	fi

	return 0  # Always return success - failures are non-fatal
}


####################################
# Only oc-mirror v2 is supported now
# Note for oc-mirror v2:
# resources/idms-oc-mirror.yaml
# mirror/data/working-dir/cluster-resources/itms-oc-mirror.yaml
# ls mirror/data/working-dir/cluster-resources/{idms,itms}*yaml

latest_working_dir=$(echo mirror/data/working-dir) 

ns=openshift-marketplace

if [ "$latest_working_dir" ]; then
	# Apply any idms/itms files created by oc-mirror v2
	for f in $(ls $latest_working_dir/cluster-resources/{idms,itms}*yaml 2>/dev/null || true) 
	do
		if [ -s $f ]; then
			aba_info oc apply -f $f
			exec_cmd="oc apply -f $f"
			aba_debug "Running: $exec_cmd"
			$exec_cmd
		else
			aba_warning "no such file: $f"
		fi
	done

	# Apply any CatalogSource files created by oc-mirror v2
	cs_file_list=$(ls $latest_working_dir/cluster-resources/cs-*-index*yaml 2>/dev/null || true)

	# Only warn about missing CatalogSources when operators are actually in the ISC.
	# If the ISC has no operators section, CatalogSource files are expected to be absent.
	if [ ! "$cs_file_list" ]; then
		_isc="mirror/data/imageset-config.yaml"
		if [ -f "$_isc" ] && grep -q '^[[:space:]]*operators:' "$_isc"; then
			aba_warning -p IMPORTANT \
				"No CatalogSource files found under $latest_working_dir/cluster-resources" \
				"Your imageset-config.yaml includes operators, but no CatalogSource files were generated." \
				"Run 'aba -d mirror sync' or 'aba -d mirror save' (transfer ISC and archive files), then 'aba -d mirror load' to mirror operator images."
		else
			aba_debug "No CatalogSource files found (no operators in 'aba.conf', 'mirror/mirror.conf' or in 'mirror/data/imageset-config.yaml') — skipping."
		fi
	fi

	wait_for_cs=

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
		aba_debug "Running: cat $f | sed ... | oc apply -f - (CatalogSource $cs_name)"
	       	cat $f | sed "s/name: cs-.*-index.*/name: $cs_name/g" | oc apply -f - # 2>/dev/null

		aba_info "Patching CatalogSource display name for $cs_name: $cs_name ($reg_host)"
		aba_debug "Running: oc patch CatalogSource $cs_name -n $ns --type merge (displayName)"
		oc patch CatalogSource $cs_name  -n $ns --type merge -p '{"spec": {"displayName": "'$cs_name' ('$reg_host')"}}'

		aba_info "Patching CatalogSource poll interval for $cs_name to 2m"
		aba_debug "Running: oc patch CatalogSource $cs_name -n $ns --type merge (pollInterval)"
		oc patch CatalogSource $cs_name  -n $ns --type merge -p '{"spec": {"updateStrategy": {"registryPoll": {"interval": "2m"}}}}'

		wait_for_cs=true

		# Start a sub-process to wait for CatalogSource 'ready'
		( 
			sleep 1

			until oc -n "$ns" get catalogsource "$cs_name" >/dev/null; do sleep 1; done

			#aba_info "Waiting for CatalogSource $cs_name to become 'ready' ... (note that a state of 'TRANSIENT_FAILURE' usually resolves itself within a few moments!)"
			aba_info "Waiting for CatalogSource $cs_name to become 'ready' ... "

			for _ in {1..99}; do
				state=$(oc -n "$ns" get catalogsource "$cs_name" -o jsonpath='{.status.connectionState.lastObservedState}')

				if [ "$state" = "READY" ]; then
					echo
					aba_info_ok "CatalogSource $cs_name is ready!"

					exit 0  # exit the process
				fi

				#[ "$state" ] && aba_info "$cs_name state: $state (working on it!)"
				if [ "$state" = "IDLE" ]; then
					echo -n "-"
				elif [ "$state" = "CONNECTING" ]; then
					echo -n "*"
				elif [ "$state" = "TRANSIENT_FAILURE" ]; then
					echo -n "#"
				elif [ "$state" ]; then
					echo -n "[$state]"
				fi

				sleep 5
			done

			# It's ok to abort from this background process 
			aba_abort "catalog source $cs_name failed to become 'ready' in time.  Ensure the cluster is stable and try again."
		) &
	done

	# Wait for all sub-processes
	[ "$wait_for_cs" ] && wait

	aba_info "Showing status of all CatalogSource resources:"
	exec_cmd="oc get CatalogSource -A"
	aba_debug "Running: $exec_cmd"
	$exec_cmd

	sig_file=$latest_working_dir/cluster-resources/signature-configmap.json
	if [ -s $sig_file ]; then
		aba_info "Applying signatures from: $sig_file ..."
		exec_cmd="oc apply -f $sig_file"
		aba_debug "Running: $exec_cmd"
		$exec_cmd
	else
		aba_info "No Signature files found in $latest_working_dir/cluster-resources" >&2
	fi
else
	# FIXME: Only show warning IF the mirror has been used for this cluster
	aba_warning "Missing oc-mirror working directory: $PWD/mirror/data/working-dir"
	aba_warning -p IMPORTANT \
		"No cluster resource files found (CatalogSource, idms/itms ...) " \
		"This usually occurs when Aba has not yet pushed any operator images to your mirror registry — either because mirroring" \
		"hasn’t been run, or it wasn’t done from this host." \
		"If the registry was filled using another method, you must manually create and apply the required CatalogSources for the operators." \
		"If the oc-mirror data/working-dir/ is on another host, copy the directory to this host and try again!" 

		#"This usually means that Aba has not yet pushed any operator images to your mirror registry (or not from this host)." \
		#"If your mirror registry was populated with images separately, you will need to apply the CatalogSources manually."

fi

# Note that if any operators fail to install after 600 seconds ... need to read this: https://access.redhat.com/solutions/6459071

# Apply user-provided custom manifests (if any)
apply_custom_manifests

exit 0

