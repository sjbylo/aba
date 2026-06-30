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
[ "$1" = "--wait" ] && ro_opt="-q -w" && out=Waiting && shift
[ "$1" = "--reset" ] && ro_opt=-r && out=Resetting && shift
tool_filter=("$@")  # remaining args are tool names (empty = all)
aba_debug "Mode: $out (ro_opt=$ro_opt) filter=[${tool_filter[*]}]"

export PLAIN_OUTPUT=1

# CRITICAL: Wait for tarball downloads to complete before starting extractions.
# Without this, 'make -sC cli <tool>' sees a partially downloaded tarball (curl still
# writing) and starts 'tar' on it, producing a truncated/corrupt binary (segfault).
# In bundle mode, tarballs are already in the archive -- no downloads to wait for.
if [ "$ro_opt" != "-r" ] && ! is_bundle_mode; then
	aba_debug "Waiting for CLI downloads to complete before extracting"
	scripts/cli-download-all.sh --wait "${tool_filter[@]}"
	aba_debug "CLI downloads complete"
fi

# Version guard: if ocp_version changed, the installed binary is stale but Make
# can't detect this when the binary is newer than the tarball (e.g. after a
# downgrade).  Backdate the binary so Make re-extracts from the correct tarball.
if [ "$ro_opt" != "-r" ]; then
	_ver=$(source aba.conf 2>/dev/null && echo "$ocp_version")
	for _bin in oc openshift-install; do
		if [ -x ~/bin/$_bin ] && [ "$_ver" ] && ! ~/bin/$_bin version 2>/dev/null | grep -q "$_ver"; then
			aba_debug "Version mismatch: ~/bin/$_bin does not match ocp_version=$_ver, backdating"
			touch -t 200001010000 ~/bin/$_bin
			run_once -r -i "cli:install:$_bin" 2>/dev/null || true
			run_once -r -i "cli:install:$_bin:$_ver" 2>/dev/null || true
		fi
	done
fi

showed_msg=false
for item in $(make --no-print-directory -sC cli out-install-all)
do
	# If a filter was given, skip tools not in the list
	if [[ ${#tool_filter[@]} -gt 0 ]] && ! printf '%s\n' "${tool_filter[@]}" | grep -qx "$item"; then
		aba_debug "Skipping $item (not in filter)"
		continue
	fi

	task_id="cli:install:$item"

	# In wait mode, peek first — skip silently if already complete
	if [[ "$ro_opt" == *"-w"* ]]; then
		if run_once -p -i "$task_id"; then
			aba_debug "CLI install already complete: $item"
			continue
		fi
		if ! $showed_msg; then
			aba_info "Ensuring CLI binaries are installed"
			showed_msg=true
		fi
	fi

	aba_debug "$out: item=$item"
	aba_debug "run_once $ro_opt -i \"$task_id\" -- make -sC cli $item"
	# Start: CLI install in background. Wait: ensure_oc(), ensure_openshift_install() etc in include_all.sh
	run_once $ro_opt -i "$task_id" -- make -sC cli $item
done

exit 0
