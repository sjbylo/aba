#!/bin/bash 

source scripts/include_all.sh
trap - ERR

aba_debug "Starting: $0 $*"

[ ! "$1" ] && cmd="get co" || cmd="$*"

echo "$cmd" | grep "^oc " && cmd=$(echo "$cmd" | cut -f2-  -d" ")  # Fix command if needed

aba_info "Running command: oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd"
eval oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd

