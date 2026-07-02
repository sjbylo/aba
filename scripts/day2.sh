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
		aba_warning "Unable to access the cluster using KUBECONFIG=$KUBECONFIG"

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
		aba_warning "Registry CA has changed. Appending new CA to the cluster trust bundle." \
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

	# Track successes and failures across every apply (flat and waved).
	local success_count=0
	local failure_count=0

	# Apply a newline-separated, pre-sorted list of manifest files. while+read
	# handles filenames containing spaces. Failures are non-fatal (logged, counted).
	_apply_manifest_list() {
		local _files="$1" manifest_file rel_path
		[ -z "$_files" ] && return 0
		while IFS= read -r manifest_file; do
			[ -z "$manifest_file" ] && continue
			# Show path relative to the custom manifests dir for cleaner output
			rel_path="${manifest_file#"$custom_manifest_dir"/}"

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
		done <<< "$_files"
	}

	# Discover numbered "wave" subdirs (names starting with a digit), sorted
	# NUMERICALLY (sort -V, so 2-foo comes before 10-foo, not lexicographically).
	local wave_dirs
	wave_dirs="$(find "$custom_manifest_dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort -V)"

	if [ -z "$wave_dirs" ]; then
		# FLAT / legacy layout: no numbered wave dirs. Apply every .yaml/.yml
		# recursively in sorted order so users can order via file naming (00-, 01-).
		local found_files file_count
		found_files="$(find "$custom_manifest_dir" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"
		file_count="$(printf '%s\n' "$found_files" | grep -c . || true)"
		if [ "$file_count" -eq 0 ]; then
			aba_debug "No custom manifest files (.yaml/.yml) found in $custom_manifest_dir"
			return 0
		fi
		aba_info "Found $file_count custom manifest file(s) in $custom_manifest_dir"
		aba_info "Applying user-provided custom manifests ..."
		_apply_manifest_list "$found_files"
	else
		# WAVED layout: numbered wave dirs are present. Apply every top-level entry
		# (files and dirs) in NUMERIC order (sort -V, so 2- before 10-), which keeps
		# the legacy relative ordering of non-wave files (e.g. 99-post applies after a
		# 10-operators wave). A numbered dir is a "wave": after applying it, an optional
		# per-wave '.wait' file gates the next entry via 'oc wait'. Non-numbered files
		# and dirs apply at their sorted position, so nothing is dropped.
		aba_info "Applying user-provided custom manifests in waves ..."

		local entry entry_name entry_files _cond
		while IFS= read -r entry; do
			[ -z "$entry" ] && continue
			entry_name="$(basename "$entry")"
			if [ -d "$entry" ]; then
				entry_files="$(find "$entry" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)"
			elif [ -f "$entry" ]; then
				case "$entry" in *.yaml|*.yml) entry_files="$entry" ;; *) continue ;; esac
			else
				continue
			fi
			if [ -n "$entry_files" ]; then
				aba_info "Applying: $entry_name"
				_apply_manifest_list "$entry_files"
			fi

			# Optional gate on a wave dir: one 'oc wait' condition per non-comment line
			# in '.wait'. A failed/timed-out wait is non-fatal so day2 can continue.
			# Require -r too: day2 runs under 'set -e', so an unreadable '.wait' would
			# make the loop's input redirect fail and abort the whole day2 run.
			if [ -d "$entry" ] && [ -f "$entry/.wait" ] && [ ! -r "$entry/.wait" ]; then
				aba_warning "Wave $entry_name: '.wait' exists but is not readable (skipping gate, continuing)"
			elif [ -d "$entry" ] && [ -f "$entry/.wait" ]; then
				while IFS= read -r _cond || [ -n "$_cond" ]; do
					_cond="${_cond%$'\r'}"
					_cond="${_cond#"${_cond%%[![:space:]]*}"}"   # trim leading whitespace
					case "$_cond" in \#*) continue ;; esac         # skip full-line comments first
					# Strip a trailing ' # comment', but ONLY if doing so keeps the line
					# xargs-parseable; otherwise the '#' is inside a quoted value (e.g. a
					# selector like --selector='app=web #1') and must be preserved.
					_stripped="${_cond%% #*}"
					if [ "$_stripped" != "$_cond" ] && printf '%s\n' "$_stripped" | xargs >/dev/null 2>&1; then
						_cond="$_stripped"
					fi
					_cond="${_cond%"${_cond##*[![:space:]]}"}"   # trim trailing whitespace
					[ -z "$_cond" ] && continue
					# Reject a line xargs cannot parse (e.g. unbalanced quotes) instead of
					# running 'oc wait' with a silently truncated argv.
					if ! printf '%s\n' "$_cond" | xargs >/dev/null 2>&1; then
						aba_warning "Wave $entry_name: cannot parse .wait line (unbalanced quotes?), skipping: $_cond"
						continue
					fi
					aba_info "Wave $entry_name: waiting for 'oc wait $_cond' ..."
					aba_debug "Running: oc wait $_cond"
					# Parse the line with xargs so shell-style quoting in copy-pasted
					# 'oc wait --for=jsonpath='\''{...}'\'' ...' examples is honored.
					if ! printf '%s\n' "$_cond" | xargs -r oc wait; then
						aba_warning "Wave $entry_name: 'oc wait $_cond' failed or timed out (continuing)"
					fi
				done < "$entry/.wait"
			fi
		done <<< "$(find "$custom_manifest_dir" -mindepth 1 -maxdepth 1 | sort -V)"
	fi

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

latest_working_dir="mirror/data/working-dir"

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

aba_info_ok "Day-2 configuration completed successfully."

exit 0

