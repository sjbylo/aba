#!/bin/bash 
# If the .finished flag file exists, refuse to continue

source scripts/include_all.sh

[ -f .finished ] && \
	echo_magenta "This cluster has already been deployed successfully!" && \
	echo_magenta "Run 'make clean; make' to re-install the cluster or remove the '.finished' flag file and try again." && exit 1

exit 0
