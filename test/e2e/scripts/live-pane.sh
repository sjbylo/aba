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

# Detect which user owns the tmux session on this pool
_suite_user=$(ssh $_SSH_OPTS ${_DEFAULT_USER}@${_h} 'cat /tmp/e2e-suite-user')
_user="${_suite_user:-$_DEFAULT_USER}"

# Check if another live dashboard took over this pool.
# exit 0 (not return) to kill the pane shell -- return just goes back to the
# wrapper's while-loop and re-sources us, creating infinite spam.
_owner=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-live-owner')
if [ -n "$_owner" ] && [ "$_owner" != "$_LIVE_ID" ]; then
	echo "Another live dashboard took over pool ${_POOL_NUM}."
	exit 0
fi

# Read suite metadata for pane title
_suite=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-last-suites')
_os=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-suite-os')
_vmconf=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-suite-vmconf')
_vmtag=""
[ -n "$_vmconf" ] && [ "$_vmconf" != "~/.vmware.conf" ] && _vmtag=" | $(basename "$_vmconf")"

_set_title() {
	printf '\033]2;live | Pool %d | %s | %s%s%s\033\\' "$_POOL_NUM" "$1" "$2" "$3" "$4"
}

# Check if the remote tmux session exists
if ssh $_SSH_OPTS ${_user}@${_h} "tmux has-session -t '$_sess'"; then
	# Session exists -- check if the pane is dead (suite finished, remain-on-exit keeping it)
	_dead=$(ssh $_SSH_OPTS ${_user}@${_h} "tmux list-panes -t '$_sess' -F '#{pane_dead}'")
	if [ "$_dead" = "1" ]; then
		# Suite finished. Show banner (no clear -- suite output is in our scrollback
		# from the previous attach, if any).
		_result=$(ssh $_SSH_OPTS ${_user}@${_h} "grep -E '(PASSED|FAILED):' ~/.e2e-harness/logs/${_suite}-summary.log | tail -1 | sed 's/\x1b\[[0-9;]*m//g'")
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
			_check=$(ssh $_SSH_OPTS ${_user}@${_h} "tmux has-session -t '$_sess' && tmux list-panes -t '$_sess' -F '#{pane_dead}' || echo NOSESSION")

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
			_new_user=$(ssh $_SSH_OPTS ${_DEFAULT_USER}@${_h} 'cat /tmp/e2e-suite-user')
			_new_user="${_new_user:-$_DEFAULT_USER}"
			if [ "$_new_user" != "$_user" ]; then
				if ssh $_SSH_OPTS ${_new_user}@${_h} "tmux has-session -t '$_sess'"; then
					break
				fi
			fi
		done
	else
		# Pane alive -- always re-read metadata right before attach (suite may
		# have changed since the top of the loop, especially during rapid cycling)
		_suite=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-last-suites')
		local _retries=0
		while [ -z "$_suite" ] && [ "$_retries" -lt 5 ]; do
			sleep 2
			_suite=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-last-suites')
			_retries=$(( _retries + 1 ))
		done
		_os=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-suite-os')
		_vmconf=$(ssh $_SSH_OPTS ${_user}@${_h} 'cat /tmp/e2e-suite-vmconf')
		_vmtag=""
		[ -n "$_vmconf" ] && [ "$_vmconf" != "~/.vmware.conf" ] && _vmtag=" | $(basename "$_vmconf")"
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
		echo "No e2e session on pool ${_POOL_NUM}. Waiting for suite to start..."
		_IDLE_MSG_SHOWN=1
	fi
	sleep 5
fi
