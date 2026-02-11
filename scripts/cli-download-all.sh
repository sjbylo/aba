#!/bin/bash
# Download all CLI install tarballs in parallel and in the background

# Ensure we're in aba root (script is in scripts/ subdirectory)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

ro_opt=
out=Downloading
[ "$1" = "--wait" ] && ro_opt=-w && out=Waiting
[ "$1" = "--reset" ] && ro_opt=-r && out=Resetting
aba_debug "Mode: $out (ro_opt=$ro_opt)"

export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"

aba_debug "Fetching download list from cli/Makefile"
for item in $(make --no-print-directory -sC cli out-download-all)
do
	tool="${item%%:*}"  # strip version tag for make target (e.g. "oc:4.20.12" -> "oc")
	aba_debug "$out: item=$item tool=$tool"
	aba_debug "run_once $ro_opt -i \"cli:download:$item\" -- make -sC cli download-$tool"
	run_once $ro_opt -i "cli:download:$item" -- make -sC cli download-$tool  # This is non-blocking
done
aba_debug "All CLI download tasks initiated"

