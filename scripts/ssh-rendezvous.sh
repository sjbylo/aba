#!/bin/bash 

ip=$(cat iso-agent-based/rendezvousIP)
if [ "$*" ]; then
	echo "Running: ssh core@$ip -- $*"
	ssh core@$ip -- $*
else
	echo "Running: ssh core@$ip"
	ssh core@$ip 
fi

