#!/bin/bash
# Live dashboard pane script for a single pool.
# Called from the generated wrapper in /tmp/e2e-live.*/poolN.sh
# Updating this file takes effect on the next loop iteration (~5s) without
# restarting run.sh live.
#
# Required env vars (set by the wrapper):
#   _POOL_NUM       Pool number (1-6)
#   _DOMAIN         VM base domain (e.g. example.com)
#   _SSH_OPTS       SSH options string
#   _DEFAULT_USER   Fallback SSH user
#   _LIVE_ID        Unique ID of this live session (for takeover detection)
#   _E2E_TMUX_SESSION  tmux session name on conN (default: e2e-suite)

_h="con${_POOL_NUM}.${_DOMAIN}"
_sess="${_E2E_TMUX_SESSION:-e2e-suite}"

# Quiet remote helpers — idle pools have no markers / no tmux server.
_lp_rcat() {
	# $1=user $2=remote path
	ssh $_SSH_OPTS "$1"@"$_h" "cat $2 2>/dev/null" 2>/dev/null
}
_lp_has_sess() {
	# $1=user (optional, default $_user)
	ssh $_SSH_OPTS "${1:-$_user}"@"$_h" "tmux has-session -t '$_sess' 2>/dev/null" 2>/dev/null
}
_lp_ssh() {
	# Quiet remote command as $_user; stdout captured by caller
	ssh $_SSH_OPTS "${_user}"@"$_h" "$@" 2>/dev/null
}
_lp_load_meta() {
	_suite=$(_lp_rcat "$_user" /tmp/e2e-last-suites)
	_os=$(_lp_rcat "$_user" /tmp/e2e-suite-os)
	_vmconf=$(_lp_rcat "$_user" /tmp/e2e-suite-vmconf)
	_vmtag=""
	[ -n "$_vmconf" ] && [ "$_vmconf" != "~/.vmware.conf" ] && _vmtag=" | $(basename "$_vmconf")"
}
_set_title() {
	printf '\033]2;live | Pool %d | %s | %s%s%s\033\\' "$_POOL_NUM" "$1" "$2" "$3" "$4"
}

# Detect which user owns the tmux session on this pool
_suite_user=$(_lp_rcat "$_DEFAULT_USER" /tmp/e2e-suite-user)
_user="${_suite_user:-$_DEFAULT_USER}"

# Check if another live dashboard took over this pool.
# exit 0 (not return) to kill the pane shell -- return just goes back to the
# wrapper's while-loop and re-sources us, creating infinite spam.
_owner=$(_lp_rcat "$_user" /tmp/e2e-live-owner)
if [ -n "$_owner" ] && [ "$_owner" != "$_LIVE_ID" ]; then
	echo "Another live dashboard took over pool ${_POOL_NUM}."
	exit 0
fi

_lp_load_meta

# Check if the remote tmux session exists
if _lp_has_sess; then
	# Session exists -- check if the pane is dead (suite finished, remain-on-exit keeping it)
	_dead=$(_lp_ssh "tmux list-panes -t '$_sess' -F '#{pane_dead}'")
	if [ "$_dead" = "1" ]; then
		# Suite finished. Show banner (no clear -- suite output is in our scrollback
		# from the previous attach, if any).
		_result=$(_lp_ssh "grep -E '(PASSED|FAILED):' ~/.e2e-harness/logs/${_suite}-summary.log 2>/dev/null | tail -1 | sed 's/\x1b\[[0-9;]*m//g'")
		_result=$(echo "$_result" | sed 's/^[0-9:]*[[:space:]]*//' | sed 's/=//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
		[ -z "$_result" ] && _result="Suite ended (aborted or no result)"

		_ts=$(date '+%Y-%m-%d %H:%M:%S')
		_meta="Pool ${_POOL_NUM} | ${_user}${_os:+ | $_os}${_vmtag}"

		echo ""
		echo "================================================================================"
		echo "  $_result"
		echo "  $_meta"
		echo "  Completed: $_ts"
		echo ""
		echo "  Scroll up to review suite output. Waiting for next suite ..."
		echo "================================================================================"
		echo ""

		_short_result="DONE"
		echo "$_result" | grep -q "PASSED" && _short_result="PASSED"
		echo "$_result" | grep -q "FAILED" && _short_result="FAILED"
		_set_title "$_suite" "$_short_result" "${_os:+ | $_os}" "$_vmtag"

		# Poll without clearing -- banner and scrollback preserved.
		# Require 2 consecutive "gone" checks to avoid SSH blips clearing the banner.
		_gone_count=0
		while true; do
			sleep 5
			# Single SSH call: check session existence AND pane state together
			_check=$(_lp_ssh "tmux has-session -t '$_sess' 2>/dev/null && tmux list-panes -t '$_sess' -F '#{pane_dead}' 2>/dev/null || echo NOSESSION")

			if [ -z "$_check" ]; then
				# SSH failed (empty output) -- ignore, don't break
				continue
			elif [ "$_check" = "NOSESSION" ]; then
				# Session gone (dispatcher killed it for new suite)
				_gone_count=$(( _gone_count + 1 ))
				[ "$_gone_count" -ge 2 ] && break
				continue
			elif [ "$_check" != "1" ]; then
				# Pane is alive again (new suite reused session)
				break
			fi
			# Pane still dead -- keep waiting
			_gone_count=0

			# Re-check user in case a new suite started as a different user
			_new_user=$(_lp_rcat "$_DEFAULT_USER" /tmp/e2e-suite-user)
			_new_user="${_new_user:-$_DEFAULT_USER}"
			if [ "$_new_user" != "$_user" ]; then
				if _lp_has_sess "$_new_user"; then
					break
				fi
			fi
		done
	else
		# Pane alive -- always re-read metadata right before attach (suite may
		# have changed since the top of the loop, especially during rapid cycling)
		_retries=0
		_lp_load_meta
		while [ -z "$_suite" ] && [ "$_retries" -lt 5 ]; do
			sleep 2
			_lp_load_meta
			_retries=$(( _retries + 1 ))
		done
		_set_title "${_suite:-(starting...)}" "${_user}" "${_os:+ | $_os}" "$_vmtag"
		_IDLE_MSG_SHOWN=
		clear
		ssh -t $_SSH_OPTS ${_user}@${_h} "exec tmux attach -d -t '$_sess'"
		# Attach exited (session killed or SSH dropped). Next loop iteration
		# will detect the new state.
	fi
else
	# No session at all -- idle pool. No clear: preserve banner/scrollback.
	_set_title "(idle)" "${_user}" "${_os:+ | $_os}" "$_vmtag"
	if [ "${_IDLE_MSG_SHOWN:-}" != "1" ]; then
		echo "Pool ${_POOL_NUM} idle — waiting for suite to start..."
		_IDLE_MSG_SHOWN=1
	fi
	sleep 5
fi
