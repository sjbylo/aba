#!/bin/bash -e
# ssh into rendezvous server (node0)

[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory $PWD not yet initialized!  See: aba cluster --help" >&2 && exit 1
source scripts/include_all.sh 
trap - ERR

[ -f aba.conf -a ! -L aba.conf ] && aba_abort "Only run this command in a 'cluster directory'.  See: aba cluster --help"
[ ! -f cluster.conf ] && aba_abort "This directory ($PWD) is not yet initialized as a cluster directory!  See: aba cluster --help"

aba_debug "Starting: $0 $* from $PWD"

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

