#!/usr/bin/env bash
# =============================================================================
# E2E Framework v2 -- Dispatcher Module
# =============================================================================
# Dynamic work-queue dispatcher functions. Dispatches one suite at a time to
# free pools, monitors completion, handles retries and force-clean operations.
#
# Depends on:
#   lib/constants.sh  -- E2E_TMUX_SESSION, E2E_RC_PREFIX, E2E_DISPATCH_STATE, etc.
#   lib/remote.sh     -- _essh, _escp, _ssh_con, _con_target, _dis_target, _wait_for_ssh
#   lib/deploy.sh     -- sync_harness, sync_extras
#
# Caller must declare these arrays before calling dispatcher functions:
#   declare -A _completed=() _busy_pools=() _results=() _result_pool=()
#   declare -a _work_queue=()
#   declare -A _retried=()
# =============================================================================

_TMUX_SESSION="$E2E_TMUX_SESSION"
_RC_PREFIX="$E2E_RC_PREFIX"

_NOTIFY_STATUS_INTERVAL=3600
_last_status_notify_s=${SECONDS:-0}

# --- Process cleanup files on a pool before wiping state ----------------------

_process_pool_cleanup_files() {
	local pool_num="$1"
	_ssh_con "$pool_num" "
		_logs=\"\$HOME/.e2e-harness/logs\"
		_ok=1
		for f in \"\$_logs\"/*.cleanup \"\$_logs\"/*.mirror-cleanup; do
			[ -f \"\$f\" ] || continue
			echo \"    Processing \$(basename \"\$f\") ...\"
			_ssh_opts='-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
			while IFS=' ' read -r target abs_path; do
				[ -z \"\$abs_path\" ] && continue
				if echo \"\$f\" | grep -q '\.cleanup\$'; then
					echo \"      \$target: delete \$abs_path\"
					if ! ssh \$_ssh_opts \"\$target\" \"[ -d '\$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\$abs_path' delete || make -C '\$abs_path' delete; }\" < /dev/null 2>&1; then
						echo \"      ERROR: delete failed for \$abs_path on \$target\"
						_ok=
					fi
				else
					echo \"      \$target: uninstall \$abs_path\"
					if ! ssh \$_ssh_opts \"\$target\" \"[ -d '\$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\$abs_path' uninstall || make -C '\$abs_path' uninstall; }\" < /dev/null 2>&1; then
						echo \"      ERROR: uninstall failed for \$abs_path on \$target\"
						_ok=
					fi
				fi
			done < \"\$f\"
			if [ -n \"\$_ok\" ]; then
				rm -f \"\$f\"
			else
				echo \"    ERROR: cleanup FAILED -- keeping \$(basename \"\$f\") for investigation\"
			fi
		done
	"
}

# --- Dispatch a single suite to a pool ----------------------------------------

_dispatch_suite() {
	local pool_num="$1"
	local suite="$2"

	printf "  \033[1;36mDISPATCH:\033[0m \033[1;33m%s\033[0m -> pool %s (con%s)\n" "$suite" "$pool_num" "$pool_num"

	# Capture scrollback from previous suite before killing the session
	_ssh_con "$pool_num" "tmux capture-pane -t '$_TMUX_SESSION' -p -S - >> ~/.e2e-harness/logs/tmux-history.log 2>/dev/null" 2>/dev/null
	_ssh_con "$pool_num" "tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null"
	_ssh_con "$pool_num" "pkill -f 'runner\.sh.*$pool_num' 2>/dev/null"
	_ssh_con "$pool_num" "sudo rm -f '${_RC_PREFIX}-${suite}.rc' '${_RC_PREFIX}-${suite}.lock' /tmp/e2e-paused-*"

	# Detect SSH user change since last run on this pool
	local _prev_user=""
	_prev_user=$(_ssh_con "$pool_num" "cat /tmp/e2e-suite-user 2>/dev/null" 2>/dev/null) || true
	_prev_user="${_prev_user//[[:space:]]/}"
	local _cur_user="${CON_SSH_USER:-steve}"
	local _user_changed=""
	if [ -n "$_prev_user" ] && [ "$_prev_user" != "$_cur_user" ]; then
		_user_changed=1
		echo "    User changed ($_prev_user -> $_cur_user)"
		echo "    Processing $_prev_user's cleanup files before revert ..."
		local _old_host="${_prev_user}@con${pool_num}.${VM_BASE_DOMAIN}"
		_essh "$_old_host" "
			_logs=\"\$HOME/.e2e-harness/logs\"
			for f in \"\$_logs\"/*.cleanup \"\$_logs\"/*.mirror-cleanup; do
				[ -f \"\$f\" ] || continue
				echo \"      Processing \$(basename \"\$f\") ...\"
				_ssh_opts='-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'
				while IFS=' ' read -r target abs_path; do
					[ -z \"\$abs_path\" ] && continue
					if echo \"\$f\" | grep -q '\.cleanup\$'; then
						echo \"        \$target: delete \$abs_path\"
						ssh \$_ssh_opts \"\$target\" \"[ -d '\$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\$abs_path' delete || make -C '\$abs_path' delete; }\" < /dev/null 2>&1 || true
					else
						echo \"        \$target: uninstall \$abs_path\"
						ssh \$_ssh_opts \"\$target\" \"[ -d '\$abs_path' ] && { command -v aba >/dev/null 2>&1 && aba -y -d '\$abs_path' uninstall || make -C '\$abs_path' uninstall; }\" < /dev/null 2>&1 || true
					fi
				done < \"\$f\"
				rm -f \"\$f\"
			done
		" 2>&1 || echo "    WARNING: old user cleanup had errors (continuing with revert)"
	fi

	# Process current user's leftover cleanup files
	if [ -z "$_user_changed" ]; then
		_process_pool_cleanup_files "$pool_num"
	fi

	# Revert VMs on user change
	if [ -n "$_user_changed" ]; then
		echo "    Reverting pool $pool_num VMs to snapshot ..."
		for _vm_prefix in con dis; do
			local _vm="${_vm_prefix}${pool_num}"
			if govc snapshot.tree -vm "$_vm" 2>&1 | grep -q "pool-ready"; then
				govc snapshot.revert -vm "$_vm" "pool-ready" || { echo "    FATAL: revert $_vm failed" >&2; return 1; }
				govc vm.power -on "$_vm" || true
				echo "      $_vm: reverted to pool-ready"
			else
				echo "      $_vm: WARNING -- pool-ready snapshot not found" >&2
			fi
		done
		local _host="con${pool_num}.${VM_BASE_DOMAIN}"
		local target="${_cur_user}@${_host}"
		_wait_for_ssh "$target" 120 || { echo "    FATAL: con${pool_num} not reachable after revert" >&2; return 1; }
		echo "    con${pool_num}: SSH ready"
	fi

	# Sync latest harness
	local target
	target=$(_con_target "$pool_num")
	if ! sync_harness "$target" "$_ABA_ROOT" "$_DEPLOY_CONFIG_ENV"; then
		echo "    ERROR: harness sync to con${pool_num} failed -- skipping dispatch"
		return 1
	fi
	sync_extras "$target" "${CON_SSH_USER:-steve}"

	local _retry_arg=""
	[ -n "${_retried[$suite]:-}" ] && _retry_arg=" retry"
	local runner_cmd="bash ~/.e2e-harness/runner.sh $pool_num $suite$_retry_arg"
	_ssh_con "$pool_num" "tmux set-option -g history-limit 200000 2>/dev/null; tmux new-session -d -s '$_TMUX_SESSION' '$runner_cmd'; tmux rename-window -t '$_TMUX_SESSION' '$suite'; tmux set-option -t '$_TMUX_SESSION' remain-on-exit on"

	_busy_pools[$pool_num]="$suite"
	_result_pool[$suite]="$pool_num"
	echo "    tmux session '$_TMUX_SESSION' started on con${pool_num}"
}

# --- Check if a pool's suite has completed ------------------------------------

_check_pool() {
	local pool_num="$1"
	local suite="$2"
	local rc_content

	rc_content=$(_ssh_con "$pool_num" "cat '${_RC_PREFIX}-${suite}.rc' 2>/dev/null" 2>/dev/null) || rc_content=""
	if [ -n "$rc_content" ]; then
		rc_content="${rc_content//[^0-9]/}"
		echo "${rc_content:-255}"
		return
	fi

	local sess_alive=""
	sess_alive=$(_ssh_con "$pool_num" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null) || sess_alive=""
	if [ "$sess_alive" != "yes" ]; then
		sleep 5
		sess_alive=$(_ssh_con "$pool_num" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null) || sess_alive=""
		if [ "$sess_alive" = "yes" ]; then
			return
		fi
		echo "  WARNING: Suite '$suite' on con${pool_num} died without writing .rc (killed/crashed)" >&2
		echo "255"
	fi
}

# --- Find a free pool ---------------------------------------------------------

_find_free_pool() {
	for _p in $CLI_POOL_LIST; do
		if [ -z "${_busy_pools[$_p]:-}" ]; then
			if _essh "$(_con_target "$_p")" "true" 2>/dev/null; then
				local _has_sess=""
				_has_sess=$(_ssh_con "$_p" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null) || _has_sess=""
				[ "$_has_sess" = "yes" ] && continue
				echo "$_p"
				return 0
			fi
		fi
	done
	return 1
}

# --- Record a completed result ------------------------------------------------

_record_result() {
	local suite="$1"
	local rc="$2"
	local pool_num="${_result_pool[$suite]:-?}"

	if [ "$rc" -eq 99 ]; then
		# Framework/infrastructure failure -- re-queue to a different pool.
		# Track which pools have failed for this suite.
		local _bad_key="_bad_pools_${suite//[^a-zA-Z0-9_]/_}"
		eval "${_bad_key}=\"\${${_bad_key}:-} ${pool_num}\""
		printf "  FRAMEWORK: %-35s pool %-2s  \033[1;35mINFRA FAIL\033[0m (re-queuing)\n" "$suite" "$pool_num"
		# Don't record in _results; append to _work_queue for re-dispatch.
		# Caller handles _busy_pools unset and log collection.
		_work_queue+=("$suite")
		if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
			$NOTIFY_CMD "[e2e] INFRA FAIL: ${suite} on pool ${pool_num} (re-queued)" < /dev/null >/dev/null &
		fi
		return
	fi

	_results[$suite]="$rc"

	if [ "$rc" -eq 0 ]; then
		printf "  COMPLETED: %-35s pool %-2s  \033[1;32mPASS\033[0m\n" "$suite" "$pool_num"
	elif [ "$rc" -eq 3 ]; then
		printf "  COMPLETED: %-35s pool %-2s  \033[1;33mSKIP\033[0m\n" "$suite" "$pool_num"
	else
		printf "  COMPLETED: %-35s pool %-2s  \033[1;31mFAIL\033[0m (exit=%s)\n" "$suite" "$pool_num" "$rc"
	fi

	if [ "$rc" -ne 0 ] && [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
		local _status="FAIL (exit=$rc)"
		[ "$rc" -eq 3 ] && _status="SKIP"
		$NOTIFY_CMD "[e2e] ${_status}: ${suite} (pool ${pool_num})" < /dev/null >/dev/null &
	fi
}

# --- Collect logs from conN and disN ------------------------------------------

_collect_pool_logs() {
	local pool_num="$1"
	local log_dir="$_RUN_DIR/logs/pool${pool_num}"

	mkdir -p "$log_dir"
	local _con_target _dis_target
	_con_target=$(_con_target "$pool_num")
	_dis_target=$(_dis_target "$pool_num")
	_escp -r "${_con_target}:~/.e2e-harness/logs/*" "$log_dir/" 2>/dev/null || true
	_escp -r "${_dis_target}:~/.e2e-harness/logs/*" "$log_dir/" 2>/dev/null || true
}

# --- Detect running and completed suites (stateless reconnect) ----------------

_detect_running_and_completed() {
	echo "  Scanning pools for existing suite state ..."
	local _rc_base
	_rc_base=$(basename "$_RC_PREFIX")

	# Pass 1: detect running suites (live tmux takes precedence over stale .rc)
	local -A _running_suites=()
	for _p in $CLI_POOL_LIST; do
		local sess_exists=""
		sess_exists=$(_ssh_con "$_p" "tmux has-session -t '$_TMUX_SESSION' 2>/dev/null && echo yes" 2>/dev/null) || sess_exists=""
		if [ "$sess_exists" = "yes" ]; then
			local suite=""
			suite=$(_ssh_con "$_p" "cat /tmp/e2e-last-suites 2>/dev/null" 2>/dev/null) || suite=""
			if [ -n "$suite" ]; then
				_busy_pools[$_p]="$suite"
				_result_pool[$suite]="$_p"
				_running_suites[$suite]=1
				echo "    con${_p}: $suite still running"
			fi
		fi
	done

	# Pass 2: detect completed suites (.rc files)
	for _p in $CLI_POOL_LIST; do
		local rc_files=""
		rc_files=$(_ssh_con "$_p" "ls ${_RC_PREFIX}-*.rc 2>/dev/null" 2>/dev/null) || rc_files=""
		if [ -n "$rc_files" ]; then
			while IFS= read -r rc_file; do
				[ -z "$rc_file" ] && continue
				local fname suite rc
				fname=$(basename "$rc_file" .rc)
				suite="${fname#${_rc_base}-}"
				if [ -n "${_running_suites[$suite]:-}" ]; then
					echo "    con${_p}: $suite .rc ignored (suite is running on another pool)"
					continue
				fi
				rc=$(_ssh_con "$_p" "cat '$rc_file' 2>/dev/null" 2>/dev/null) || rc=""
				rc="${rc//[^0-9]/}"
				_completed[$suite]="${rc:-255}"
				_result_pool[$suite]="$_p"
				echo "    con${_p}: $suite completed (exit=${_completed[$suite]})"
			done <<< "$rc_files"
		fi
	done
}

# --- Force-clean helpers ------------------------------------------------------

_force_clean_all() {
	echo "  --force: wiping all suite state on all pools ..."
	for _p in $CLI_POOL_LIST; do
		_ssh_con "$_p" "
			tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null
			sudo rm -f ${_RC_PREFIX}-*.rc ${_RC_PREFIX}-*.lock /tmp/e2e-paused-*
		"
		_process_pool_cleanup_files "$_p"
		echo "    con${_p}: cleaned"
	done
	_completed=()
	_busy_pools=()
}

_force_clean_pool() {
	local pool_num="$1"
	echo "  --force: wiping suite state on con${pool_num} ..."
	_ssh_con "$pool_num" "
		tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null
		sudo rm -f ${_RC_PREFIX}-*.rc ${_RC_PREFIX}-*.lock /tmp/e2e-paused-*
	"
	_process_pool_cleanup_files "$pool_num"
	local suite_on_pool="${_busy_pools[$pool_num]:-}"
	[ -n "$suite_on_pool" ] && unset '_busy_pools[$pool_num]'
	for s in "${!_completed[@]}"; do
		if [ "${_result_pool[$s]:-}" = "$pool_num" ]; then
			unset '_completed[$s]'
			unset '_result_pool[$s]'
		fi
	done
	echo "    con${pool_num}: cleaned"
}

_force_clean_suite() {
	local _raw="$1"
	local _suite_list=()
	IFS=',' read -ra _suite_list <<< "$_raw"

	echo "  --force: wiping state for suite '$_raw' ..."
	for _p in $CLI_POOL_LIST; do
		for suite in "${_suite_list[@]}"; do
			_ssh_con "$_p" "
				running=\$(cat /tmp/e2e-last-suites 2>/dev/null) || running=''
				if [ \"\$running\" = '$suite' ]; then
					tmux kill-session -t '$_TMUX_SESSION' 2>/dev/null
				fi
				sudo rm -f '${_RC_PREFIX}-${suite}.rc' '${_RC_PREFIX}-${suite}.lock' '/tmp/e2e-paused-${suite}'
			" 2>/dev/null
		done
		local _dominated=""
		if [ -n "${_busy_pools[$_p]:-}" ]; then
			for suite in "${_suite_list[@]}"; do
				[ "${_busy_pools[$_p]}" = "$suite" ] && _dominated=1 && break
			done
		fi
		if [ -n "${_busy_pools[$_p]:-}" ] && [ -z "$_dominated" ]; then
			echo "    Skipping con${_p}: running ${_busy_pools[$_p]}"
			continue
		fi
		_process_pool_cleanup_files "$_p"
	done
	for suite in "${_suite_list[@]}"; do
		unset '_completed[$suite]'
		for _p in "${!_busy_pools[@]}"; do
			[ "${_busy_pools[$_p]}" = "$suite" ] && unset '_busy_pools[$_p]'
		done
	done
	echo "    $_raw: cleaned"
}

# --- Build work queue from suites_to_run minus completed/running --------------

_build_work_queue() {
	_work_queue=()
	for suite in "${suites_to_run[@]}"; do
		[ -n "${_completed[$suite]:-}" ] && continue
		local running=""
		for _p in "${!_busy_pools[@]}"; do
			[ "${_busy_pools[$_p]}" = "$suite" ] && running=1 && break
		done
		[ -n "$running" ] && continue
		_work_queue+=("$suite")
	done
}

# --- Write dispatch state file for read-only commands -------------------------

_write_dispatch_state() {
	{
		echo "REQUESTED=${_work_queue[*]:-}"
		echo "QUEUED_IDX=$_queue_idx"
		echo "QUEUED_TOTAL=${#_work_queue[@]}"
		local _q_remaining=()
		for (( _qi=_queue_idx; _qi<${#_work_queue[@]}; _qi++ )); do
			_q_remaining+=("${_work_queue[$_qi]}")
		done
		echo "PENDING=${_q_remaining[*]:-}"
		local _bp_str=""
		for _bp in "${!_busy_pools[@]}"; do
			_bp_str+="${_busy_pools[$_bp]} "
		done
		echo "RUNNING=${_bp_str% }"
		echo "DONE=${#_results[@]}"
		local _done_str=""
		for _ds in "${!_results[@]}"; do
			_done_str+="${_ds}:${_results[$_ds]}@${_result_pool[$_ds]:-?} "
		done
		echo "DONE_LIST=${_done_str% }"
	} > "$E2E_DISPATCH_STATE"
}

# --- Periodic status notification ---------------------------------------------

_notify_periodic_status() {
	[ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ] || return 0
	local _now_s=$SECONDS
	[ $(( _now_s - _last_status_notify_s )) -ge $_NOTIFY_STATUS_INTERVAL ] || return 0
	_last_status_notify_s=$_now_s

	local _n_ok=0 _n_fail=0 _n_skip=0
	local _notify_body=""
	for _ns in "${!_busy_pools[@]}"; do
		_notify_body+="  con${_ns}: ${_busy_pools[$_ns]} RUNNING
"
	done
	for _ns in "${!_results[@]}"; do
		local _nrc="${_results[$_ns]}"
		local _np="${_result_pool[$_ns]:-?}"
		if [ "$_nrc" -eq 0 ] 2>/dev/null; then
			_notify_body+="  con${_np}: ${_ns} PASS
"
			_n_ok=$(( _n_ok + 1 ))
		elif [ "$_nrc" -eq 3 ] 2>/dev/null; then
			_n_skip=$(( _n_skip + 1 ))
		else
			_notify_body+="  con${_np}: ${_ns} FAIL(${_nrc})
"
			_n_fail=$(( _n_fail + 1 ))
		fi
	done
	local _q_left=$(( ${#_work_queue[@]} - _queue_idx ))
	local _hdr="[e2e $(date '+%H:%M:%S')] ${#_results[@]} done (${_n_ok}ok ${_n_fail}fail), ${#_busy_pools[@]} running"
	[ "$_q_left" -gt 0 ] && _hdr+=", ${_q_left} queued"
	$NOTIFY_CMD "${_hdr}
${_notify_body}" < /dev/null >/dev/null &
}

# --- Print final summary ------------------------------------------------------

_print_final_summary() {
	echo ""
	echo "  Collecting final logs ..."

	declare -A _pools_used=()
	for s in "${!_result_pool[@]}"; do
		_pools_used[${_result_pool[$s]}]=1
	done

	for _p in "${!_pools_used[@]}"; do
		_collect_pool_logs "$_p" && echo "    Pool $_p: logs collected" || echo "    Pool $_p: WARNING: log collection failed"
	done

	echo ""
	echo "========================================"
	echo "  Final Summary"
	echo "========================================"

	local _total=0 _passed=0 _failed=0 _skipped=0 _infra=0

	for suite in "${suites_to_run[@]}"; do
		local rc="${_results[$suite]:-}"
		local pool="${_result_pool[$suite]:-?}"
		_total=$(( _total + 1 ))

		if [ -z "$rc" ]; then
			# No result at all -- check if it was an unresolved infra failure
			local _bad_key="_bad_pools_${suite//[^a-zA-Z0-9_]/_}"
			local _bad_val=""
			eval "_bad_val=\"\${${_bad_key}:-}\""
			if [ -n "$_bad_val" ]; then
				printf "  \033[1;35mINFRA\033[0m %-35s (failed on pools:%s)\n" "$suite" "$_bad_val"
				_infra=$(( _infra + 1 ))
			else
				printf "  \033[1;33m????\033[0m  %-35s pool %-2s (no result)\n" "$suite" "$pool"
			fi
			_overall_rc=1
		elif [ "$rc" -eq 0 ]; then
			printf "  \033[1;32mPASS\033[0m  %-35s pool %-2s\n" "$suite" "$pool"
			_passed=$(( _passed + 1 ))
		elif [ "$rc" -eq 3 ]; then
			printf "  \033[1;33mSKIP\033[0m  %-35s pool %-2s\n" "$suite" "$pool"
			_skipped=$(( _skipped + 1 ))
		else
			printf "  \033[1;31mFAIL\033[0m  %-35s pool %-2s (exit=%s)\n" "$suite" "$pool" "$rc"
			_failed=$(( _failed + 1 ))
			_overall_rc=1
		fi
	done

	echo ""
	local _summary="  Total: $_total  Passed: $_passed  Failed: $_failed  Skipped: $_skipped"
	[ "$_infra" -gt 0 ] && _summary+="  Infra: $_infra"
	echo "$_summary"
	echo "  Logs: $_RUN_DIR/logs/"
	echo "========================================"

	if [ -n "${NOTIFY_CMD:-}" ] && [ -x "${NOTIFY_CMD%% *}" ]; then
		local _done_detail=""
		for _ds in "${suites_to_run[@]}"; do
			local _drc="${_results[$_ds]:-}"
			local _dp="${_result_pool[$_ds]:-?}"
			if [ -z "$_drc" ]; then
				_done_detail+="  ???? $_ds (pool $_dp)
"
			elif [ "$_drc" -eq 0 ]; then
				_done_detail+="  PASS $_ds (pool $_dp)
"
			elif [ "$_drc" -eq 3 ]; then
				_done_detail+="  SKIP $_ds (pool $_dp)
"
			else
				_done_detail+="  FAIL $_ds (pool $_dp, exit=$_drc)
"
			fi
		done
		local _notify_hdr="[e2e] ALL DONE: ${_passed} passed, ${_failed} failed, ${_skipped} skipped"
		[ "$_infra" -gt 0 ] && _notify_hdr+=", ${_infra} infra"
		_notify_hdr+=" (of ${_total})"
		$NOTIFY_CMD "${_notify_hdr}
${_done_detail}Finished: $(date '+%Y-%m-%d %H:%M')" < /dev/null >/dev/null
	fi
}
