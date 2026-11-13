#!/bin/bash 
# If the .install-complete flag file exists, refuse to continue

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

[ -f .install-complete ] && \
	aba_abort "This cluster has already been deployed successfully!" \
		"To re-install:  $(aba_cmd delete)" \
		"Then:           $(aba_cmd install)"

exit 0
