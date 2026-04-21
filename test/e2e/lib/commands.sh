#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- One-shot Subcommands
# =============================================================================
# Each public function implements a subcommand (stop, start, status, verify,
# list, destroy, reschedule).  Called from the main run.sh dispatcher.
#
# Dependencies: remote.sh, cli.sh, deploy.sh, constants.sh
# =============================================================================

# --- stop --------------------------------------------------------------------
# Kill runners on selected pools. Optionally --clean: delete clusters/mirrors.

cmd_stop() {
	local pool_list="$1"
	local all_pools="${2:-$pool_list}"
	local do_clean="${CLI_CLEAN:-}"

	# Kill the dispatcher only when stopping ALL configured pools.
	if [ "$pool_list" = "$all_pools" ]; then
		if [ -f "$E2E_DISPATCHER_PID" ]; then
			local _dpid
			_dpid=$(cat "$E2E_DISPATCHER_PID")
			if [ -n "$_dpid" ] && kill -0 "$_dpid" 2>/dev/null; then
				kill "$_dpid" && echo "Dispatcher (pid $_dpid) stopped."
			fi
			rm -f "$E2E_DISPATCHER_PID" "$E2E_DISPATCH_STATE"
		fi
	fi

	local _rc_glob="${E2E_RC_PREFIX}-*.rc ${E2E_RC_PREFIX}-*.lock /tmp/e2e-runner.rc /tmp/e2e-runner.lock /tmp/e2e-paused-*"

	echo "Stopping runners on pool(s) ${pool_list} ..."
	local p
	for p in $pool_list; do
		local target
		target=$(_con_target "$p")
		printf "  con${p}: "
		if _essh "$target" "
			_suite_user=\$(cat /tmp/e2e-suite-user 2>/dev/null) || _suite_user=\"\"
			_sudo=\"\"; [ \"\$_suite_user\" = root ] && _sudo=sudo
			\$_sudo tmux kill-session -t '$E2E_TMUX_SESSION' 2>/dev/null
			sudo rm -f $_rc_glob
			echo stopped
		"; then
			:
		else
			echo "unreachable"
		fi
	done
	echo "Done."

	# --clean: process .cleanup and .mirror-cleanup files
	if [ -n "$do_clean" ]; then
		_process_cleanup_on_pools "$pool_list"
	fi
}

# --- start -------------------------------------------------------------------
# Power on conN + disN VMs for selected pools.

cmd_start() {
	local pool_list="$1"

	_ensure_govc
	local _vmconf="$HOME/.vmware.conf"
	[ -f "$_vmconf" ] && { set -a; source "$_vmconf"; set +a; }

	echo ""
	echo "  Powering on pool VMs (pool(s) ${pool_list}) ..."
	local p
	for p in $pool_list; do
		local prefix
		for prefix in con dis; do
			local vm="${prefix}${p}"
			local _state=""
			_state=$(govc vm.info -json "$vm" | grep -o '"powerState":"[^"]*"' | head -1) || _state=""
			if [[ "$_state" == *"poweredOn"* ]]; then
				echo "    ${vm}: already on"
			elif govc vm.info "$vm" &>/dev/null; then
				govc vm.power -on "$vm"
				echo "    ${vm}: powered on"
			else
				echo "    ${vm}: not found (skipped)"
			fi
		done
	done
	echo ""
	echo "  Done. Wait ~30s for SSH, then: run.sh deploy -p ${pool_list// /,}"
}

# --- status ------------------------------------------------------------------
# Show what's running on each pool.

cmd_status() {
	local pool_list="$1"

	printf "  %-6s  %-10s  %-40s  %-8s  %s\n" "POOL" "STATE" "SUITE" "SINCE" "LAST OUTPUT"
	printf "  %-6s  %-10s  %-40s  %-8s  %s\n" "------" "----------" "----------------------------------------" "--------" "--------------------"

	local p
	for p in $pool_list; do
		local target
		target=$(_con_target "$p")
		local _info=""
		_info=$(_essh "$target" "
			_suite_user=\$(cat /tmp/e2e-suite-user 2>/dev/null) || _suite_user=\"\"
			_sudo=\"\"; [ \"\$_suite_user\" = root ] && _sudo=sudo
			_uhome=~; [ \"\$_suite_user\" = root ] && _uhome=/root
			_slog=\"\${_uhome}/.e2e-harness/logs/summary.log\"
			\$_sudo test -f \"\$_slog\" 2>/dev/null || _slog=\$(\$_sudo ls -t \${_uhome}/.e2e-harness/logs/*-summary.log 2>/dev/null | head -1)
			suite=\$(cat /tmp/e2e-last-suites 2>/dev/null) || suite=\"\"
			_ts() { stat -c %Y \"\$1\" 2>/dev/null | xargs -I{} date -d @{} +%H:%M 2>/dev/null; }
			if \$_sudo tmux has-session -t '$E2E_TMUX_SESSION' 2>/dev/null; then
				suite=\${suite:-unknown}
				rc_file=\"${E2E_RC_PREFIX}-\${suite}.rc\"
				last=\$(\$_sudo tail -1 \"\$_slog\" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
				if [ -f \"\$rc_file\" ]; then
					rc=\$(cat \"\$rc_file\" 2>/dev/null)
					_since=\$(_ts \"\$rc_file\")
					echo \"DONE|\${suite}|exit=\${rc}|\${_since}\"
				elif [ -f \"/tmp/e2e-paused-\${suite}\" ]; then
					_since=\$(_ts \"/tmp/e2e-paused-\${suite}\")
					echo \"PAUSED|\${suite}|\${last}|\${_since}\"
				else
					_since=\$(_ts /tmp/e2e-last-suites)
					echo \"RUNNING|\${suite}|\${last}|\${_since}\"
				fi
			else
				if [ -n \"\$suite\" ]; then
					rc_file=\"${E2E_RC_PREFIX}-\${suite}.rc\"
					if [ -f \"\$rc_file\" ]; then
						rc=\$(cat \"\$rc_file\" 2>/dev/null)
						_since=\$(_ts \"\$rc_file\")
						echo \"FINISHED|\${suite}|exit=\${rc}|\${_since}\"
					else
						echo \"IDLE|\${suite}|(no result)|\"
					fi
				else
					echo \"IDLE|-|-|\"
				fi
			fi
			echo '|||TABLE|||'
			\$_sudo tac \"\$_slog\" 2>/dev/null \\
				| awk 'BEGIN{p=0} /====/{if(p)exit; p=1; next} p{print}' \\
				| tac \\
				| sed 's/\x1b\[[0-9;]*m//g' \\
				| grep -E 'PASS|FAIL|SKIP|RUNNING|PENDING|  --' \\
				| sed 's/^[0-9: ]*//'
		" 2>/dev/null || echo "UNREACHABLE|-|-|")

		local _status_line="${_info%%|||TABLE|||*}"
		local _table_data="${_info#*|||TABLE|||}"
		_table_data="$(echo "$_table_data" | sed '/^[[:space:]]*$/d')"

		local _state _suite _detail _since
		IFS='|' read -r _state _suite _detail _since <<< "$_status_line"
		local _sc
		case "$_state" in
			RUNNING)     _sc="\033[1;32m" ;;
			PAUSED)      _sc="\033[1;33m" ;;
			DONE)        if [[ "$_detail" == *"exit=0"* ]]; then _sc="\033[1;32m"; else _sc="\033[1;31m"; fi ;;
			FINISHED)    if [[ "$_detail" == *"exit=0"* ]]; then _sc="\033[32m";   else _sc="\033[1;31m"; fi ;;
			IDLE)        _sc="\033[0m" ;;
			UNREACHABLE) _sc="\033[90m" ;;
			*)           _sc="\033[0m" ;;
		esac

		if [[ "$_state" == "UNREACHABLE" ]]; then
			printf "  con%-3s  ${_sc}%-10s\033[0m\n" "$p" "$_state"
			continue
		elif [[ "$_state" == "RUNNING" || "$_state" == "PAUSED" ]]; then
			printf "  con%-3s  ${_sc}%-10s\033[0m  %-40s  %s\033[0m\n" "$p" "$_state" "$_suite" "$_since"
		else
			printf "  con%-3s  ${_sc}%-10s\033[0m  %-40s  %-8s  %s\033[0m\n" "$p" "$_state" "$_suite" "$_since" "$_detail"
		fi

		if [ -n "$_table_data" ]; then
			if [[ "$_state" == "FINISHED" && "$_detail" != *"exit=0"* ]]; then
				_table_data="${_table_data//RUNNING.../FAIL}"
			fi
			if [[ "$_state" == "IDLE" ]]; then
				_table_data="${_table_data//RUNNING.../INT}"
			fi
			while IFS= read -r _tline; do
				[[ "$_tline" == *---* ]] && continue
				if [[ "$_tline" == *PASS* ]]; then
					_tline="${_tline/PASS/$'\033[32mPASS\033[0m'}"
				elif [[ "$_tline" == *FAIL* ]]; then
					_tline="${_tline/FAIL/$'\033[1;31mFAIL\033[0m'}"
				elif [[ "$_tline" == *RUNNING* ]]; then
					if [[ "$_state" == "PAUSED" ]]; then
						_tline="${_tline/RUNNING.../$'\033[1;33mPAUSED...\033[0m'}"
					else
						_tline="${_tline/RUNNING.../$'\033[1;36mRUNNING...\033[0m'}"
					fi
					if [[ ( "$_state" == "RUNNING" || "$_state" == "PAUSED" ) && -n "$_detail" ]]; then
						_tline+="  $_detail"
						_detail=""
					fi
				elif [[ "$_tline" == *SKIP* ]]; then
					_tline="${_tline/SKIP/$'\033[33mSKIP\033[0m'}"
				elif [[ "$_tline" == *INT* ]]; then
					_tline="${_tline/INT/$'\033[90mINT\033[0m'}"
				fi
				printf "           %s\n" "$_tline"
			done <<< "$_table_data"
		fi
	done

	# Dispatcher status section
	_show_dispatcher_status
}

_show_dispatcher_status() {
	if [ -f "$E2E_DISPATCHER_PID" ] && kill -0 "$(cat "$E2E_DISPATCHER_PID")" 2>/dev/null; then
		printf "  Dispatcher: \033[1;32mRUNNING\033[0m (pid %s)" "$(cat "$E2E_DISPATCHER_PID")"
		if [ -f "$E2E_DISPATCH_STATE" ]; then
			local _ds_pending _ds_running _ds_done _ds_done_list
			_ds_pending=$(grep '^PENDING=' "$E2E_DISPATCH_STATE" | cut -d= -f2-)
			_ds_running=$(grep '^RUNNING=' "$E2E_DISPATCH_STATE" | cut -d= -f2-)
			_ds_done=$(grep '^DONE=' "$E2E_DISPATCH_STATE" | cut -d= -f2-)
			_ds_done_list=$(grep '^DONE_LIST=' "$E2E_DISPATCH_STATE" | cut -d= -f2-)
			echo ""

			if [ -n "$_ds_running" ]; then
				# shellcheck disable=SC2086
				set -- $_ds_running; local _n_active=$#
				printf "    Active (%d):  %s\n" "$_n_active" "${_ds_running// /  |  }"
			fi

			# Merge injected suites into pending display
			local _ds_injected=""
			if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
				_ds_injected=$(tr '\n' ' ' < "$E2E_INJECT_QUEUE" | sed 's/ *$//')
			fi
			if [ -n "$_ds_injected" ] && [ -n "$_ds_pending" ]; then
				_ds_pending="$_ds_injected $_ds_pending"
			elif [ -n "$_ds_injected" ]; then
				_ds_pending="$_ds_injected"
			fi
			if [ -n "$_ds_pending" ]; then
				# shellcheck disable=SC2086
				set -- $_ds_pending; local _n_pending=$#
				printf "    Pending (%d): %s\n" "$_n_pending" "${_ds_pending// /  |  }"
			fi

			if [ -n "$_ds_done" ] && [ "$_ds_done" -gt 0 ] 2>/dev/null; then
				local _done_summary=""
				local _entry
				for _entry in $_ds_done_list; do
					local _s="${_entry%%:*}"
					local _rc_pool="${_entry#*:}"
					local _rc="${_rc_pool%%@*}"
					local _pool="${_rc_pool#*@}"
					if [ "$_rc" = "0" ]; then
						_done_summary+="$_s (\033[32mPASS\033[0m) "
					else
						_done_summary+="$_s (\033[1;31mFAIL\033[0m/exit=$_rc,con$_pool) "
					fi
				done
				printf "    Done (%s):    %b\n" "$_ds_done" "${_done_summary% }"
			fi
		else
			echo ""
		fi
	else
		printf "  Dispatcher: \033[90mnot running\033[0m\n"
	fi
}

# --- verify ------------------------------------------------------------------
# Run ALL infrastructure checks. Don't stop on first failure.

cmd_verify() {
	local pool_list="$1"
	local run_dir="$2"
	local pools_file="${run_dir}/pools.conf"

	echo ""
	echo "=== Verifying pool VMs (pools ${pool_list}) ==="
	local _p _any_failed=0
	for _p in $pool_list; do
		"$BASH" "${run_dir}/setup-infra.sh" --verify --pool "$_p" --pools-file "$pools_file" || {
			echo "FAILED: Verification of pool $_p failed" >&2
			_any_failed=1
		}
	done
	if [ "$_any_failed" -eq 1 ]; then
		echo ""
		echo "ERROR: One or more pool verifications failed (see above)" >&2
		return 1
	fi
}

# --- list --------------------------------------------------------------------
# Show available test suites.

cmd_list() {
	local run_dir="$1"
	echo "Available suites:"
	echo ""
	local f
	for f in "${run_dir}/suites/"suite-*.sh; do
		[ -f "$f" ] || continue
		local name desc
		name="$(basename "$f" .sh)"
		name="${name#suite-}"
		desc="$(grep -m1 '^# Suite:' "$f" | sed 's/^# Suite: *//')"
		printf "  %-35s %s\n" "$name" "$desc"
	done
	echo ""
	echo "Run:  run.sh run --suite <name>"
	echo "      run.sh run -p all"
}

# --- destroy -----------------------------------------------------------------
# Destroy pool VMs. Optionally --clean first.

cmd_destroy() {
	local pool_list="$1"

	_ensure_govc
	local _vmconf="$HOME/.vmware.conf"
	[ -f "$_vmconf" ] && { set -a; source "$_vmconf"; set +a; }

	# --clean: delete clusters/mirrors before destroying VMs
	if [ -n "${CLI_CLEAN:-}" ]; then
		echo "=== Cleaning up test clusters and mirrors on pool VMs ==="
		_process_cleanup_on_pools "$pool_list"
		echo ""
	fi

	echo "=== Destroying pool VMs ==="
	local p
	for p in $pool_list; do
		local prefix
		for prefix in con dis; do
			local vm="${prefix}${p}"
			if govc vm.info "$vm" | grep "Name:" >/dev/null 2>&1; then
				echo "  Destroying $vm ..."
				govc vm.power -off "$vm" || true
				govc vm.destroy "$vm"
			fi
		done
	done

	# Sweep for orphaned cluster VMs in pool folders
	_sweep_orphan_vms "$pool_list"
	echo "=== Done ==="
}

# --- reschedule --------------------------------------------------------------
# Inject suites into the running dispatcher's queue.

cmd_reschedule() {
	local run_dir="$1"
	shift
	local suites_to_run=("$@")

	echo ""
	echo "=== Reschedule: injecting into dispatcher queue ==="
	local suite
	for suite in "${suites_to_run[@]}"; do
		if [ -f "$E2E_INJECT_QUEUE" ] && [ -s "$E2E_INJECT_QUEUE" ]; then
			local _existing
			_existing=$(cat "$E2E_INJECT_QUEUE")
			printf '%s\n%s\n' "$suite" "$_existing" > "$E2E_INJECT_QUEUE"
		else
			echo "$suite" > "$E2E_INJECT_QUEUE"
		fi
		printf "  Queued: \033[1;36m%s\033[0m (front)\n" "$suite"
	done
	echo ""
	if [ -f "$E2E_DISPATCHER_PID" ] && kill -0 "$(cat "$E2E_DISPATCHER_PID")" 2>/dev/null; then
		echo "  Dispatcher is running -- will pick this up on its next cycle (~30s)."
	else
		echo "  WARNING: No dispatcher running. Start one with: run.sh run -p all"
	fi
	echo "  Tip: if you changed suite code, run 'deploy --force' first."
	echo ""
}

# --- deploy (command) --------------------------------------------------------
# Full developer deploy: push source + harness to conN.

cmd_deploy() {
	local pool_list="$1"
	local aba_root="$2"
	local deploy_config="$3"

	echo ""
	echo "  Developer deploy: source + harness push to conN (${pool_list}) ..."

	local _deploy_tar
	_deploy_tar=$(_make_source_tar "$aba_root")
	local _deploy_size
	_deploy_size=$(du -h "$_deploy_tar" | cut -f1)
	echo "  Source tarball: $_deploy_size"
	echo ""

	local p
	for p in $pool_list; do
		deploy_pool "$p" "$aba_root" "$deploy_config" "$_deploy_tar"
	done

	rm -f "$_deploy_tar"
	echo ""
	echo "  Deploy complete."
}

# --- Internal helpers --------------------------------------------------------

_ensure_govc() {
	if command -v govc &>/dev/null; then
		return 0
	fi
	local _aba_root="${_ABA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
	if [ -f "$_aba_root/scripts/include_all.sh" ]; then
		source "$_aba_root/scripts/include_all.sh"
		if ensure_govc; then
			return 0
		fi
		echo "ERROR: govc installation failed." >&2
		exit 1
	fi
	echo "ERROR: govc not found. Install govc (e.g. from ABA: ensure_govc) or add it to PATH." >&2
	exit 1
}

# Process .cleanup and .mirror-cleanup files across selected pools.
_process_cleanup_on_pools() {
	local pool_list="$1"
	local _e2e_logs=".e2e-harness/logs"

	echo ""
	echo "=== Cleaning up test clusters and mirrors ==="
	local p
	for p in $pool_list; do
		local target
		target=$(_con_target "$p")

		local _has_files=""
		_has_files=$(_essh "$target" "ls ~/$_e2e_logs/*.cleanup ~/$_e2e_logs/*.mirror-cleanup 2>/dev/null | head -1" 2>/dev/null) || continue
		[ -z "$_has_files" ] && { echo "  con${p}: no cleanup files"; continue; }

		echo "  con${p}: processing cleanup files ..."
		_essh "$target" bash <<-REMOTE
			_ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
			_logs="\$HOME/$_e2e_logs"

			for f in "\$_logs"/*.cleanup; do
				[ -f "\$f" ] || continue
				echo "    Processing \$(basename "\$f") ..."
				_ok=1
				while IFS=' ' read -r target abs_path; do
					[ -z "\$abs_path" ] && continue
					echo "      \$target: delete \$abs_path"
					ssh \$_ssh_opts "\$target" \
						"[ -d '\$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\$abs_path' delete || make -C '\$abs_path' delete; } || echo '      (dir not found)'" \
						< /dev/null 2>&1 || { echo "      WARNING: cleanup failed"; _ok=; }
				done < "\$f"
				[ -n "\$_ok" ] && rm -f "\$f"
			done

			for f in "\$_logs"/*.mirror-cleanup; do
				[ -f "\$f" ] || continue
				echo "    Processing \$(basename "\$f") ..."
				_ok=1
				while IFS=' ' read -r target abs_path; do
					[ -z "\$abs_path" ] && continue
					echo "      \$target: uninstall \$abs_path"
					ssh \$_ssh_opts "\$target" \
						"[ -d '\$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\$abs_path' uninstall || make -C '\$abs_path' uninstall; } || echo '      (dir not found)'" \
						< /dev/null 2>&1 || { echo "      WARNING: cleanup failed"; _ok=; }
				done < "\$f"
				[ -n "\$_ok" ] && rm -f "\$f"
			done
		REMOTE
		echo "  con${p}: cleanup done."
	done
	echo "=== Cleanup complete ==="
}

# Sweep pool folders for orphaned cluster VMs.
_sweep_orphan_vms() {
	local pool_list="$1"
	local _base="/Datacenter/vm/aba-e2e"

	echo ""
	echo "=== Sweeping pool folders for orphaned cluster VMs ==="
	local _all_orphans=""
	local p
	for p in $pool_list; do
		local _pfolder="${_base}/pool${p}"
		local _orphans=""
		_orphans=$(govc find "$_pfolder" -type m) || continue
		[ -z "$_orphans" ] && continue
		_all_orphans+="$_orphans"$'\n'
	done
	_all_orphans="${_all_orphans%$'\n'}"

	if [ -z "$_all_orphans" ]; then
		echo "  No orphaned VMs found in pool folders."
		return
	fi

	echo "  The following VMs will be DESTROYED:"
	while IFS= read -r _ovm; do
		[ -z "$_ovm" ] && continue
		echo "    $_ovm"
	done <<< "$_all_orphans"
	echo ""

	local _answer=""
	if [ -n "${CLI_YES:-}" ]; then
		_answer="y"
	else
		printf "  Destroy these VMs? (Y/n): "
		read -r -t 60 _answer || _answer="n"
	fi

	if [[ "$_answer" =~ ^[Yy]?$ ]]; then
		while IFS= read -r _ovm; do
			[ -z "$_ovm" ] && continue
			echo "  Destroying $_ovm ..."
			govc vm.power -off "$_ovm" || true
			govc vm.destroy "$_ovm"
		done <<< "$_all_orphans"
	else
		echo "  Skipped orphan cleanup."
	fi
}

# --- Suite selection helpers -------------------------------------------------

# List all available suite names (short form, no prefix/suffix).
all_suite_names() {
	local run_dir="$1"
	local suites=()
	local f
	for f in "${run_dir}/suites/"suite-*.sh; do
		[ -f "$f" ] || continue
		local name
		name="$(basename "$f" .sh)"
		name="${name#suite-}"
		suites+=("$name")
	done
	echo "${suites[*]}"
}

# Resolve suite selection from CLI flags. Populates stdout with space-separated suite names.
resolve_suites() {
	local run_dir="$1"

	if [ -n "${CLI_RESUME:-}" ]; then
		echo "ERROR: --resume requires dispatcher context" >&2
		return 1
	elif [ -n "${CLI_ALL:-}" ]; then
		all_suite_names "$run_dir"
	elif [ -n "${CLI_SUITE:-}" ]; then
		echo "${CLI_SUITE//,/ }"
	else
		echo "ERROR: No suite selector (--all or --suite X)" >&2
		return 1
	fi
}

# Validate that suite files exist.
validate_suites() {
	local run_dir="$1"
	shift
	local suites=("$@")

	local _s
	for _s in "${suites[@]}"; do
		if [ ! -f "${run_dir}/suites/suite-${_s}.sh" ]; then
			echo "ERROR: Unknown suite '$_s' (no file: suites/suite-${_s}.sh)" >&2
			echo "  Available suites:" >&2
			local _sf
			for _sf in "${run_dir}/suites/"suite-*.sh; do
				echo "    $(basename "$_sf" .sh | sed 's/^suite-//')" >&2
			done
			return 1
		fi
	done
}
