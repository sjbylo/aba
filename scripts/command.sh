#!/bin/bash 

cmd="$@"
echo "$cmd" | grep "^oc " && cmd=$(echo "$cmd" | cut -f2-  -d" ")
oc --kubeconfig=iso-agent-based/auth/kubeconfig $cmd

