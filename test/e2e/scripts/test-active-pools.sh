#!/usr/bin/env bash
# Pool retirement: stop drops pools, start puts them back, dispatcher skips them.
# No pools, SSH, or govc.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"

pass=0
fail=0
_assert() {
	local desc="$1"; shift
	if "$@"; then
		echo "  PASS: $desc"
		pass=$(( pass + 1 ))
	else
		echo "  FAIL: $desc"
		fail=$(( fail + 1 ))
	fi
}

_not() { ! "$@"; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# shellcheck disable=SC1091
source "$_E2E_DIR/lib/constants.sh"
# shellcheck disable=SC1091
source "$_E2E_DIR/lib/commands.sh"
# shellcheck disable=SC1091
source "$_E2E_DIR/lib/dispatcher.sh"

E2E_ACTIVE_POOLS="$_tmp/active"
E2E_DAEMON_META="$_tmp/meta"
E2E_DAEMON_PID="$_tmp/daemon.pid"
E2E_DISPATCHER_PID="$_tmp/dispatcher.pid"
E2E_DISPATCH_STATE="$_tmp/state"
E2E_POOL_LOCK_PREFIX="$_tmp/pool"
E2E_GLOBAL_LOCK="$_tmp/global.lock"

printf 'pid=1\npools=1 2 3 4\nstarted=test\nargs=run --all -p 1-4\n' > "$E2E_DAEMON_META"

# No active file yet: every pool is eligible, and retire reads the meta line.
_assert "missing file leaves pool 3 in service" _e2e_pool_in_service 3

rem=$(_e2e_retire_pools "3 4")
_assert "retire 3 4 leaves 1 2" test "$rem" = "1 2"
_assert "pool 1 still in service" _e2e_pool_in_service 1
_assert "pool 3 retired" _not _e2e_pool_in_service 3
_assert "meta pools line updated" grep -qx 'pools=1 2' "$E2E_DAEMON_META"

back=$(_e2e_return_pools "4")
_assert "start puts pool 4 back" test "$back" = "1 2 4"
_assert "pool 4 in service again" _e2e_pool_in_service 4
_assert "meta includes 4" grep -qx 'pools=1 2 4' "$E2E_DAEMON_META"

# Dispatcher must not SSH to a retired pool.
declare -A _busy_pools=()
declare -A _unreachable_pools=()
declare -A _pool_cooldown_until=()
CLI_POOL_LIST="1 2 3 4"
_ssh_log="$_tmp/ssh"
: > "$_ssh_log"
_essh() {
	printf '%s\n' "$1" >> "$_ssh_log"
	return 0
}
_export_pool_ssh_users() { :; }
_con_target() { printf 'con%s\n' "$1"; }

printf '1\n2\n' > "$E2E_ACTIVE_POOLS"
free=$(_find_free_pool)
_assert "free pool is 1" test "$free" = "1"
_assert "no SSH to retired pools" test "$(cat "$_ssh_log")" = "con1"

_busy_pools[1]="suite-a"
_busy_pools[2]="suite-b"
: > "$_ssh_log"
if free=$(_find_free_pool); then
	_assert "retired pools are not a fallback" test -n ""
else
	_assert "no free pool when 1 and 2 are busy" test "$free" = ""
fi
_assert "busy in-service pools were not a reason to SSH retired ones" test ! -s "$_ssh_log"
unset '_busy_pools[1]'
unset '_busy_pools[2]'

# cmd_stop / cmd_start without touching the real daemon or vCenter.
_powered=""
_cleaned=""
_stopped_labels=""
_e2e_power_pool_vms() { _powered="${_powered} $1:$2"; }
_process_cleanup_on_pools() { _cleaned="${_cleaned} $1"; }
_stop_pid_file() { _stopped_labels="${_stopped_labels} $2"; }
_e2e_pid_alive() { [ -f "$E2E_DAEMON_PID" ]; }
_con_target() { printf 'con%s\n' "$1"; }
_essh() { echo stopped; }
pgrep() { return 1; }
CLI_CLEAN=1
echo 1 > "$E2E_DAEMON_PID"
printf 'pools=1 2 3 4\n' > "$E2E_DAEMON_META"
rm -f "$E2E_ACTIVE_POOLS"

cmd_stop "3 4" "1 2 3 4" > "$_tmp/stop-out"
_assert "partial stop powers the named pools off" test "$_powered" = " off:3 4"
_assert "cleanup runs before the VMs go off" test "$_cleaned" = " 3 4"
_assert "partial stop does not kill the daemon" test -z "$_stopped_labels"
_assert "daemon set is now 1 2" test "$(_e2e_read_active_pools)" = "1 2"
_assert "stop tells you which pools remain" grep -q 'New suites will use pool(s): 1 2' "$_tmp/stop-out"

_powered=""
cmd_start "3" > "$_tmp/start-out"
_assert "start powers that pool on" test "$_powered" = " on:3"
_assert "start returns pool 3 to the set" test "$(_e2e_read_active_pools)" = "1 2 3"

# Stopping every configured pool does not power the VMs off.
_powered=""
_stopped_labels=""
printf 'pools=1 2 3 4\n' > "$E2E_DAEMON_META"
printf '1\n2\n3\n4\n' > "$E2E_ACTIVE_POOLS"
cmd_stop "1 2 3 4" "1 2 3 4" > "$_tmp/stop-all-out"
_assert "stop all does not power VMs off" test -z "$_powered"
_assert "stop all stops the daemon" grep -q 'Daemon' <<< "$_stopped_labels"

# Guest halt is the shutdown. Hard power-off runs only when the guest stays up.
_halt_log="$_tmp/halt"
: > "$_halt_log"
_essh() { printf '%s %s\n' "$1" "$2" >> "$_halt_log"; }
sleep() { :; }
_govc_log="$_tmp/govc"
: > "$_govc_log"
govc() { printf '%s\n' "$*" >> "$_govc_log"; }
_E2E_HALT_POLLS=3
# The poll runs in a command substitution, so a shell variable would not stick.
echo 0 > "$_tmp/state-n"
_e2e_vm_power_state() {
	local n
	n=$(cat "$_tmp/state-n")
	n=$(( n + 1 ))
	printf '%s\n' "$n" > "$_tmp/state-n"
	if [ "$n" -ge 2 ]; then
		printf 'poweredOff\n'
	else
		printf 'poweredOn\n'
	fi
}
_e2e_guest_shutdown con3 steve@con3.example.com > "$_tmp/halt-ok"
_assert "halt is sent to the guest" grep -qx 'steve@con3.example.com sudo halt -p' "$_halt_log"
_assert "guest that powers off is halted" grep -qx '    con3: halted' "$_tmp/halt-ok"
_assert "finished halt does not cut power" test ! -s "$_govc_log"

: > "$_halt_log"
: > "$_govc_log"
_e2e_vm_power_state() { printf 'poweredOn\n'; }
_e2e_guest_shutdown dis3 steve@dis3.example.com > "$_tmp/halt-fail" 2> "$_tmp/halt-fail-err"
_assert "stuck guest is halted first" grep -qx 'steve@dis3.example.com sudo halt -p' "$_halt_log"
_assert "stuck guest is then powered off" grep -qx 'vm.power -off dis3' "$_govc_log"
_assert "stuck guest says why power was cut" grep -q 'halt did not finish' "$_tmp/halt-fail-err"

echo ""
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
