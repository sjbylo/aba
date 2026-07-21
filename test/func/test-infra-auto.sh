#!/bin/bash
# test-infra-auto.sh -- Functional tests for tools/setup-dns.sh, tools/setup-ntp.sh
# and scripts/infra-dns.sh (per-cluster record management).
#
# Requires: root/sudo, dig, dnsmasq installable, chrony installed
# Run from the ABA root directory.

set -euo pipefail

source scripts/include_all.sh

_PASS=0
_FAIL=0

_assert() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then
		echo "  PASS: $desc"
		_PASS=$(( _PASS + 1 ))
	else
		echo "  FAIL: $desc (command: $*)"
		_FAIL=$(( _FAIL + 1 ))
	fi
}

_assert_not() {
	local desc="$1"; shift
	if ! "$@" >/dev/null 2>&1; then
		echo "  PASS: $desc"
		_PASS=$(( _PASS + 1 ))
	else
		echo "  FAIL: $desc (expected failure but succeeded)"
		_FAIL=$(( _FAIL + 1 ))
	fi
}

echo "=== Functional tests: infra-auto DNS/NTP ==="
echo

# ── DNS Setup ────────────────────────────────────────────────────────────────
echo "--- DNS: setup ---"

tools/setup-dns.sh -y --upstream 8.8.8.8

_assert "Marker file exists" test -f /etc/dnsmasq.d/aba-upstream.conf
_assert "dnsmasq is active" systemctl is-active --quiet dnsmasq
_assert "resolv.conf points to localhost" grep -q '^nameserver 127.0.0.1' /etc/resolv.conf
_assert "resolv.conf backup exists" test -f /etc/resolv.conf.aba-backup
_assert "External DNS resolves" dig @127.0.0.1 +short +timeout=3 google.com

# Idempotent
echo
echo "--- DNS: idempotent re-run ---"
tools/setup-dns.sh -y --upstream 8.8.8.8
_assert "Still works after re-run" dig @127.0.0.1 +short +timeout=3 google.com

# ── infra-dns.sh add-cluster ─────────────────────────────────────────────────
echo
echo "--- DNS: add-cluster ---"

# Create a temporary cluster.conf for testing
_test_dir=$(mktemp -d)
cat > "$_test_dir/cluster.conf" <<-EOF
cluster_name=testcluster
base_domain=example.com
starting_ip=10.99.99.99
EOF

(cd "$_test_dir" && $OLDPWD/scripts/infra-dns.sh add-cluster)

_assert "Cluster record file exists" test -f /etc/dnsmasq.d/aba-testcluster.conf
_assert "api resolves" dig @127.0.0.1 +short api.testcluster.example.com | grep -q '10.99.99.99'
_assert "apps wildcard resolves" dig @127.0.0.1 +short foo.apps.testcluster.example.com | grep -q '10.99.99.99'

# ── infra-dns.sh remove-cluster ──────────────────────────────────────────────
echo
echo "--- DNS: remove-cluster ---"

scripts/infra-dns.sh remove-cluster testcluster

_assert "Cluster record file removed" test ! -f /etc/dnsmasq.d/aba-testcluster.conf
_assert_not "api no longer resolves" dig @127.0.0.1 +short +timeout=2 api.testcluster.example.com | grep -q '10.99.99.99'

rm -rf "$_test_dir"

# ── infra-dns.sh check ───────────────────────────────────────────────────────
echo
echo "--- DNS: check ---"
_assert "infra-dns.sh check passes" scripts/infra-dns.sh check

# ── DNS Remove ───────────────────────────────────────────────────────────────
echo
echo "--- DNS: remove ---"

tools/remove-dns.sh -y

_assert "Marker file removed" test ! -f /etc/dnsmasq.d/aba-upstream.conf
_assert "dnsmasq stopped" ! systemctl is-active --quiet dnsmasq
_assert "resolv.conf restored" ! grep -q '^nameserver 127.0.0.1' /etc/resolv.conf
_assert "NM dns=none removed" test ! -f /etc/NetworkManager/conf.d/aba-no-dns.conf

# ── NTP Setup ────────────────────────────────────────────────────────────────
echo
echo "--- NTP: setup ---"

tools/setup-ntp.sh -y --allow-network 10.0.0.0/16

_assert "chrony allow line present" grep -q '^allow 10.0.0.0/16' /etc/chrony.conf
_assert "chronyd is active" systemctl is-active --quiet chronyd

# Idempotent
echo
echo "--- NTP: idempotent re-run ---"
tools/setup-ntp.sh -y --allow-network 10.0.0.0/16
_allow_count=$(grep -c '^allow 10.0.0.0/16' /etc/chrony.conf)
_assert "Only one allow line (idempotent)" test "$_allow_count" -eq 1

# ── NTP Remove ───────────────────────────────────────────────────────────────
echo
echo "--- NTP: remove ---"

tools/remove-ntp.sh -y

_assert_not "chrony allow line removed" grep -q '^allow ' /etc/chrony.conf
_assert "chronyd still running (as client)" systemctl is-active --quiet chronyd

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $_PASS passed, $_FAIL failed ==="
[ "$_FAIL" -eq 0 ] || exit 1
