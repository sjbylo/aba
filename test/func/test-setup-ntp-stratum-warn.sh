#!/bin/bash
# aba setup ntp warns when this host's stratum is weak. It does not change the server.

set -eo pipefail

cd "$(dirname "$0")/../.."

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

eval "$(sed -n '/^_ntp_warn_if_weak_stratum()/,/^}/p' tools/setup-ntp.sh)"
aba_warn() { printf '%s\n' "$*"; }

check() {
	local stratum=$1 expect=$2 label=$3
	local msg
	msg=$(_ntp_warn_if_weak_stratum "$stratum")
	if [ "$expect" = warn ]; then
		case "$msg" in
			*"NTP stratum $stratum"*"stratum 1 or 2"*) _pass "$label" ;;
			*) _fail "$label: $msg" ;;
		esac
	else
		if [ -z "$msg" ]; then
			_pass "$label"
		else
			_fail "$label: $msg"
		fi
	fi
}

check 1 quiet "stratum 1 is quiet"
check 2 quiet "stratum 2 is quiet"
check 3 warn "stratum 3 warns"
check 4 warn "stratum 4 warns"
check 15 warn "stratum 15 warns"
check 0 quiet "stratum 0 is quiet"
check 16 quiet "stratum 16 is quiet"
check "" quiet "unreadable stratum is quiet"

msg=$(_ntp_warn_if_weak_stratum 3 10.0.1.8)
case "$msg" in
	*"NTP stratum 3"*"stratum 1 or 2"*"Consider 10.0.1.8 if the OpenShift nodes can reach it."*)
		_pass "weak stratum names the selected server"
		;;
	*) _fail "weak stratum names the selected server: $msg" ;;
esac
if printf '%s\n' "$msg" | grep -q '162.159.200.123'; then
	_fail "warning named a server other than the selected one"
else
	_pass "warning does not name an unselected server"
fi

msg=$(_ntp_warn_if_weak_stratum 3)
case "$msg" in
	*"Consider "*) _fail "no upstream still suggests a server: $msg" ;;
	*"NTP stratum 3"*"stratum 1 or 2"*) _pass "weak stratum without an upstream keeps the short warning" ;;
	*) _fail "weak stratum without an upstream: $msg" ;;
esac

msg=$(_ntp_warn_if_weak_stratum 2 10.0.1.8)
if [ -z "$msg" ]; then
	_pass "stratum 2 with an upstream is quiet"
else
	_fail "stratum 2 with an upstream is quiet: $msg"
fi

# The restart leaves stratum 0 for a few seconds. The wait must outlast that.
# Replies live in a file: each read runs in a command substitution, so a
# shell array would be discarded before the next try.
eval "$(sed -n '/^_ntp_wait_stratum()/,/^}/p' tools/setup-ntp.sh)"
sleep() { printf 's\n' >> "$_sleepfile"; }
_ntp_current_stratum() {
	local v
	v=$(head -n 1 "$_seqfile")
	tail -n +2 "$_seqfile" > "$_seqfile.next"
	mv "$_seqfile.next" "$_seqfile"
	printf '%s\n' "$v"
}

wait_for() {
	local label=$1 expect=$2 expect_sleeps=$3
	shift 3
	local got sleeps dir
	dir=$(mktemp -d)
	printf '%s\n' "$@" > "$dir/replies"
	: > "$dir/sleeps"
	_seqfile=$dir/replies
	_sleepfile=$dir/sleeps
	got=$(_ntp_wait_stratum)
	sleeps=$(wc -l < "$dir/sleeps" | tr -d ' ')
	rm -rf "$dir"
	if [ "$got" = "$expect" ] && [ "$sleeps" -eq "$expect_sleeps" ]; then
		_pass "$label"
	else
		_fail "$label: got '$got' after $sleeps sleeps"
	fi
}

wait_for "stratum 3 is returned immediately" 3 0 3
wait_for "stratum 0 then 3 waits once" 3 1 0 3
wait_for "empty then 2 waits once" 2 1 "" 2
_zeros=()
_i=0
while [ "$_i" -lt 15 ]; do
	_zeros+=("0")
	_i=$(( _i + 1 ))
done
wait_for "stratum 0 gives up after 15 tries" 0 15 "${_zeros[@]}"

if grep -q '_ntp_stratum=$(_ntp_wait_stratum)' tools/setup-ntp.sh \
	&& grep -q '\[ -n "$_ntp_have" \]' tools/setup-ntp.sh; then
	_pass "setup waits for a stratum only when an NTP server is configured"
else
	_fail "setup still reads the stratum once"
fi

eval "$(sed -n '/^_ntp_servers_in()/,/^}/p' tools/setup-ntp.sh)"
eval "$(sed -n '/^_ntp_configured_servers()/,/^}/p' tools/setup-ntp.sh)"
eval "$(sed -n '/^_ntp_selected_from_tracking()/,/^}/p' tools/setup-ntp.sh)"
eval "$(sed -n '/^_ntp_suggest_upstream()/,/^}/p' tools/setup-ntp.sh)"

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT
printf '%s\n' '#pool 2.rhel.pool.ntp.org iburst' 'allow 10.0.0.0/20' > "$_tmp/empty.conf"
got=$(_ntp_configured_servers "$_tmp/empty.conf")
if [ -z "$got" ]; then
	_pass "commented pool is not an NTP server"
else
	_fail "commented pool is not an NTP server: $got"
fi

mkdir -p "$_tmp/dhcp"
printf '%s\n' 'server 162.159.200.123 iburst' > "$_tmp/dhcp/ens4.sources"
printf '%s\n' 'server 10.0.1.8 iburst' '#pool 2.rhel.pool.ntp.org iburst' "sourcedir $_tmp/dhcp" > "$_tmp/chrony.conf"
got=$(_ntp_configured_servers "$_tmp/chrony.conf")
if printf '%s\n' "$got" | grep -qx '10.0.1.8' && printf '%s\n' "$got" | grep -qx '162.159.200.123'; then
	_pass "configured servers include chrony.conf and sourcedir"
else
	_fail "configured servers include chrony.conf and sourcedir: $got"
fi

got=$(printf '%s\n' 'Reference ID    : 0A000108 (10.0.1.8)' | _ntp_selected_from_tracking)
if [ "$got" = "10.0.1.8" ]; then
	_pass "selected source is the address chrony is using"
else
	_fail "selected source is the address chrony is using: $got"
fi

got=$(_ntp_suggest_upstream 10.0.1.5 10.0.1.8 10.0.1.8 162.159.200.123)
if [ "$got" = "10.0.1.8" ]; then
	_pass "suggestion is the selected server"
else
	_fail "suggestion is the selected server: $got"
fi

got=$(_ntp_suggest_upstream 10.0.1.5 "" 10.0.1.8 162.159.200.123)
if [ "$got" = "10.0.1.8" ]; then
	_pass "with no selection the first configured server is suggested"
else
	_fail "with no selection the first configured server is suggested: $got"
fi

got=$(_ntp_suggest_upstream 10.0.1.5 10.0.1.5 10.0.1.5 10.0.1.8)
if [ "$got" = "10.0.1.8" ]; then
	_pass "this host is not suggested as its own upstream"
else
	_fail "this host is not suggested as its own upstream: $got"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
