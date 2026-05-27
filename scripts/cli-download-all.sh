#!/bin/bash
# ── Contract ──────────────────────────────────────────────────────────
# Script:  cli-download-all.sh
# Purpose: Orchestrate parallel, non-blocking CLI tarball downloads.
#
# Modes (mutually exclusive):
#   (default)      Start background downloads for all tools (non-blocking).
#                  Downloads are serialized per-tarball via run_once inside
#                  the Makefile recipes — this script just triggers them.
#   --wait         Block until every download task has completed.
#   --reset        Reset download task markers (forces re-download on next run).
#   --no-version   Only start downloads for version-independent tools
#                  (oc-mirror, butane, govc) -- used when ocp_version is unknown.
#
# Optional positional args after the mode flag are tool names to filter on.
#   e.g.  cli-download-all.sh --wait oc openshift-install
#   No tool args = all tools.
#
# Inputs:
#   cli/Makefile targets: out-download-all | out-download-no-version
#   Each target outputs "tool[:version] ..." (e.g. "oc:4.20.12 oc-mirror butane govc")
#
# Side effects:
#   Triggers cli/Makefile download/reset targets which manage
#   per-tarball run_once serialization internally.
#
# Callers (9+): aba.sh, include_all.sh, Makefile (tar/tarrepo), cli/Makefile,
#   reg-save.sh, make-bundle.sh, tui/abatui.sh, cli-install-all.sh
# ──────────────────────────────────────────────────────────────────────

# Ensure we're in aba root (script is in scripts/ subdirectory)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Parse mode flag (mutually exclusive)
mode=start
make_list_target=out-download-all

if [ "${1:-}" = "--wait" ]; then
	mode=wait
	shift
elif [ "${1:-}" = "--reset" ]; then
	mode=reset
	shift
fi

if [ "${1:-}" = "--no-version" ]; then
	make_list_target=out-download-no-version
	shift
fi

tool_filter=("$@")

aba_debug "Mode: $mode filter=[${tool_filter[*]}] list_target=$make_list_target"

export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"

showed_wait_msg=false

aba_debug "Fetching download list from cli/Makefile ($make_list_target)"
items=$(make --no-print-directory -sC cli "$make_list_target") || {
	aba_abort "Failed to get download list from cli/Makefile ($make_list_target)"
}

for item in $items
do
	tool="${item%%:*}"  # strip version tag for make target (e.g. "oc:4.20.12" -> "oc")

	# Sanity-check the tool name from Makefile output
	if [[ ! "$tool" =~ ^[a-z][-a-z]*$ ]]; then
		aba_error "Unexpected tool name from cli/Makefile: '$tool' (item='$item')"
		continue
	fi

	# If a filter was given, skip tools not in the list
	if [[ ${#tool_filter[@]} -gt 0 ]] && ! printf '%s\n' "${tool_filter[@]}" | grep -qx "$tool"; then
		aba_debug "Skipping $tool (not in filter)"
		continue
	fi

	aba_debug "$mode: item=$item tool=$tool"

	if [[ "$mode" == "reset" ]]; then
		make -sC cli reset-download-$tool
	elif [[ "$mode" == "wait" ]]; then
		if ! $showed_wait_msg; then
			aba_info "Ensuring CLI downloads are complete ..."
			showed_wait_msg=true
		fi
		make -sC cli download-$tool
	else
		make -sC cli download-$tool &
	fi
done
aba_debug "All CLI download tasks processed"
