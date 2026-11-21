#!/bin/bash -e
# This script displays the access credentials for an installed cluster

source scripts/include_all.sh

aba_debug "Starting: $0 $* in $PWD"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)
export regcreds_dir=$HOME/.aba/mirror/${image_source:-mirror}
verify-aba-conf || aba_abort "$_ABA_CONF_ERR"
verify-cluster-conf || exit 1

# Resolve kubeconfig (prefers local, falls back to externalized state)
kc=$(cluster_kubeconfig)
[ -z "$kc" ] && aba_abort "Cluster not ready! Cannot find kubeconfig."

show_cluster_card


