#!/bin/bash -e
# This script displays the access credentials for an installed cluster

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ ! -d iso-agent-based/auth ] && echo_red "Cluster not ready!" && exit 1

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
verify-aba-conf || exit 1
verify-cluster-conf || exit 1

pw=$(cat iso-agent-based/auth/kubeadmin-password 2>/dev/null)
kc=$(ls $PWD/iso-agent-based/auth/kubeconfig 2>/dev/null)

cat <<END
[ABA] To access the cluster as the system:admin user when using 'oc', run
[ABA]     export KUBECONFIG=$kc
[ABA] Access the OpenShift web-console here: https://console-openshift-console.apps.$cluster_name.$base_domain
[ABA] Login to the console with user: "kubeadmin", and password: "$pw"
END
cat <<END
[ABA] Run '. <(aba shell)' to access the cluster using the kubeconfig file (auth cert), or
[ABA] Run '. <(aba login)' to log into the cluster using the 'kubeadmin' password.
END
[ -f regcreds/pull-secret-mirror.json ] && \
	echo "[ABA] Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry (run after adding any operators to your mirror)." && \
	echo "[ABA] Run 'aba day2-osus' to configure the OpenShift Update Service."
cat <<END
[ABA] Run 'aba day2-ntp' to configure NTP on this cluster.
[ABA] Run 'aba info' to see this information again.
[ABA] Run 'aba -h' or 'aba help' for more.
END


