#!/usr/bin/env bash
# =============================================================================
# E2E Framework -- Shared cleanup (cluster delete / mirror uninstall)
# =============================================================================
# Single implementation for processing .cleanup / .mirror-cleanup lists.
# Used by: dispatcher (_run_cleanup_on_host), runner (_pre_suite_cleanup),
#          framework (e2e_cleanup_clusters / e2e_cleanup_mirrors).
#
# GOLDEN RULES:
#   1. ALWAYS use aba -d <dir> delete / uninstall / unregister.
#   2. If aba fails → STOP. Keep the cleanup file for investigation.
#      NEVER force-clean / rm -rf registry state after an aba failure.
#   3. If the cluster/mirror dir is already gone → success (nothing to do).
#      (aba -d requires the directory to exist, so we short-circuit here.)
#
# Depends on: lib/remote.sh (_essh)
# =============================================================================

# Delete one cluster via aba. Success if dir already gone.
# Usage: _e2e_cleanup_cluster_entry <user@host> <abs_path>
_e2e_cleanup_cluster_entry() {
	local target="$1"
	local abs_path="$2"

	_essh "$target" \
		"if [ ! -d '$abs_path' ]; then
			echo '  (cluster dir $abs_path already gone -- nothing to delete)'
			exit 0
		fi
		\$HOME/.e2e-harness/bin/aba -y -d '$abs_path' delete --force" \
		< /dev/null
}

# Uninstall/unregister one mirror via aba. Success if dir already gone.
# After successful aba: remove suite-created dirs (not the pool 'mirror/' dir).
# Usage: _e2e_cleanup_mirror_entry <user@host> <abs_path>
_e2e_cleanup_mirror_entry() {
	local target="$1"
	local abs_path="$2"

	_essh "$target" \
		"if [ ! -d '$abs_path' ]; then
			echo '  (mirror dir $abs_path already gone -- nothing to uninstall)'
			exit 0
		fi
		_state=\$HOME/.aba/mirror/\$(basename '$abs_path')/state.sh
		if [ -f '$abs_path/regcreds/state.sh' ]; then
			_state='$abs_path/regcreds/state.sh'
		fi
		if grep -qs 'reg_vendor=existing' \"\$_state\" 2>/dev/null; then
			echo '  Externally-managed registry -- using unregister'
			\$HOME/.e2e-harness/bin/aba -y -d '$abs_path' unregister || exit 1
		else
			\$HOME/.e2e-harness/bin/aba -y -d '$abs_path' uninstall || exit 1
		fi
		# Post-success only: drop suite-created working dirs (never after aba failure)
		if [ \"\$(basename '$abs_path')\" != mirror ]; then
			rm -rf '$abs_path'
		else
			echo '  (preserving pool mirror dir)'
		fi" \
		< /dev/null
}

# Return 0 if hostname (no user@) is in the allowed set (space- or comma-separated).
_e2e_host_allowed() {
	local host="$1"
	local allowed="${2:-}"
	[ -z "$allowed" ] && return 0
	local a
	for a in ${allowed//,/ }; do
		[ "$host" = "$a" ] && return 0
	done
	return 1
}

# Process one .cleanup or .mirror-cleanup file (local path).
# On full success (no foreign entries): removes the file.
# On aba failure: keeps the file and returns 1.
# Usage: _e2e_process_one_cleanup_file <file> <cluster|mirror> <allowed_hosts>
#   allowed_hosts: space- or comma-separated hostnames; empty = allow all
_e2e_process_one_cleanup_file() {
	local file="$1"
	local kind="$2"
	local allowed="${3:-}"
	local indent="${4:-  }"

	[ -f "$file" ] || return 0

	echo "${indent}Processing $(basename "$file") ..."
	echo "${indent}  Contents: $(tr '\n' ' ' < "$file")"

	local target abs_path _file_ok=1 _has_foreign=""
	while IFS=' ' read -r target abs_path; do
		[ -z "$abs_path" ] && continue
		local _tgt_host="${target#*@}"
		if ! _e2e_host_allowed "$_tgt_host" "$allowed"; then
			echo "${indent}  WARNING: cross-pool target $target skipped (allowed: ${allowed//,/, })"
			_has_foreign=1
			continue
		fi
		if [ "$kind" = cluster ]; then
			echo "${indent}  $target: aba -y -d $abs_path delete --force"
			if ! _e2e_cleanup_cluster_entry "$target" "$abs_path"; then
				echo "${indent}  ERROR: aba delete failed for $abs_path on $target"
				echo "${indent}  STOPPING -- investigate aba failure (do not force-clean)"
				_file_ok=""
			fi
		else
			echo "${indent}  $target: aba -y -d $abs_path uninstall|unregister"
			if ! _e2e_cleanup_mirror_entry "$target" "$abs_path"; then
				echo "${indent}  ERROR: aba uninstall/unregister failed for $abs_path on $target"
				echo "${indent}  STOPPING -- investigate aba failure (do not force-clean)"
				_file_ok=""
			fi
		fi
	done < "$file"

	if [ -n "$_has_foreign" ]; then
		echo "${indent}  Keeping $(basename "$file") -- contains cross-pool entries"
		return 0
	elif [ -n "$_file_ok" ]; then
		rm -f "$file"
		return 0
	else
		echo "${indent}  ERROR: cleanup FAILED -- keeping $(basename "$file") for investigation"
		return 1
	fi
}

# Process all *.cleanup and *.mirror-cleanup files in a local directory.
# Usage: _e2e_process_cleanup_dir <logs_dir> <allowed_hosts> [indent]
_e2e_process_cleanup_dir() {
	local logs_dir="$1"
	local allowed="${2:-}"
	local indent="${3:-  }"
	local _all_ok=1 f

	[ -d "$logs_dir" ] || return 0

	for f in "$logs_dir"/*.cleanup; do
		[ -f "$f" ] || continue
		_e2e_process_one_cleanup_file "$f" cluster "$allowed" "$indent" || _all_ok=""
	done
	for f in "$logs_dir"/*.mirror-cleanup; do
		[ -f "$f" ] || continue
		_e2e_process_one_cleanup_file "$f" mirror "$allowed" "$indent" || _all_ok=""
	done

	[ -n "$_all_ok" ]
}
