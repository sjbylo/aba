#!/bin/bash 

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ ! "$1" ] && cmd="get co" || cmd="$*"

echo "$cmd" | grep "^oc " && cmd=$(echo "$cmd" | cut -f2-  -d" ")  # Fix command if needed

echo "Running command: oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd"
oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd

