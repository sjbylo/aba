#!/bin/bash
# Install all CLI tools in parallel and in the background

# Ensure we're in aba root (script is in scripts/ subdirectory)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

ro_opt=
out=Installing
[ "$1" = "--wait" ] && ro_opt=-w && out=Waiting
[ "$1" = "--reset" ] && ro_opt=-r && out=Resetting

export PLAIN_OUTPUT=1

for item in $(make --no-print-directory -sC cli out-install-all)
do
	aba_debug $out: item=$item
	aba_debug "run_once $ro_opt -i \"cli:install:$item\" -- make -sC cli $item"
	run_once $ro_opt -i "cli:install:$item" -- make -sC cli $item  # This is non-blocking
done

exit 0
