#!/bin/bash 
# If the .install-complete flag file exists, refuse to continue

source scripts/include_all.sh

[ -f .install-complete ] && \
	echo_magenta "This cluster has already been deployed successfully!" && \
	echo_magenta "Run 'aba clean; aba' to re-install the cluster or remove the '.install-complete' flag file and try again." && exit 1

exit 0
