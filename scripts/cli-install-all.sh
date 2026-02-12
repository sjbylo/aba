#!/bin/bash
# Install CLI tools in parallel and in the background
# Usage: cli-install-all.sh [--wait|--reset] [tool ...]
#   No tool args = all tools.  Tool args = only those tools.
#   e.g.  cli-install-all.sh --wait oc openshift-install

# Ensure we're in aba root (script is in scripts/ subdirectory)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

ro_opt=
out=Installing
[ "$1" = "--wait" ] && ro_opt=-w && out=Waiting && shift
[ "$1" = "--reset" ] && ro_opt=-r && out=Resetting && shift
tool_filter=("$@")  # remaining args are tool names (empty = all)
aba_debug "Mode: $out (ro_opt=$ro_opt) filter=[${tool_filter[*]}]"

export PLAIN_OUTPUT=1

# CRITICAL: Wait for tarball downloads to complete before starting extractions.
# Without this, 'make -sC cli <tool>' sees a partially downloaded tarball (curl still
# writing) and starts 'tar' on it, producing a truncated/corrupt binary (segfault).
if [ "$ro_opt" != "-r" ]; then
	aba_debug "Waiting for CLI downloads to complete before extracting"
	scripts/cli-download-all.sh --wait "${tool_filter[@]}"
	aba_debug "CLI downloads complete"
fi

for item in $(make --no-print-directory -sC cli out-install-all)
do
	# If a filter was given, skip tools not in the list
	if [[ ${#tool_filter[@]} -gt 0 ]] && ! printf '%s\n' "${tool_filter[@]}" | grep -qx "$item"; then
		aba_debug "Skipping $item (not in filter)"
		continue
	fi

	aba_debug "$out: item=$item"
	aba_debug "run_once $ro_opt -i \"cli:install:$item\" -- make -sC cli $item"
	run_once $ro_opt -i "cli:install:$item" -- make -sC cli $item  # This is non-blocking
done

exit 0
