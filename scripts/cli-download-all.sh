#!/bin/bash
# Download CLI install tarballs in parallel and in the background
# Usage: cli-download-all.sh [--wait|--reset] [tool ...]
#   No tool args = all tools.  Tool args = only those tools.
#   e.g.  cli-download-all.sh --wait oc openshift-install

# Ensure we're in aba root (script is in scripts/ subdirectory)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

ro_opt=
out=Downloading
[ "$1" = "--wait" ] && ro_opt=-w && out=Waiting && shift
[ "$1" = "--reset" ] && ro_opt=-r && out=Resetting && shift
tool_filter=("$@")  # remaining args are tool names (empty = all)
aba_debug "Mode: $out (ro_opt=$ro_opt) filter=[${tool_filter[*]}]"

export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"

aba_debug "Fetching download list from cli/Makefile"
for item in $(make --no-print-directory -sC cli out-download-all)
do
	tool="${item%%:*}"  # strip version tag for make target (e.g. "oc:4.20.12" -> "oc")

	# If a filter was given, skip tools not in the list
	if [[ ${#tool_filter[@]} -gt 0 ]] && ! printf '%s\n' "${tool_filter[@]}" | grep -qx "$tool"; then
		aba_debug "Skipping $tool (not in filter)"
		continue
	fi

	aba_debug "$out: item=$item tool=$tool"
	aba_debug "run_once $ro_opt -i \"cli:download:$item\" -- make -sC cli download-$tool"
	run_once $ro_opt -i "cli:download:$item" -- make -sC cli download-$tool  # This is non-blocking
done
aba_debug "All CLI download tasks initiated"
