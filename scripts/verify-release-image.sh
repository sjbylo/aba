#!/bin/bash
# Verify the correct/matching release image exists in the registry. Required access to the registry of course!

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/${image_source:-mirror}
export regcreds_display="${image_source:-mirror}/regcreds"

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

#aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc openshift-install

if [ ! -x ~/bin/openshift-install ]; then
	aba_abort "The ~/bin/openshift-install CLI is missing!  Please run aba first."
fi

out=$(openshift-install version)
release_ver=$(echo "$out" | grep "^openshift-install" | cut -d" " -f2)

if [ "$ocp_version" != "$release_ver" ]; then
	aba_abort \
		"The OpenShift version set in 'aba.conf' does not match the version of the 'openshift-install' CLI." \
		"Please run 'aba -d cli clean install' to refresh the CLIs and try again." 
fi

if dist_supports_channels; then
	release_sha=$(echo "$out" | grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")
else
	# The installer's digest is the index. The mirror holds the arch image oc-mirror recorded.
	release_digest="$(dist_release_image_ref "$ocp_version")" || aba_abort \
		"Cannot tell which release image oc-mirror put into the mirror for $ocp_version"
	release_sha="@$release_digest"
fi

# When verify_conf=conf/off, skip the skopeo registry connectivity check
# but still extract the openshift-install binary from the mirror (required
# so the CVO pod references the mirror URL, not quay.io — avoids sigstore
# verification failures in OCP 4.21+).
if [ "$verify_conf" = "conf" ] || [ "$verify_conf" = "off" ]; then
	aba_warn "verify_conf=$verify_conf: skipping release image connectivity check"
else
	_image_ref=":${ocp_version}-$(uname -m)"
	dist_supports_channels || _image_ref="$release_sha"
	check_release_image || aba_abort \
		"Cannot access the release image for OpenShift v$ocp_version (HTTP ${_release_http_code:-?})" \
		"Image: $reg_host:$reg_port${reg_path}/openshift/release-images${_image_ref}" \
		"${_release_check_err:+Error: $_release_check_err}" \
		"${_release_check_extra[@]}" \
		"Run 'aba -d mirror verify' for detailed diagnostics."
fi

# Extract openshift-install binary from the mirror, if not already.  Use this binary to install OpenShift.
# Version+host+port in the filename ensures a version change triggers re-extraction.
openshift_install_mirror="./openshift-install-mirror-${ocp_version}-${reg_host}-${reg_port}"
if [ ! -x "$openshift_install_mirror" ]; then
	# HACK
	cat > .idms.yaml <<-END
	apiVersion: config.openshift.io/v1
	kind: ImageDigestMirrorSet
	metadata:
	  name: image-digest-mirror
	spec:
	  imageDigestMirrors:
	END
	echo "$image_content_sources" | sed 's/^/  /' >> .idms.yaml

	aba_info Extracting openshift-install from the release-image: $reg_host:$reg_port$reg_path/openshift/release-images$release_sha
	# This fails for oc versions up to v4.14 since the wrong/old version of 'oc' is used (i.e. 'idms' not supported).
	# So, I added || true to ignore errors (which is a hack!)
	exec_cmd="oc adm release extract --idms-file=.idms.yaml --command=openshift-install $reg_host:$reg_port$reg_path/openshift/release-images$release_sha --insecure=true"
	aba_debug "Running: $exec_cmd"
	if ! $exec_cmd; then
		aba_warn "Extract command failed"
	fi
	if [ -x openshift-install ]; then
		mv openshift-install "$openshift_install_mirror"
	else
		rm -f .idms.yaml
		aba_abort "Failed to extract openshift-install from the release image. The release image may not be available at $reg_host:$reg_port$reg_path/openshift/release-images$release_sha"
	fi
	rm -f .idms.yaml
else
	aba_info "openshift-install already extracted from mirror registry"
fi

if ! dist_supports_channels; then
	_inst_digest=$("$openshift_install_mirror" version 2>/dev/null | sed -n 's/^release image .*@\(sha256:[0-9a-f]\{64\}\)$/\1/p')
	if [ "$_inst_digest" != "$release_digest" ]; then
		rm -f "$openshift_install_mirror"
		aba_abort "The openshift-install from the mirror reports release image ${_inst_digest:-(none)}, expected $release_digest" \
			"The extracted binary was removed; run the command again."
	fi
fi

aba_success "Release image for version $release_ver is available at $reg_host:$reg_port$reg_path/openshift/release-images$release_sha"

