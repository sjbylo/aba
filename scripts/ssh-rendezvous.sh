#!/bin/bash 

source scripts/include_all.sh 

source <(normalize-cluster-conf) 

ip=$(cat iso-agent-based/rendezvousIP)

if [ "$*" ]; then
	echo "Running: ssh -i $ssh_key_file core@$ip -- $*"
	ssh -i $ssh_key_file core@$ip -- $*
else
	echo "Running: ssh -i $ssh_key_file core@$ip"
	ssh -i $ssh_key_file core@$ip 
fi

