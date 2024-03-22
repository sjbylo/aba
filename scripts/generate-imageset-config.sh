#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source <(normalize-aba-conf)
#source <(normalize-mirror-conf)

ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

[ ! -s /tmp/redhat-operator-index-v$ocp_ver_major ] && \
	oc-mirror list operators --catalog registry.redhat.io/redhat/redhat-operator-index-v$ocp_ver_major > /tmp/redhat-operator-index-v$ocp_ver_major

tail -n +2 /tmp/redhat-operator-index-v$ocp_ver_major | awk '{print $1,$NF}' | while read op_name op_default_channel
do
	echo "\
      - name: $op_name
        channels:
        - name: $op_default_channel"
done

