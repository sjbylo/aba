#!/bin/bash
# Console /etc/hosts lines in the install summary.
# Set VIPs win. A single node with empty VIPs uses the node address.

set -eo pipefail

cd "$(dirname "$0")/../.."
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

run_hosts() {
	INFO_ABA=1 _show_console_hosts "$@"
}

has_line() {
	printf '%s\n' "$1" | grep -F -qx -- "$2"
}

out=$(starting_ip=10.0.0.100 api_vip= ingress_vip= run_hosts hub example.com 1 0)
if has_line "$out" "[ABA] Optionally, set these values in /etc/hosts to access the cluster." \
	&& has_line "$out" "10.0.0.100 api.hub.example.com" \
	&& has_line "$out" "10.0.0.100 console-openshift-console.apps.hub.example.com" \
	&& has_line "$out" "10.0.0.100 oauth-openshift.apps.hub.example.com"; then
	_pass "SNO with empty VIPs uses the node address"
else
	_fail "SNO with empty VIPs uses the node address: $out"
fi

out=$(starting_ip=10.0.0.200 api_vip=10.0.0.198 ingress_vip=10.0.0.199 run_hosts virt example.com 1 0)
if has_line "$out" "10.0.0.198 api.virt.example.com" \
	&& has_line "$out" "10.0.0.199 console-openshift-console.apps.virt.example.com" \
	&& has_line "$out" "10.0.0.199 oauth-openshift.apps.virt.example.com" \
	&& ! printf '%s\n' "$out" | grep -q '10.0.0.200'; then
	_pass "set VIPs are used even when the config says one master"
else
	_fail "set VIPs are used even when the config says one master: $out"
fi

out=$(starting_ip=10.0.0.200 api_vip=10.0.0.198 ingress_vip=10.0.0.199 run_hosts virt example.com 3 0)
if has_line "$out" "10.0.0.198 api.virt.example.com" \
	&& has_line "$out" "10.0.0.199 console-openshift-console.apps.virt.example.com" \
	&& has_line "$out" "10.0.0.199 oauth-openshift.apps.virt.example.com" \
	&& ! printf '%s\n' "$out" | grep -q '10.0.0.200'; then
	_pass "compact uses api_vip and ingress_vip"
else
	_fail "compact uses api_vip and ingress_vip: $out"
fi

out=$(starting_ip=10.0.0.10 api_vip=10.0.0.20 ingress_vip=10.0.0.21 run_hosts std example.com 3 2)
if has_line "$out" "10.0.0.20 api.std.example.com" \
	&& has_line "$out" "10.0.0.21 oauth-openshift.apps.std.example.com"; then
	_pass "standard uses api_vip and ingress_vip"
else
	_fail "standard uses api_vip and ingress_vip: $out"
fi

out=$(starting_ip=10.0.0.200 api_vip=10.0.0.198 ingress_vip= run_hosts virt example.com 3 0)
if [ -z "$out" ]; then
	_pass "missing ingress_vip prints nothing"
else
	_fail "missing ingress_vip prints nothing: $out"
fi

out=$(starting_ip= api_vip= ingress_vip= run_hosts hub example.com 1 0)
if [ -z "$out" ]; then
	_pass "SNO with no node address prints nothing"
else
	_fail "SNO with no node address prints nothing: $out"
fi

out=$(INFO_ABA= starting_ip=10.0.0.100 _show_console_hosts hub example.com 1 0)
if [ -z "$out" ]; then
	_pass "quiet when info is off"
else
	_fail "quiet when info is off: $out"
fi

body=$(sed -n '/^show_cluster_card()/,/^}/p' scripts/include_all.sh)
api_at=$(printf '%s\n' "$body" | grep -n '"API"' | head -1 | cut -d: -f1)
hosts_at=$(printf '%s\n' "$body" | grep -n '_show_console_hosts' | head -1 | cut -d: -f1)
shell_at=$(printf '%s\n' "$body" | grep -n '"Shell"' | head -1 | cut -d: -f1)
if [ -n "$api_at" ] && [ -n "$hosts_at" ] && [ -n "$shell_at" ] \
	&& [ "$api_at" -lt "$hosts_at" ] && [ "$hosts_at" -lt "$shell_at" ]; then
	_pass "hosts block sits after the API line and before the shell line"
else
	_fail "hosts block placement: api=$api_at hosts=$hosts_at shell=$shell_at"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
