#!/bin/bash 
# ssh into rendezvous server (node0)

source scripts/include_all.sh 

aba_debug "Starting: $0 $*"

source <(normalize-cluster-conf) 

verify-cluster-conf || exit 1

[ ! -f iso-agent-based/rendezvousIP ] && aba_abort "$PWD/iso-agent-based/rendezvousIP file missing!  To create it, run: aba iso"
ip=$(cat iso-agent-based/rendezvousIP)

if [ "$*" ]; then
	aba_info "Running: ssh -i $ssh_key_file core@$ip -- $*"
	ssh -i $ssh_key_file core@$ip -- $*
else
	aba_info "Running: ssh -i $ssh_key_file core@$ip"
	ssh -i $ssh_key_file core@$ip
fi

