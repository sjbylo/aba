#!/bin/bash 

[ -f .finished ] && echo "Warning: This cluster was already deployed.  Run 'make clean' first or remove the '.finished' flag file and try again." && exit 1

exit 0
