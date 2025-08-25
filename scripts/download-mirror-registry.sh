#!/bin/bash 
# Download the latest version of mirror-registry

ver=$(curl -skL https://mirror.openshift.com/pub/openshift-v4/clients/mirror-registry/ | grep -oP '>(\d+\.\d+(\.\d+)?)<' | grep -oP '\d+\.\d+(\.\d+)?' | sort -V | tail -n 1)
[ ! "$ver" ] && ver=1.3.11
echo Downloading https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/$ver/mirror-registry.tar.gz ...
[ "$PLAIN_OUTPUT" ] && progress="-s" || progress="--progress-bar"
curl $progress -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/$ver/mirror-registry.tar.gz

