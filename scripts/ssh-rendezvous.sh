#!/bin/bash 

if [ "$@" ]; then
	echo Running: ssh core@$(cat iso-agent-based/rendezvousIP) -- $@
	ssh core@$(cat iso-agent-based/rendezvousIP) -- $@
else
	echo Running: ssh core@$(cat iso-agent-based/rendezvousIP) 
	ssh core@$(cat iso-agent-based/rendezvousIP) 
fi

#[ $? -ne 0 ] && echo "Note: If ssh fails, are the ssh keys configured, e.g. ~/.ssh/id_rsa and ~/.ssh/id_rsa.pub ?"
