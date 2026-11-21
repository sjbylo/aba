#!/bin/bash
# local stratum stays 3 unless the best reachable NTP server is stratum 3 or worse.

set -eo pipefail

cd "$(dirname "$0")/../.."

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

eval "$(sed -n '/^# BEGIN ntp-stratum-helpers$/,/^# END ntp-stratum-helpers$/p' scripts/day2-config-ntp.sh)"

aba_debug() { :; }
aba_info() { :; }
aba_warn() { printf '%s\n' "$*"; }

n=$(grep -c 'local stratum $_ntp_local_stratum orphan' scripts/day2-config-ntp.sh)
if [ "$n" -eq 2 ]; then
	_pass "master and worker chrony lines use the chosen local stratum"
else
	_fail "expected 2 variable local-stratum lines, found $n"
fi
if grep -q 'local stratum 3 orphan$' scripts/day2-config-ntp.sh; then
	_fail "hardcoded local stratum 3 orphan is still written"
else
	_pass "chrony file is not hardcoded to local stratum 3"
fi

_ntp_server_stratum() {
	case $1 in
		s1) echo 1 ;;
		s2) echo 2 ;;
		s3) echo 3 ;;
		s4) echo 4 ;;
		s5) echo 5 ;;
		s15) echo 15 ;;
		*) return 1 ;;
	esac
}

check() {
	local servers=$1 expect=$2 label=$3
	ntp_servers=$servers
	_ntp_local_stratum=0
	_ntp_choose_local_stratum >/dev/null
	if [ "$_ntp_local_stratum" = "$expect" ]; then
		_pass "$label"
	else
		_fail "$label -> $_ntp_local_stratum (wanted $expect)"
	fi
}

check s2 3 "stratum 2 keeps local stratum 3"
check s1 3 "stratum 1 keeps local stratum 3"
check s3 4 "stratum 3 raises local stratum to 4"
check s4 5 "stratum 4 raises local stratum to 5"
check "s3 s2" 3 "a stratum 2 server among worse ones keeps 3"
check "s5 s4" 5 "best stratum 4 raises local stratum to 5"
check "down s3" 4 "an unreadable server is ignored when another answers"
check down 3 "an unreadable server keeps local stratum 3"
check s15 3 "stratum 15 cannot sit above, keeps 3"
check "" 3 "no servers keeps local stratum 3"

ntp_servers=s3
msg=$(_ntp_choose_local_stratum)
case "$msg" in
	*"is stratum 3"*"Setting local stratum to 4"*"stratum 1 or 2"*)
		_pass "stratum 3 warning explains the raise"
		;;
	*)
		_fail "stratum 3 warning text: $msg"
		;;
esac

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
