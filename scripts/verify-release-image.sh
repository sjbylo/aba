#!/bin/bash
# Verify the correct/matching release image exists in the registry. Required access to the registry of course!

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
source <(normalize-mirror-conf)
export regcreds_dir=$HOME/.aba/mirror/$mirror_name

verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-mirror-conf || aba_abort "Invalid or incomplete mirror.conf. Check the errors above and fix mirror/mirror.conf."

aba_info "Ensuring CLI binaries are installed"
scripts/cli-install-all.sh --wait oc openshift-install

if [ ! -x ~/bin/openshift-install ]; then
	aba_abort "The ~/bin/openshift-install CLI is missing!  Please run aba first."
fi

out=$(openshift-install version)
release_sha=$(echo "$out" | grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")
release_ver=$(echo "$out" | grep "^openshift-install" | cut -d" " -f2)

if [ "$ocp_version" != "$release_ver" ]; then
	aba_abort \
		"The OpenShift version set in 'aba.conf' does not match the version of the 'openshift-install' CLI." \
		"Please run 'aba -d cli clean install' to refresh the CLIs and try again." 
fi

# When verify_conf=conf/off, skip the skopeo registry connectivity check
# but still extract the openshift-install binary from the mirror (required
# so the CVO pod references the mirror URL, not quay.io — avoids sigstore
# verification failures in OCP 4.21+).
if [ "$verify_conf" = "conf" ] || [ "$verify_conf" = "off" ]; then
	aba_warning "verify_conf=$verify_conf: skipping release image connectivity check"
else
	_release_url="docker://$reg_host:$reg_port$reg_path/openshift/release-images$release_sha"

	# Check twice for the image (skopeo sometimes fails when it shouldn't!)
	aba_debug "Running: skopeo inspect $_release_url"
	if ! skopeo inspect "$_release_url" >/dev/null 2>&1; then
		sleep 10
		_skopeo_err=$(skopeo inspect "$_release_url" 2>&1 >/dev/null) || {
			aba_abort \
				"Cannot access the release image for OpenShift v$release_ver in your registry." \
				"Image: $_release_url" \
				"${_skopeo_err:+skopeo: $_skopeo_err}" \
				"Possible causes:" \
				"- Registry credentials are missing or expired (run: aba -d mirror verify)" \
				"- Images have not been mirrored yet (run: aba sync or aba save/load)" \
				"- OpenShift version mismatch between aba.conf (v$ocp_version) and mirrored images"
		}
	fi
fi

# Extract openshift-install binary from the mirror, if not already.  Use this binary to install OpenShift.
openshift_install_mirror="./openshift-install-mirror-$reg_host"
if [ ! -x $openshift_install_mirror ]; then
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
	oc adm release extract --idms-file=.idms.yaml  --command=openshift-install $reg_host:$reg_port$reg_path/openshift/release-images$release_sha --insecure=true || true
	[ -x openshift-install ] && mv openshift-install $openshift_install_mirror
	# Now use the one in CWD # [ -s openshift-install ] && mv openshift-install ~/bin
	rm -f .idms.yaml
else
	aba_info "openshift-install already extracted from mirror registry"
fi

aba_info_ok "Release image for version $release_ver is available at $reg_host:$reg_port$reg_path/openshift/release-images$release_sha"

