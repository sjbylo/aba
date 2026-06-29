#!/bin/bash
# ── Contract ──────────────────────────────────────────────────────────
# Script:  cli-download-all.sh
# Purpose: Orchestrate parallel, non-blocking CLI tarball downloads.
#          run_once wraps Make from OUTSIDE (ADR-002 boundary rule).
#
# Modes (mutually exclusive):
#   (default)      Start background downloads for all tools (non-blocking).
#                  run_once handles backgrounding internally — no '&'.
#   --wait         Block until every download task has completed.
#                  run_once reloads command from saved cmd.sh — no command needed.
#   --reset        Reset download task state (forces re-download on next run).
#   --no-version   Only start downloads for version-independent tools
#                  (oc-mirror, butane, govc) — used when ocp_version is unknown.
#   --target-version <ver>  Download oc + openshift-install for <ver> (parallel).
#                  Used by reg-save.sh to fetch CLIs for upgrade target version.
#
# Optional positional args after the mode flag are tool names to filter on.
#   e.g.  cli-download-all.sh --wait oc openshift-install
#   No tool args = all tools.
#
# Inputs:
#   cli/Makefile targets: out-download-all | out-download-no-version
#   Each target outputs "tool[:version] ..." (e.g. "oc:4.20.12 oc-mirror butane govc")
#
# Task IDs:
#   cli:download:<item> where <item> includes version suffix for versioned tools.
#   e.g. "cli:download:oc:4.20.12", "cli:download:govc", "cli:download:oc-mirror"
#   These match what ensure_*() functions wait on.
#
# Callers (9+): aba.sh, include_all.sh, Makefile (tar/tarrepo), cli/Makefile,
#   reg-save.sh, make-bundle.sh, tui/v2/abatui2.sh, cli-install-all.sh
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
target_ocp_version=""

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

if [ "${1:-}" = "--target-version" ]; then
	target_ocp_version="$2"
	shift 2
fi

tool_filter=("$@")

aba_debug "Mode: $mode filter=[${tool_filter[*]}] list_target=$make_list_target target_ver=$target_ocp_version"

export PLAIN_OUTPUT=1
aba_debug "PLAIN_OUTPUT=1 (suppressing progress indicators)"

showed_wait_msg=false

# When --target-version is given, override ocp_version for the make calls
if [ "$target_ocp_version" ]; then
	make_ocp_override="ocp_version=$target_ocp_version"
else
	make_ocp_override=""
fi

aba_debug "Fetching download list from cli/Makefile ($make_list_target)"
items=$(make --no-print-directory -sC cli "$make_list_target" $make_ocp_override) || {
	aba_abort "Failed to get download list from cli/Makefile ($make_list_target)"
}

for item in $items
do
	tool="${item%%:*}"  # strip version tag for filtering (e.g. "oc:4.20.12" -> "oc")

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

	# Task ID includes version suffix for versioned tools (e.g. cli:download:oc:4.20.12)
	task_id="cli:download:$item"

	aba_debug "$mode: item=$item tool=$tool task_id=$task_id"

	if [[ "$mode" == "reset" ]]; then
		run_once -r -i "$task_id"
	elif [[ "$mode" == "wait" ]]; then
		# Already complete? Skip silently.
		if run_once -p -i "$task_id"; then
			aba_debug "CLI download already complete: $tool"
			continue
		fi
		if ! $showed_wait_msg; then
			aba_info "Ensuring CLI downloads are complete ..."
			showed_wait_msg=true
		fi
		# Idempotent start (guarantees cmd.sh exists for the wait)
		run_once -i "$task_id" -- make -sC cli download-$tool $make_ocp_override
		# Wait without command — run_once reloads from saved cmd.sh
		if ! run_once -q -w -i "$task_id"; then
			# govc download failure is non-fatal for non-vmw platforms
			if [[ "$tool" == "govc" && "${platform:-}" != "vmw" ]]; then
				aba_warning "govc failed to download — ignoring since platform != vmw."
			else
				aba_error "Download failed for $tool"
				exit 1
			fi
		fi
	else
		# Skip download if an install task for this tool is already running or
		# done — the install's make handles the download via file prerequisites.
		# Starting both would race on the same tarball (ADR-008 Finding 5).
		inst_task=""
		case "$tool" in
			oc-mirror)          inst_task="$TASK_INST_OC_MIRROR" ;;
			oc)                 inst_task="$TASK_INST_OC" ;;
			openshift-install)  inst_task="$TASK_INST_OPENSHIFT_INSTALL" ;;
			govc)               inst_task="$TASK_INST_GOVC" ;;
			butane)             inst_task="$TASK_INST_BUTANE" ;;
		esac
		if [[ -n "$inst_task" ]] && run_once -A -i "$inst_task" 2>/dev/null; then
			aba_debug "Skipping download for $tool — install task running or done"
			continue
		fi

		# Start mode: run_once backgrounds internally — no '&' needed
		run_once -i "$task_id" -- make -sC cli download-$tool $make_ocp_override
	fi
done
aba_debug "All CLI download tasks processed"
