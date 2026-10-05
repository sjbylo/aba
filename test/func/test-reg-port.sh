#!/bin/bash
# A registry port is 1-65535. 8443 still passes. Does not write mirror.conf in the repo.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh

fail=0
pass() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

if valid_port 8443 && valid_port 1 && valid_port 65535; then
	pass "8443, 1, and 65535"
else
	bad "a valid port was rejected"
fi

if ! valid_port 0 && ! valid_port 65536 && ! valid_port 99999 && ! valid_port abc; then
	pass "0, 65536, 99999, and abc"
else
	bad "an invalid port was accepted"
fi

# Stored reg_port is checked by verify-mirror-conf. Temp directory only.
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
echo x > "$d/mirror.conf"

run_verify() {
	local port=$1
	(
		cd "$d"
		verify_conf=all
		unset ABA_TRACE_FILE reg_root data_dir reg_path reg_ssh_key reg_vendor reg_pw
		reg_host=registry.example.com
		reg_port=$port
		verify-mirror-conf >/dev/null 2>&1
	)
}

if run_verify 8443; then
	pass "verify accepts 8443"
else
	bad "verify rejected 8443"
fi

if run_verify 0; then
	bad "verify accepted 0"
else
	pass "verify rejects 0"
fi

if run_verify 99999; then
	bad "verify accepted 99999"
else
	pass "verify rejects 99999"
fi

if grep -q 'valid_port' scripts/aba.sh && grep -q 'valid_port' scripts/include_all.sh; then
	pass "CLI and verify both call valid_port"
else
	bad "valid_port is not used at both checks"
fi

exit "$fail"
