#!/bin/bash
# Test: Verify stderr capture to aba_debug for internal commands
# Validates that commands which previously discarded stderr now log it to trace.log
# Unit test (fast, uses mocks, no network)

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

# Setup mock directory and trace log
_mock_dir=$(mktemp -d)
_trace_log=$(mktemp)
trap 'rm -rf "$_mock_dir" "$_trace_log"' EXIT

# Source include_all to get aba_debug, probe_host, etc.
source scripts/include_all.sh dummy_arg 2>/dev/null

# Override ABA_TRACE_FILE to our temp file so we can inspect debug output
ABA_TRACE_FILE="$_trace_log"
export ABA_TRACE_FILE

echo
echo "=== Testing: stderr capture to aba_debug ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: probe_host() logs stderr on failure
# ─────────────────────────────────────────────────────────────────────────────

# Mock curl that fails with a specific error message
cat > "$_mock_dir/curl" <<'MOCK'
#!/bin/bash
echo "curl: (7) Failed to connect to badhost port 443" >&2
exit 7
MOCK
chmod +x "$_mock_dir/curl"

> "$_trace_log"
(
	export PATH="$_mock_dir:$PATH"
	probe_host "http://badhost:443/test" "test-endpoint" 1 1 0
) 2>/dev/null || true

if grep -q "probe_host failed for test-endpoint" "$_trace_log"; then
	test_pass "probe_host: logs stderr on failure"
else
	test_fail "probe_host: logs stderr on failure" "trace: $(cat "$_trace_log")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: probe_host() succeeds silently (no debug noise on success)
# ─────────────────────────────────────────────────────────────────────────────

cat > "$_mock_dir/curl" <<'MOCK'
#!/bin/bash
echo "HTTP/1.1 200 OK" >&1
exit 0
MOCK
chmod +x "$_mock_dir/curl"

> "$_trace_log"
(
	export PATH="$_mock_dir:$PATH"
	probe_host "http://goodhost/test" "good-endpoint" 1 1 0
) 2>/dev/null

if ! grep -q "probe_host failed" "$_trace_log"; then
	test_pass "probe_host: no debug output on success"
else
	test_fail "probe_host: no debug output on success" "trace: $(cat "$_trace_log")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: _dnsmasq_restart() logs stderr on failure
# ─────────────────────────────────────────────────────────────────────────────

# Extract and source _dnsmasq_restart
eval "$(sed -n '/^_dnsmasq_restart()/,/^}/p' scripts/infra-dns.sh)"

cat > "$_mock_dir/systemctl" <<'MOCK'
#!/bin/bash
case "$1 $2" in
	"reset-failed dnsmasq") exit 0 ;;
	"restart dnsmasq")
		echo "Job for dnsmasq.service failed because the control process exited with error code." >&2
		exit 1 ;;
	*) exit 0 ;;
esac
MOCK
chmod +x "$_mock_dir/systemctl"

> "$_trace_log"
(
	export PATH="$_mock_dir:$PATH"
	SUDO=""
	_dnsmasq_restart
) 2>/dev/null || true

if grep -q "dnsmasq restart failed" "$_trace_log"; then
	test_pass "_dnsmasq_restart: logs stderr on failure"
else
	test_fail "_dnsmasq_restart: logs stderr on failure" "trace: $(cat "$_trace_log")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: _dnsmasq_restart() succeeds silently
# ─────────────────────────────────────────────────────────────────────────────

cat > "$_mock_dir/systemctl" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$_mock_dir/systemctl"

> "$_trace_log"
(
	export PATH="$_mock_dir:$PATH"
	SUDO=""
	_dnsmasq_restart
) 2>/dev/null

if ! grep -q "dnsmasq restart failed" "$_trace_log"; then
	test_pass "_dnsmasq_restart: no debug output on success"
else
	test_fail "_dnsmasq_restart: no debug output on success" "trace: $(cat "$_trace_log")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: preflight_check_dns logs stderr on failure
# ─────────────────────────────────────────────────────────────────────────────

# Extract the function from preflight-check.sh
eval "$(sed -n '/^preflight_check_dns()/,/^}/p' scripts/preflight-check.sh)"

cat > "$_mock_dir/dig" <<'MOCK'
#!/bin/bash
echo ";; connection timed out; no servers could be reached" >&2
exit 9
MOCK
chmod +x "$_mock_dir/dig"

> "$_trace_log"
(
	export PATH="$_mock_dir:$PATH"
	dns_servers="192.168.1.99"
	preflight_check_dns
) 2>/dev/null || true

if grep -q "dig @192.168.1.99 failed" "$_trace_log"; then
	test_pass "preflight_check_dns: logs stderr on failure"
else
	test_fail "preflight_check_dns: logs stderr on failure" "trace: $(cat "$_trace_log")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: preflight_check_ntp logs stderr on failure (chronyd path)
# ─────────────────────────────────────────────────────────────────────────────

# Extract the function from preflight-check.sh
eval "$(sed -n '/^preflight_check_ntp()/,/^}/p' scripts/preflight-check.sh)"

cat > "$_mock_dir/chronyd" <<'MOCK'
#!/bin/bash
echo "Could not resolve address" >&2
exit 1
MOCK
chmod +x "$_mock_dir/chronyd"

# Need a timeout mock that just passes through to the real command
cat > "$_mock_dir/timeout" <<'MOCK'
#!/bin/bash
shift  # skip timeout value
"$@"
MOCK
chmod +x "$_mock_dir/timeout"

> "$_trace_log"
(
	export PATH="$_mock_dir:$PATH"
	ntp_servers="10.0.0.99"
	preflight_check_ntp
) 2>/dev/null || true

if grep -q "chronyd -Q.*failed\|UDP probe.*failed" "$_trace_log"; then
	test_pass "preflight_check_ntp: logs stderr on failure"
else
	test_fail "preflight_check_ntp: logs stderr on failure" "trace: $(cat "$_trace_log")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Syntax check all modified scripts
# ─────────────────────────────────────────────────────────────────────────────

_syntax_ok=true
for script in \
	scripts/cluster-upgrade.sh \
	scripts/download-catalog-index.sh \
	scripts/include_all.sh \
	scripts/infra-dns.sh \
	scripts/install-kvm.conf.sh \
	scripts/install-vmware.conf.sh \
	scripts/preflight-check.sh \
	tools/setup-dns.sh \
	tools/setup-ntp.sh; do
	if ! bash -n "$script" 2>/dev/null; then
		test_fail "Syntax check: $script" "bash -n failed"
		_syntax_ok=false
	fi
done
[ "$_syntax_ok" = true ] && test_pass "Syntax check: all modified scripts pass"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: No 'local' outside functions in top-level scripts
# ─────────────────────────────────────────────────────────────────────────────

_local_ok=true
for script in \
	scripts/cluster-upgrade.sh \
	scripts/download-catalog-index.sh \
	scripts/install-kvm.conf.sh \
	scripts/install-vmware.conf.sh \
	tools/setup-dns.sh \
	tools/setup-ntp.sh; do
	# shellcheck: SC2218 could help, but let's just verify manually
	# Check if 'local' appears outside any function body
	_in_func=false
	_bad_local=""
	while IFS= read -r line; do
		if echo "$line" | grep -qP '^\w+\s*\(\)\s*\{'; then
			_in_func=true
		elif echo "$line" | grep -qP '^\}'; then
			_in_func=false
		elif [ "$_in_func" = false ] && echo "$line" | grep -qP '^\s*local\s'; then
			_bad_local="$line"
			break
		fi
	done < "$script"
	if [ -n "$_bad_local" ]; then
		test_fail "No top-level 'local' in $script" "found: $_bad_local"
		_local_ok=false
	fi
done
[ "$_local_ok" = true ] && test_pass "No 'local' outside functions in top-level scripts"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="
[ -z "$FAILURES" ] && echo -e "${GREEN}All tests passed!${NC}" || echo -e "${RED}Some tests failed!${NC}"
exit ${FAILURES:+1}
exit 0
