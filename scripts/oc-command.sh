#!/bin/bash -e

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized!  See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh
trap - ERR

[ ! -f cluster.conf ] && aba_abort "$PWD/cluster.conf file missing! Cluster directory $PWD not yet initialized!  See: aba cluster --help"

aba_debug "Starting: $0 $* from $PWD"

[ ! "$1" ] && cmd="get co" || cmd="$*"

echo "$cmd" | grep "^oc " && cmd=$(echo "$cmd" | cut -f2-  -d" ")  # Fix command if needed

#aba_info "Downloading CLI installation binaries"
#scripts/cli-install-all.sh --wait  # FIXME: should only be for oc?

aba_info "Running command: oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd"
eval oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd

