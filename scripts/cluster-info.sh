#!/bin/bash -e
# This script displays the access credentials for an installed cluster

source scripts/include_all.sh

[ "$1" ] && set -x

[ ! -d iso-agent-based/auth ] && echo_red "Cluster not ready!" && exit 1

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
verify-aba-conf || exit 1
verify-cluster-conf || exit 1

pw=$(cat iso-agent-based/auth/kubeadmin-password 2>/dev/null)
kc=$(ls $PWD/iso-agent-based/auth/kubeconfig 2>/dev/null)

cat <<END
To access the cluster as the system:admin user when using 'oc', run
    export KUBECONFIG=$kc
Access the OpenShift web-console here: https://console-openshift-console.apps.$cluster_name.$base_domain
Login to the console with user: "kubeadmin", and password: "$pw"
END
cat <<END
Run '. <(aba shell)' to access the cluster using the kubeconfig file (x509 cert), or
Run '. <(aba login)' to log into the cluster using the 'kubeadmin' password.
END
[ -f regcreds/pull-secret-mirror.json ] && \
echo "Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry."
cat <<END
Run 'aba day2-ntp' to configure NTP on this cluster.
Run 'aba -h' or 'aba help' for more.
END




