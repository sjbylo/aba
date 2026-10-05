#!/bin/bash
# dig +short may print a CNAME and several addresses. The VIP is the first IPv4 line.
# Does not run dig and does not write cluster.conf.

set -eo pipefail

cd "$(dirname "$0")/../.."
_is_ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
eval "$(awk '/^first_ipv4\(\)/,/^}/' scripts/resolve-vips.sh)"

fail=0
check() {
	local name="$1" input="$2" expect="$3" got
	got=$(first_ipv4 "$input")
	if [ "$got" = "$expect" ]; then
		echo "PASS: $name"
	else
		echo "FAIL: $name got '${got}' expected '${expect}'"
		fail=1
	fi
}

check "one address stays" "10.0.1.10" "10.0.1.10"
check "cname then address" "$(printf '%s\n' 'www.redhat.com' '23.39.10.95')" "23.39.10.95"
check "first of several addresses" "$(printf '%s\n' 'd111.cloudfront.net' '1.2.3.4' '5.6.7.8')" "1.2.3.4"
check "name only is empty" "cname.example.net" ""
check "empty is empty" "" ""

exit "$fail"
