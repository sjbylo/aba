#!/bin/bash
# Download all CLI install tarballs in parallel and in the background

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

ro_opt=
out=Downloading
[ "$1" = "--wait" ] && ro_opt=-w && out=Waiting
[ "$1" = "--reset" ] && ro_opt=-r && out=Resetting

export PLAIN_OUTPUT=1

for item in $(make -sC $ABA_ROOT/cli out-download-all)
do
	aba_debug $out: item=$item
	aba_debug "run_once $ro_opt -i "cli:download:$item" -- make -sC $ABA_ROOT/cli $item"
	run_once $ro_opt -i "cli:download:$item" -- make -sC $ABA_ROOT/cli $item  # This is non-blocking
done

