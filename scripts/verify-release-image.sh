#!/bin/bash
# Verify the correct/matching release image exists in the registry. Required access to the registry of course!

source scripts/include_all.sh

aba_debug "Starting: $0 $*"



if [ ! -x ~/bin/openshift-install ]; then
	aba_abort "The ~/bin/openshift-install CLI is missing!  Please run aba first."
fi

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

verify-aba-conf || exit 1
verify-mirror-conf || exit 1

aba_info "Downloading CLI installation binaries"
scripts/cli-install-all.sh --wait  # FIXME: should only be for oc / openshift-install?

out=$(openshift-install version)
release_sha=$(echo "$out" | grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")
release_ver=$(echo "$out" | grep "^openshift-install" | cut -d" " -f2)

if [ "$ocp_version" != "$release_ver" ]; then
	aba_abort \
		"The OpenShift version set in 'aba.conf' does not match the version of the 'openshift-install' CLI." \
		"Please run 'aba -d cli clean install' to refresh the CLIs and try again." 
fi


#[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

# Check twice for the image (skopeo sometimes fails when it shouldn't!)
aba_debug Running: skopeo inspect docker://$reg_host:$reg_port$reg_path/openshift/release-images$release_sha
if ! skopeo inspect                  docker://$reg_host:$reg_port$reg_path/openshift/release-images$release_sha >/dev/null; then
	sleep 10
	if ! skopeo inspect                  docker://$reg_host:$reg_port$reg_path/openshift/release-images$release_sha >/dev/null; then

		aba_abort \
			"The expected release image for OpenShift v$release_ver was not found in your registry at $reg_host:$reg_port$reg_path." \
			"Did you complete running a 'sync' or 'save/load' operation to copy the images into your registry?" \
			"Be sure that the images in your registry match the version of the 'openshift-install' CLI (currently version $release_ver)" \
			"Do you have the correct image versions in your registry?" \
			"Failed to access the release image: docker://$reg_host:$reg_port$reg_path/openshift/release-images$release_sha" 
	fi
fi

# Extract openshift-install binary from the mirror, if not already.  Use this binary to install OpenShift. 
openshift_install_mirror="./openshift-install-$ocp_version-$reg_host-$reg_port-$(echo $reg_path | tr / -)"
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

