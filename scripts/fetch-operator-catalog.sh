#!/bin/bash
# Convenience script to download the latest operator catalog and convert to image set format ready for use!

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

export ocp_ver=$ocp_version
export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

[ ! "$ocp_ver_major" ] && echo "Error, ocp_version not defined" && exit 1

# Fetch latest operator catalog and default channels
[ ! -s .redhat-operator-index-v$ocp_ver_major ] && \
	oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major > .redhat-operator-index-v$ocp_ver_major

tail -n +3 .redhat-operator-index-v$ocp_ver_major | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
    - name: $op_name
      channels:
      - name: $op_default_channel"
done > imageset-config-operator-catalog.yaml

echo_cyan "See file: imageset-config-operator-catalog.yaml and copy the required Operators to your imageset config file, if needed."

