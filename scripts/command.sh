#!/bin/bash 

. scripts/include_all.sh

oc --kubeconfig=iso-agent-based/auth/kubeconfig $@

