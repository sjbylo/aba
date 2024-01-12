#!/bin/bash 

if [ "$@" ]; then
	echo Running: ssh core@$(cat iso-agent-based/rendezvousIP) -- $@
	ssh core@$(cat iso-agent-based/rendezvousIP) -- $@
else
	echo Running: ssh core@$(cat iso-agent-based/rendezvousIP) 
	ssh core@$(cat iso-agent-based/rendezvousIP) 
fi

