#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- tmux Dashboard / Live / Attach
# =============================================================================
# Manages all tmux-based UI: dash (read-only tails), live (interactive
# attach with live-pane.sh), and attach (single-pool session attach).
#
# Supports up to 6 pools with flexible layouts:
#   1-2 pools: vertical split
#   3-4 pools: 2x2 grid
#   5-6 pools: 3x2 grid
#
# Dependencies: remote.sh (for _essh, _E2E_SSH_OPTS), constants.sh
# =============================================================================

# --- Dashboard (read-only log tail) ------------------------------------------
# Usage: cmd_dash <pool_list> [log_file]

cmd_dash() {
	local pool_list="$1"
	local logfile="${CLI_DASH_LOG:-summary.log}"
	local _sess="e2e-dash-user"

	local _np=0
	local _pools=()
	local _p
	for _p in $pool_list; do
		_np=$(( _np + 1 ))
		_pools+=("$_p")
	done

	_create_tmux_dashboard "$_sess" "$_np" "$logfile" "${_pools[@]}"
	echo "Attaching to dashboard (${_np} pools) ..."
	exec tmux attach -t "$_sess"
}

# --- Live (interactive multi-pane) -------------------------------------------
# Usage: cmd_live <pool_list> <run_dir>

cmd_live() {
	local pool_list="$1"
	local run_dir="$2"
	local _default_user="${CON_SSH_USER:-steve}"
	local _domain="${VM_BASE_DOMAIN}"
	local _sess="e2e-live"

	local _np=0
	local _pools=()
	local _p
	for _p in $pool_list; do
		_np=$(( _np + 1 ))
		_pools+=("$_p")
	done

	# Reuse existing live session if it has the right number of panes
	local _existing_panes=0
	_existing_panes=$(tmux list-panes -t "$_sess" | wc -l) || _existing_panes=0
	if [ "$_existing_panes" -eq "$_np" ]; then
		echo "Live session already running with $_np panes -- reattaching."
		if [ -n "${TMUX:-}" ]; then
			exec tmux switch-client -t "$_sess"
		else
			exec tmux attach -t "$_sess"
		fi
	fi

	tmux kill-session -t "$_sess"
	tmux set-option -g history-limit 50000

	# Claim ownership on each conN (prevents competing live dashboards)
	local _live_id="$$-$(date +%s)"
	for _p in "${_pools[@]}"; do
		_essh "$(_con_target "$_p" "$_default_user")" \
			"sudo rm -f /tmp/e2e-live-owner; echo '$_live_id' > /tmp/e2e-live-owner" || true
	done

	# Clean up own temp dirs from previous runs
	find /tmp -maxdepth 1 -name 'e2e-live.*' -user "$(id -un)" -exec rm -rf {} +; true
	local _live_script_dir
	_live_script_dir=$(mktemp -d /tmp/e2e-live.XXXXXX)

	# Create layout
	_create_pane_layout "$_sess" "$_np" "_live_create_pane_script" "${_pools[@]}"

	tmux set-option -t "$_sess" alternate-screen off
	tmux set-option -t "$_sess" allow-rename on
	tmux set-option -t "$_sess" pane-border-status top
	tmux set-option -t "$_sess" pane-border-format " #{pane_title} "

	echo "Live dashboard (${_np} pools) -- Ctrl-a + arrow to switch panes, Ctrl-a Ctrl-a [ to scroll remote"
	if [ -n "${TMUX:-}" ]; then
		exec tmux switch-client -t "$_sess"
	else
		exec tmux attach -t "$_sess"
	fi
}

# Helper: create a per-pool live pane script.
_live_create_pane_script() {
	local p="$1"
	local _h="con${p}.${_domain}"
	local _so="$_E2E_SSH_OPTS"
	local _script="${_live_script_dir}/pool${p}.sh"
	{
		echo '#!/bin/bash'
		echo 'stty -ixon'
		echo "export _POOL_NUM=$p"
		echo "export _DOMAIN='${_domain}'"
		echo "export _SSH_OPTS='$_so'"
		echo "export _DEFAULT_USER='${_default_user}'"
		echo "export _LIVE_ID='${_live_id}'"
		echo "export _E2E_TMUX_SESSION='${E2E_TMUX_SESSION}'"
		echo "_PANE_SCRIPT='${run_dir}/scripts/live-pane.sh'"
		echo 'while true; do'
		echo '  if [ -f "$_PANE_SCRIPT" ]; then'
		echo '    source "$_PANE_SCRIPT"'
		echo '  else'
		echo "    _suite=\$(ssh $_so ${_default_user}@${_h} 'cat /tmp/e2e-last-suites')"
		echo "    _os=\$(ssh $_so ${_default_user}@${_h} 'cat /tmp/e2e-suite-os')"
		echo "    _vmconf=\$(ssh $_so ${_default_user}@${_h} 'cat /tmp/e2e-suite-vmconf')"
		echo '    _vmtag=""'
		echo '    [ -n "$_vmconf" ] && [ "$_vmconf" != "~/.vmware.conf" ] && _vmtag=" | $(basename "$_vmconf")"'
		printf "    printf '\\\\033]2;live | Pool %d | ${_default_user}%%s%%s%%s\\\\033\\\\\\\\' \"\${_suite:+ | \$_suite}\" \"\${_os:+ | \$_os}\" \"\$_vmtag\"\n" "$p"
		echo '    clear'
		echo "    ssh -t $_so ${_default_user}@${_h} \"tmux has-session -t '${E2E_TMUX_SESSION}' && exec tmux attach -d -t '${E2E_TMUX_SESSION}'\" || {"
		echo "      echo 'No e2e session on pool ${p}. Waiting for suite to start...'"
		echo '    }'
		echo '    sleep 5'
		echo '  fi'
		echo 'done'
	} > "$_script"
	chmod +x "$_script"
	echo "$_script"
}

# --- Attach (single-pool session) --------------------------------------------
# Works from inside tmux or a bare terminal.
# Usage: cmd_attach <host> [user]

cmd_attach() {
	local host="$1"
	local user="${CON_SSH_USER:-steve}"
	local domain="${VM_BASE_DOMAIN}"

	# Accept "conN" or "conN.domain"
	case "$host" in
		*.*) ;;
		*)   host="${host}.${domain}" ;;
	esac

	echo "Attaching to tmux on ${user}@${host} ..."
	exec ssh -t -o LogLevel=ERROR "${user}@${host}" \
		"if tmux has-session -t '$E2E_TMUX_SESSION'; then \
		   tmux attach -t '$E2E_TMUX_SESSION'; \
		 else echo 'No e2e session found on ${host}.'; tmux list-sessions || echo '(no tmux sessions)'; fi"
}

# --- Shared dashboard builder ------------------------------------------------
# Creates a tmux session with one tail pane per pool.
# Usage: _create_tmux_dashboard SESSION_NAME NUM_POOLS LOG_FILE POOL_NUMS...

_create_tmux_dashboard() {
	local _sess="$1" _np="$2" _logfile="${3:-summary.log}"
	shift 3
	local _pool_nums=("$@")

	local _user="${CON_SSH_USER:-steve}"
	local _domain="${VM_BASE_DOMAIN}"

	# Build per-pool tail command with suite-change detection
	_dash_pane_cmd() {
		local _p=$1
		local _h="con${_p}.${_domain}"
		local _so="$_E2E_SSH_OPTS"
		local _sess_name="${E2E_TMUX_SESSION:-e2e-suite}"
		echo "while true; do"\
" _u=\$(ssh $_so \${_u:-${_user}}@${_h} 'cat /tmp/e2e-suite-user');"\
" _u=\${_u:-${_user}};"\
" _os=\$(ssh $_so \${_u}@${_h} 'cat /tmp/e2e-suite-os');"\
" _vc=\$(ssh $_so \${_u}@${_h} 'cat /tmp/e2e-suite-vmconf');"\
" _vt=''; [ -n \"\$_vc\" ] && [ \"\$_vc\" != '~/.vmware.conf' ] && _vt=\" | \$(basename \"\$_vc\")\";"\
" if ssh $_so \${_u}@${_h} 'tmux has-session -t ${_sess_name}'; then"\
"   _s=\$(ssh $_so \${_u}@${_h} 'cat /tmp/e2e-last-suites');"\
"   printf '\\033]2;dashboard | Pool ${_p} | %s%s%s%s\\033\\\\' \"\${_u}\" \"\${_s:+ | \$_s}\" \"\${_os:+ | \$_os}\" \"\$_vt\";"\
"   clear;"\
"   ssh $_so \${_u}@${_h} 'tail -F -n 500 ~/.e2e-harness/logs/${_logfile}' & _tpid=\$!;"\
"   while kill -0 \$_tpid; do"\
"     sleep 10;"\
"     _ns=\$(ssh $_so \${_u}@${_h} 'cat /tmp/e2e-last-suites');"\
"     [ -n \"\$_ns\" ] && [ \"\$_ns\" != \"\$_s\" ] && kill \$_tpid && break;"\
"   done;"\
"   wait \$_tpid;"\
" else"\
"   printf '\\033]2;dashboard | Pool ${_p} | %s | (idle)%s%s\\033\\\\' \"\${_u}\" \"\${_os:+ | \$_os}\" \"\$_vt\";"\
"   clear;"\
"   echo 'No e2e session on pool ${_p}. Waiting for suite to start...';"\
"   sleep 5;"\
" fi;"\
" done"
	}

	# Reuse existing dashboard if it has the right number of panes
	local _existing_panes=0
	_existing_panes=$(tmux list-panes -t "$_sess" | wc -l) || _existing_panes=0
	if [ "$_existing_panes" -eq "$_np" ]; then
		return 0
	fi

	tmux kill-session -t "$_sess"

	# Build layout based on pool count (supports up to 6)
	_create_pane_layout "$_sess" "$_np" "_dash_pane_cmd" "${_pool_nums[@]}"

	tmux set-option -t "$_sess" allow-rename on
	tmux set-option -t "$_sess" pane-border-status top
	tmux set-option -t "$_sess" pane-border-format " #{pane_title} "
}

# --- Layout builder (supports 1-6 pools) ------------------------------------
# Creates tmux panes using the given command generator function.
# Usage: _create_pane_layout SESSION NUM_POOLS CMD_FUNC POOL_NUMS...
#
# CMD_FUNC is called as: CMD_FUNC <pool_num> -- must echo the command string.

_create_pane_layout() {
	local _sess="$1" _np="$2" _cmd_func="$3"
	shift 3
	local _pool_nums=("$@")

	# If pool_nums not provided, generate 1..N
	if [ ${#_pool_nums[@]} -eq 0 ]; then
		local _i
		for (( _i=1; _i<=_np; _i++ )); do
			_pool_nums+=("$_i")
		done
	fi

	if [ "$_np" -le 2 ]; then
		# 1-2 pools: simple vertical split
		tmux new-session -d -s "$_sess" "$($_cmd_func "${_pool_nums[0]}")"
		if [ "$_np" -ge 2 ]; then
			tmux split-window -t "$_sess" -v "$($_cmd_func "${_pool_nums[1]}")"
		fi
		tmux select-layout -t "$_sess" even-vertical
	elif [ "$_np" -le 4 ]; then
		# 3-4 pools: 2x2 grid
		tmux new-session -d -s "$_sess" "$($_cmd_func "${_pool_nums[0]}")"
		local _tl
		_tl=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | head -1)
		tmux split-window -h -t "$_tl" "$($_cmd_func "${_pool_nums[1]}")"
		local _tr
		_tr=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | tail -1)
		tmux split-window -v -t "$_tl" "$($_cmd_func "${_pool_nums[2]}")"
		if [ "$_np" -ge 4 ]; then
			tmux split-window -v -t "$_tr" "$($_cmd_func "${_pool_nums[3]}")"
		fi
	else
		# 5-6 pools: 3x2 grid (3 rows, 2 columns)
		tmux new-session -d -s "$_sess" "$($_cmd_func "${_pool_nums[0]}")"
		local _tl
		_tl=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | head -1)
		tmux split-window -h -t "$_tl" "$($_cmd_func "${_pool_nums[1]}")"
		local _tr
		_tr=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | tail -1)
		# Split left column into 3
		tmux split-window -v -t "$_tl" "$($_cmd_func "${_pool_nums[2]}")"
		local _ml
		_ml=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | sed -n '3p')
		tmux split-window -v -t "$_ml" "$($_cmd_func "${_pool_nums[4]}")"
		# Split right column into 3
		tmux split-window -v -t "$_tr" "$($_cmd_func "${_pool_nums[3]}")"
		if [ "$_np" -ge 6 ]; then
			local _mr
			_mr=$(tmux list-panes -t "$_sess" -F '#{pane_id}' | tail -1)
			tmux split-window -v -t "$_mr" "$($_cmd_func "${_pool_nums[5]}")"
		fi
		tmux select-layout -t "$_sess" tiled
	fi
}
