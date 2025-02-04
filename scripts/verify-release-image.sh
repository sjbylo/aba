#!/bin/bash
# Verify the correct/matching release image exists in the registry. Required access to the registry of course!

source scripts/include_all.sh

[ "$1" ] && set -x

if [ ! -x ~/bin/openshift-install ]; then
	echo
	echo_red "The ~/bin/openshift-install CLI is missing!  Please run aba first." >&2
	echo

	exit 1
fi

source <(normalize-aba-conf)
source <(normalize-mirror-conf)

out=$(openshift-install version)
release_sha=$(echo "$out" | grep "release image" | sed "s/.*\(@sha.*$\)/\1/g")
release_ver=$(echo "$out" | grep "^openshift-install" | cut -d" " -f2)

if [ "$ocp_version" != "$release_ver" ]; then
	echo
	echo_red "Warning: The OpenShift version set in 'aba.conf' is not the same as the version of the 'openshift-install' CLI." >&2 
	echo_red "         Please run 'aba clean && aba' in the cli/ directory to refresh the CLIs and try again." >&2 
	echo

	exit 1
fi


[ ! "$tls_verify" ] && tls_verify_opts="--tls-verify=false"

if ! skopeo inspect $tls_verify_opts docker://$reg_host:$reg_port/$reg_path/openshift/release-images$release_sha >/dev/null; then
	echo
	echo_red "Error: Release image missing in your registry at $reg_host:$reg_port/$reg_path. Expected version is $release_ver." >&2
	echo_red "       Did you run 'sync' or 'save/load' to copy the images into your registry?" >&2
	echo_red "       Be sure that the images in your registry match the version of the 'openshift-install' CLI (currently version $release_ver)" >&2
	echo_red "       Do you have the correct image versions in your registry?" >&2
	echo_red "       Failed to access the release image: docker://$reg_host:$reg_port/$reg_path/openshift/release-images$release_sha" >&2

	exit 1
fi

# HACK
cat > .idms.yaml <<END
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: image-digest-mirror
spec:
  imageDigestMirrors:
END
echo "$image_content_sources" | sed 's/^/  /' >> .idms.yaml

echo Extracting openshift-install from $reg_host:$reg_port/$reg_path/openshift/release-images$release_sha
#oc adm release extract --idms-file=.idms.yaml  --command=openshift-install $reg_host:$reg_port/$reg_path/openshift/release-images:${release_ver}-x86_64
# FIXME: this fails for oc versions up to v4.14 since the wrong version of 'oc' is used (i.e. 'idms' not supported).  So, I added || true to ignore errors
oc adm release extract --idms-file=.idms.yaml  --command=openshift-install $reg_host:$reg_port/$reg_path/openshift/release-images$release_sha --insecure=true || true
[ -s openshift-install ] && mv openshift-install ~/bin
rm -f .idms.yaml

echo_green "Release image for version $release_ver is available at $reg_host:$reg_port/$reg_path/openshift/release-images$release_sha"

