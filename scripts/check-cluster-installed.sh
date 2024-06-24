#!/bin/bash 
# If the .finished flag file exists, refuse to continue

[ -f .finished ] && echo "Warning: This cluster has already been deployed successfully.  Run 'make clean' or remove the '.finished' flag file and try again." && exit 1

exit 0
