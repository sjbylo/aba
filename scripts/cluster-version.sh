#!/bin/bash -e
# INTENT:       Output the current running OpenShift version of an installed cluster.
# CALLED BY:    aba cluster-version (via aba.sh dispatch)
# CWD:          Cluster directory (e.g. ~/aba/ocp/)
# REQUIRES:     cluster.conf, kubeconfig (externalized or local), oc CLI
# PRODUCES:     Single version string on stdout (e.g. "4.20.23"), empty if unreachable
# SIDE EFFECTS: None
# IDEMPOTENT:   Yes

source scripts/include_all.sh

source <(normalize-cluster-conf)

_kc=$(cluster_kubeconfig)
[ -z "$_kc" ] && aba_abort "kubeconfig not found for this cluster"

cluster_api_reachable "$_kc" || exit 0

oc --kubeconfig "$_kc" --request-timeout=10s get clusterversion version \
	-o 'jsonpath={.status.history[?(@.state=="Completed")].version}' 2>/dev/null \
	| awk '{print $1}'
