#!/bin/bash -e

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized!  See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh
trap - ERR

[ ! -f cluster.conf ] && aba_abort "$PWD/cluster.conf file missing! Cluster directory $PWD not yet initialized!  See: aba cluster --help"

aba_debug "Starting: $0 $* from $PWD"

source <(normalize-cluster-conf)

[ ! "$1" ] && cmd="get co" || cmd="$*"

echo "$cmd" | grep -q "^oc " && cmd=$(echo "$cmd" | cut -f2-  -d" ")  # Fix command if needed

#aba_info "Downloading CLI installation binaries"
#scripts/cli-install-all.sh --wait oc

_kc=$(cluster_kubeconfig 2>/dev/null)
[ -z "$_kc" ] && _kc="$PWD/iso-agent-based/auth/kubeconfig"
export KUBECONFIG="$_kc"

cluster_api_reachable "$KUBECONFIG" || aba_abort "Cluster API is not reachable. Is the cluster running?"

aba_info "Running command: oc $cmd" >&2
aba_debug "Running: oc $cmd"
eval oc $cmd

