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
export regcreds_display="${mirror_name:-mirror}/regcreds"
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

scripts/cli-install-all.sh --wait oc

aba_info "Accessing the cluster ..."

# Resolve kubeconfig if not already set
if [ ! "$KUBECONFIG" ]; then
	_kc=$(cluster_kubeconfig 2>/dev/null)
	[ -n "$_kc" ] && export KUBECONFIG="$_kc"
fi

# Fast fail if cluster API is unreachable
cluster_api_reachable "$KUBECONFIG" || aba_abort "Cluster API is not reachable. Is the cluster running?"

aba_debug "Running: oc whoami --request-timeout=20s"
if ! oc whoami --request-timeout='20s' >/dev/null 2>/dev/null; then
	aba_debug "Running: oc whoami (with KUBECONFIG=$KUBECONFIG)"
	if ! oc whoami >/dev/null; then
		aba_warn "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

		. <(aba login)

		aba_debug "Running: oc whoami --request-timeout=20s (after login)"
		if ! oc whoami --request-timeout='20s' >/dev/null; then
			aba_abort "Unable to log into the cluster" 
		fi
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
# Detect cert mismatch: registry was reinstalled with new CA but cluster has the old one.
_cert_changed=""
_existing_bundle=""
if [ -s "$regcreds_dir/rootCA.pem" ] && [ "$cm_existing" ]; then
	_cm_key="${reg_host}..${reg_port}"
	_existing_bundle=$(oc get cm registry-config -n openshift-config -o go-template='{{index .data "'"$_cm_key"'"}}' 2>/dev/null || true)
	# Compare the base64 body (unique per cert) to check if the new cert is already in the bundle
	_new_cert_body=$(grep -v '^-' "$regcreds_dir/rootCA.pem" | tr -d '[:space:]')
	_bundle_body=$(echo "$_existing_bundle" | grep -v '^-' | tr -d '[:space:]')
	if [ -n "$_new_cert_body" ] && [ -n "$_bundle_body" ] && \
	   ! echo "$_bundle_body" | grep -qF "$_new_cert_body"; then
		_local_fp=$(openssl x509 -noout -fingerprint -in "$regcreds_dir/rootCA.pem" 2>/dev/null || true)
		aba_warn "Registry CA has changed. Appending new CA to the cluster trust bundle." \
			"New CA:  $_local_fp"
		_cert_changed=1
	fi
fi
if [ -s "$regcreds_dir/rootCA.pem" ] && { [ ! "$cm_existing" ] || [ "$_cert_changed" ]; }; then
	aba_info "Adding the trust CA of the registry ($reg_host) ..."
	if [ "$_cert_changed" ] && [ -n "$_existing_bundle" ]; then
		# Append new cert to existing bundle so both old and new CAs are trusted
		export additional_trust_bundle="${_existing_bundle}
$(cat "$regcreds_dir/rootCA.pem")"
		aba_info "Appending new CA to existing trust bundle"
	else
		export additional_trust_bundle=$(cat "$regcreds_dir/rootCA.pem")
	fi
	aba_info "Using root CA file at $regcreds_display/rootCA.pem"

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

	_day2_oauth_proxy_available() {
		aba_debug "Running: oc get imagestream -n openshift oauth-proxy"
		oc get imagestream -n openshift oauth-proxy >/dev/null 2>&1
	}

	if ! aba_wait_show "Waiting for oauth-proxy imagestream" 5 180 _day2_oauth_proxy_available; then
		aba_abort "Timed out waiting for oauth-proxy imagestream (3 min)"
	fi

	aba_debug "Running: oc get imagestream -n openshift oauth-proxy -o yaml"
	if oc get imagestream -n openshift oauth-proxy -o yaml 2>&1 | grep -qi "unknown authority"; then
		aba_info "Waiting for registry CA trust to propagate to the cluster ..."
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
		aba_info "Registry CA trust already propagated."
	fi
	# Note, might still need to restart operators, e.g. 'oc delete pod -l name=jaeger-operator -n openshift-distributed-tracing'
else
	aba_info "Registry trust bundle already added (cm registry-config -n openshift-config). Assuming workaround has already been applied or not necessary."
fi

apply_custom_manifests() {
	# Apply user-provided custom manifests from day2-custom-manifests/ in cluster folder.
	# Supports two modes:
	#   1. Waved: numbered subdirs (10-ns/, 20-app/) applied in sort -V order.
	#      Optional .wait file in a wave dir gates the next wave via oc wait.
	#   2. Flat (legacy): all .yaml/.yml files applied in alphabetical order.
	# Mode is auto-detected: if ANY numbered subdir exists, waved mode is used.

	local custom_manifest_dir="$PWD/day2-custom-manifests"

	if [ ! -d "$custom_manifest_dir" ]; then
		aba_info "No custom manifests directory found at $custom_manifest_dir (this is optional)"
		return 0
	fi

	# Inner helper: apply a list of manifest files (one per line on stdin)
	_apply_manifest_list() {
		local _success=0 _fail=0
		local _file
		while IFS= read -r _file; do
			[ -z "$_file" ] && continue
			local _rel="${_file#"$custom_manifest_dir"/}"
			if [ ! -s "$_file" ]; then
				aba_warn "Skipping empty file: $_rel"
				_fail=$(( _fail + 1 ))
				continue
			fi
			aba_info "oc apply -f $_rel"
			if oc apply -f "$_file"; then
				_success=$(( _success + 1 ))
			else
				aba_warn "Failed to apply: $_rel (continuing)"
				_fail=$(( _fail + 1 ))
			fi
		done
		[ $_success -gt 0 ] && aba_success "Applied $_success manifest(s) in this batch"
		[ $_fail -gt 0 ] && aba_warn "Failed $_fail manifest(s) in this batch"
	}

	# Detect waved mode: any numbered subdir?
	local _waves
	_waves=$(find "$custom_manifest_dir" -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | sort -V)

	if [ -z "$_waves" ]; then
		# --- Flat (legacy) mode ---
		local found_files
		found_files="$(find "$custom_manifest_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"
		local file_count
		file_count="$(printf '%s\n' "$found_files" | grep -c . || true)"

		if [ "$file_count" -eq 0 ]; then
			aba_debug "No custom manifest files (.yaml/.yml) found in $custom_manifest_dir"
			return 0
		fi

		aba_info "Found $file_count custom manifest file(s) (flat mode)"
		aba_info "Applying user-provided custom manifests ..."
		echo "$found_files" | _apply_manifest_list
		return 0
	fi

	# --- Waved mode ---
	aba_info "Waved manifest application detected"

	# Also collect any top-level (non-subdir) manifests to apply first
	local _top_files
	_top_files=$(find "$custom_manifest_dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
	if [ "$_top_files" ]; then
		aba_info "Applying top-level manifests (before waves) ..."
		echo "$_top_files" | _apply_manifest_list
	fi

	local _wave_num=0
	while IFS= read -r _wave_dir; do
		[ -z "$_wave_dir" ] && continue
		_wave_num=$(( _wave_num + 1 ))
		local _wave_name
		_wave_name=$(basename "$_wave_dir")

		local _wave_files
		_wave_files=$(find "$_wave_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

		if [ -z "$_wave_files" ]; then
			aba_debug "Wave $_wave_name: no manifest files, skipping"
			continue
		fi

		local _wf_count
		_wf_count=$(echo "$_wave_files" | grep -c . || true)
		aba_info "Wave $_wave_name: applying $_wf_count manifest(s) ..."
		echo "$_wave_files" | _apply_manifest_list

		# Process .wait gate if present
		local _wait_file="$_wave_dir/.wait"
		if [ -f "$_wait_file" ]; then
			aba_info "Wave $_wave_name: processing .wait gate ..."
			while IFS= read -r _wait_line; do
				# Skip empty lines and comments
				[[ -z "$_wait_line" || "$_wait_line" =~ ^[[:space:]]*# ]] && continue
				aba_info "oc wait $_wait_line"
				if ! eval oc wait $_wait_line; then
					aba_warn "Wait gate failed: oc wait $_wait_line (continuing to next wave)"
				fi
			done < "$_wait_file"
		fi
	done <<< "$_waves"

	aba_success "Waved manifest application complete ($_wave_num wave(s) processed)"
	return 0
}


####################################
# Only oc-mirror v2 is supported now
# Note for oc-mirror v2:
# resources/idms-oc-mirror.yaml
# mirror/data/working-dir/cluster-resources/itms-oc-mirror.yaml
# ls mirror/data/working-dir/cluster-resources/{idms,itms}*yaml

working_dir="mirror/data/working-dir"

ns=openshift-marketplace

if [ -d "$working_dir/cluster-resources" ]; then
	# Apply any idms/itms files created by oc-mirror v2
	for f in $(ls $working_dir/cluster-resources/{idms,itms}*yaml 2>/dev/null || true) 
	do
		if [ -s $f ]; then
			aba_info oc apply -f $f
			exec_cmd="oc apply -f $f"
			aba_debug "Running: $exec_cmd"
			$exec_cmd
		else
			aba_warn "no such file: $f"
		fi
	done

	# Apply any CatalogSource files created by oc-mirror v2
	cs_file_list=$(ls $working_dir/cluster-resources/cs-*-index*yaml 2>/dev/null || true)

	# Only warn about missing CatalogSources when operators are actually in the ISC.
	# If the ISC has no operators section, CatalogSource files are expected to be absent.
	if [ ! "$cs_file_list" ]; then
		_isc="mirror/data/imageset-config.yaml"
		if [ -f "$_isc" ] && grep -q '^[[:space:]]*operators:' "$_isc"; then
			aba_warn -p IMPORTANT \
				"No CatalogSource files found under $working_dir/cluster-resources" \
				"Your imageset-config.yaml includes operators, but no CatalogSource files were generated." \
				"Run 'aba -d mirror sync' or 'aba -d mirror save' (transfer ISC and archive files), then 'aba -d mirror load' to mirror operator images."
		else
			aba_info "No operators configured — skipping CatalogSource setup."
		fi
	fi

	cs_pids=()

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
					aba_success "CatalogSource $cs_name is ready!"

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
		cs_pids+=($!)
	done

	# Wait for each CatalogSource subprocess individually so no failure is lost
	cs_failed=0
	for pid in "${cs_pids[@]}"; do
		if ! wait "$pid"; then
			cs_failed=1
		fi
	done

	[ "$cs_failed" = "1" ] && aba_abort "One or more CatalogSources failed to become READY. Check the errors above."

	aba_info "Showing status of all CatalogSource resources:"
	exec_cmd="oc get CatalogSource -A"
	aba_debug "Running: $exec_cmd"
	$exec_cmd

	sig_file=$working_dir/signature-configmap-merged.json
	[ -s "$sig_file" ] || sig_file=$working_dir/cluster-resources/signature-configmap.json
	if [ -s "$sig_file" ]; then
		aba_info "Applying signatures from: $sig_file ..."
		if oc get configmap mirrored-release-signatures -n openshift-config-managed >/dev/null 2>&1; then
			# Merge new signatures into existing ConfigMap (additive).
			# oc apply would prune signatures from prior syncs because
			# last-applied-configuration tracks the previous key set.
			oc patch configmap mirrored-release-signatures -n openshift-config-managed \
				--type=merge -p "$(jq '{binaryData: .binaryData}' "$sig_file")"
		else
			oc apply -f "$sig_file"
		fi
	else
		aba_info "No Signature files found in $working_dir/cluster-resources" >&2
	fi
else
	# FIXME: Only show warning IF the mirror has been used for this cluster
	aba_warn "Missing oc-mirror working directory: $PWD/mirror/data/working-dir"
	aba_warn -p IMPORTANT \
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

aba_success "Day-2 configuration completed successfully."

# Day2 changes (IDMS, CA trust, ITMS) trigger CO reconciliation and possible node restarts.
# Wait for operators to settle so subsequent commands (e.g. upgrade) see a stable cluster.
aba_wait_show "Ensuring cluster operators are stable after day2 changes (Ctrl-C to skip)" 15 600 cluster_is_ready || true

exit 0

