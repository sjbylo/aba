#!/bin/bash 
# ssh into rendezvous server (node0)

source scripts/include_all.sh 

aba_debug "Starting: $0 $*"

source <(normalize-cluster-conf) 

verify-cluster-conf || exit 1

[ ! -f iso-agent-based/rendezvousIP ] && echo "Error: $PWD/iso-agent-based/rendezvousIP file missing!  To create it, run: aba iso" && exit 1
ip=$(cat iso-agent-based/rendezvousIP)

if [ "$*" ]; then
	echo "Running: ssh -i $ssh_key_file core@$ip -- $*"
	ssh -i $ssh_key_file core@$ip -- $*
else
	echo "Running: ssh -i $ssh_key_file core@$ip"
	ssh -i $ssh_key_file core@$ip
fi

