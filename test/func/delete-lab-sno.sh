#!/bin/bash
# Delete a lab throwaway cluster (default: sno) from conno and/or disco.
# Frees the shared starting_ip (sno → 10.0.1.201) so either side can reinstall.
#
# Usage:
#   test/func/delete-lab-sno.sh              # both conno + disco
#   test/func/delete-lab-sno.sh conno        # one host
#   test/func/delete-lab-sno.sh disco
#   CLUSTER=sno4 test/func/delete-lab-sno.sh
#
# Env:
#   CLUSTER   - cluster dir name (default: sno)
#   CON / DIS - override hosts (default: conno/disco.example.com)

set -euo pipefail

cd "$(dirname "$0")/../.."

_CLUSTER="${CLUSTER:-sno}"
_SSH_CFG="${ABA_SSH_CFG:-$HOME/.aba/ssh.conf}"
_CON="${CON:-conno.example.com}"
_DIS="${DIS:-disco.example.com}"
_TARGET="${1:-both}"

_pass=0
_fail=0
_pass() { _pass=$(( _pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { _fail=$(( _fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_delete_on() {
	local host="$1"
	local ssh="ssh -F $_SSH_CFG $host"

	echo ""
	echo "--- $host ---"
	if ! $ssh "echo ok" &>/dev/null; then
		echo "  SKIPPED: $host not reachable"
		return 0
	fi

	if $ssh "test -d ~/aba/$_CLUSTER"; then
		echo "  Found ~/aba/$_CLUSTER — aba delete --yes"
		if $ssh "cd ~/aba && aba -d $_CLUSTER delete --yes" 2>&1 | tail -15; then
			_pass "$host: deleted $_CLUSTER"
		else
			_fail "$host: aba delete failed"
		fi
	else
		echo "  No ~/aba/$_CLUSTER on $host — nothing for aba/TUI to delete"
		_pass "$host: no cluster dir (already clear)"
	fi
}

echo "=== Delete lab cluster '$_CLUSTER' ==="
echo "  Target: $_TARGET"

case "$_TARGET" in
	conno|con) _delete_on "$_CON" ;;
	disco|dis) _delete_on "$_DIS" ;;
	both|all|"")
		_delete_on "$_CON"
		_delete_on "$_DIS"
		;;
	*)
		echo "Usage: $0 [conno|disco|both]" >&2
		exit 2
		;;
esac

# IP check from conno (lab NIC) when reachable
echo ""
echo "--- IP check ---"
_ip=""
case "$_CLUSTER" in
	sno) _ip=10.0.1.201 ;;
	sno2) _ip=10.0.1.202 ;;
	sno3) _ip=10.0.1.203 ;;
	sno4) _ip=10.0.1.204 ;;
esac
if [[ -n "$_ip" ]] && ssh -F "$_SSH_CFG" "$_CON" "echo ok" &>/dev/null; then
	if ssh -F "$_SSH_CFG" "$_CON" "ping -c1 -W1 $_ip >/dev/null 2>&1"; then
		_fail "$_ip still responds to ping (VM may remain)"
	else
		_pass "$_ip is free"
	fi
fi

echo ""
echo "Results: $_pass passed, $_fail failed"
exit "$_fail"
