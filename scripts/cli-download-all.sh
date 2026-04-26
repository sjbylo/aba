#!/bin/bash
# ── Contract ──────────────────────────────────────────────────────────
# Script:  cli-download-all.sh
# Purpose: Orchestrate parallel, non-blocking CLI tarball downloads via run_once.
#
# Modes (mutually exclusive):
#   (default)      Start background downloads for all tools (non-blocking).
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
#   Creates run_once tasks: cli:download:<tool[:version]>
#   Each task runs: make -sC cli download-<tool>
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
ro_opts=()
out=Downloading
wait_mode=false
make_list_target=out-download-all

if [ "${1:-}" = "--wait" ]; then
	ro_opts=(-q -w)
	out=Waiting
	wait_mode=true
	shift
elif [ "${1:-}" = "--reset" ]; then
	ro_opts=(-r)
	out=Resetting
	shift
fi

if [ "${1:-}" = "--no-version" ]; then
	make_list_target=out-download-no-version
	shift
fi

tool_filter=("$@")

aba_debug "Mode: $out (ro_opts=[${ro_opts[*]}]) filter=[${tool_filter[*]}] list_target=$make_list_target"

export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"

showed_wait_msg=false

aba_debug "Fetching download list from cli/Makefile ($make_list_target)"
items=$(make --no-print-directory -sC cli "$make_list_target") || {
	aba_err "Failed to get download list from cli/Makefile ($make_list_target)"
	exit 1
}

for item in $items
do
	tool="${item%%:*}"  # strip version tag for make target (e.g. "oc:4.20.12" -> "oc")

	# Sanity-check the tool name from Makefile output
	if [[ ! "$tool" =~ ^[a-z][-a-z]*$ ]]; then
		aba_err "Unexpected tool name from cli/Makefile: '$tool' (item='$item')"
		continue
	fi

	# If a filter was given, skip tools not in the list
	if [[ ${#tool_filter[@]} -gt 0 ]] && ! printf '%s\n' "${tool_filter[@]}" | grep -qx "$tool"; then
		aba_debug "Skipping $tool (not in filter)"
		continue
	fi

	# In --wait mode, show a message only once and only if a download is still pending
	# 2>/dev/null: peek failure is expected ("not done yet") and must be silent in DISCO mode
	if $wait_mode && ! $showed_wait_msg; then
		if ! run_once -p -i "cli:download:$item" 2>/dev/null; then
			aba_info "Ensuring CLI downloads are complete ..."
			showed_wait_msg=true
		fi
	fi

	aba_debug "$out: item=$item tool=$tool"
	aba_debug "run_once ${ro_opts[*]} -i \"cli:download:$item\" -- make -sC cli download-$tool"
	run_once "${ro_opts[@]}" -i "cli:download:$item" -- make -sC cli download-$tool
done
aba_debug "All CLI download tasks initiated"
