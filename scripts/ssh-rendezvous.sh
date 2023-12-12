#!/bin/bash 

if [ "$@" ]; then
	echo ssh core@$(cat iso-agent-based/rendezvousIP) -- $@
	ssh core@$(cat iso-agent-based/rendezvousIP) -- $@
else
	echo ssh core@$(cat iso-agent-based/rendezvousIP) 
	ssh core@$(cat iso-agent-based/rendezvousIP) 
fi

