#!/bin/bash -e
# This script displays the access credentials for an installed cluster

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/$mirror_name
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

# Resolve kubeconfig (prefer externalized state, fall back to local)
kc=$(cluster_kubeconfig)
[ -z "$kc" ] && aba_abort "Cluster not ready! Cannot find kubeconfig."

# Resolve kubeadmin password (externalized or local)
_sd=$(cluster_state_dir 2>/dev/null) || _sd=""
if [ -n "$_sd" ] && [ -f "$_sd/kubeadmin-password" ]; then
	pw=$(cat "$_sd/kubeadmin-password")
else
	pw=$(cat iso-agent-based/auth/kubeadmin-password 2>/dev/null)
fi

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
[ -f "$regcreds_dir/pull-secret-mirror.json" ] && \
	echo "[ABA] Run 'aba day2' to connect this cluster's OperatorHub to your mirror registry (run after adding any operators to your mirror)." && \
	echo "[ABA] Run 'aba day2-osus' to configure the OpenShift Update Service."
cat <<END
[ABA] Run 'aba day2-ntp' to configure NTP on this cluster.
[ABA] Run 'aba info' to see this information again.
[ABA] Run 'aba -h' or 'aba help' for more.
END


