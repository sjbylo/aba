#!/bin/bash
# Functional test: reg_check_v2_auth handles both Basic and Bearer auth.
#
# Tests the shared registry auth verification function from reg-common.sh.
# Uses a local Docker registry (Basic auth) and optionally a omr
# registry (Bearer auth) if available.
#
# Prerequisites: podman, openssl, httpd-tools (htpasswd)
# Non-destructive: creates temporary containers, cleans up on exit.

set -euo pipefail

cd "$(dirname "$0")/../.."

source scripts/include_all.sh
source scripts/reg-common.sh

_pass=0
_fail=0
_total=0
_tmpdir=$(mktemp -d)
_containers=()

_cleanup() {
	for c in "${_containers[@]}"; do
		podman rm -f "$c" >/dev/null 2>&1 || true
	done
	rm -rf "$_tmpdir"
}
trap _cleanup EXIT

_check() {
	local test_name="$1" expect="$2"
	shift 2
	_total=$(( _total + 1 ))
	local rc=0
	"$@" || rc=$?
	if [ "$expect" = "pass" ] && [ "$rc" -eq 0 ]; then
		echo "PASS: $test_name"
		_pass=$(( _pass + 1 ))
	elif [ "$expect" = "fail" ] && [ "$rc" -ne 0 ]; then
		echo "PASS: $test_name (correctly failed)"
		_pass=$(( _pass + 1 ))
	else
		echo "FAIL: $test_name (expected $expect, got rc=$rc)"
		_fail=$(( _fail + 1 ))
	fi
}

echo "=== reg_check_v2_auth Tests ==="
echo ""

# --- Setup: Docker registry with Basic auth ---
_port=15995
_user="testuser"
_pw="testpass123"
_certs="$_tmpdir/certs"
_auth="$_tmpdir/auth"
_container="aba-test-reg-$$"

mkdir -p "$_certs" "$_auth" "$_tmpdir/data"

# Generate self-signed cert
openssl genrsa -out "$_certs/registry.key" 2048 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "$_certs/registry.key" \
	-sha256 -days 1 -out "$_certs/registry.crt" \
	-subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' >/dev/null 2>&1

# Generate htpasswd
htpasswd -Bbn "$_user" "$_pw" > "$_auth/htpasswd"

# Start Docker registry with Basic auth
if ! podman run -d \
	-p ${_port}:5000 \
	--name "$_container" \
	-v "${_tmpdir}/data:/var/lib/registry:Z" \
	-v "${_certs}:/certs:Z" \
	-v "${_auth}:/auth:Z" \
	-e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
	-e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.crt \
	-e REGISTRY_HTTP_TLS_KEY=/certs/registry.key \
	-e REGISTRY_AUTH=htpasswd \
	-e 'REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm' \
	-e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
	docker.io/library/registry:latest 2>&1; then
	echo "SKIP: Could not start Docker registry container (podman error)"
	exit 0
fi
_containers+=("$_container")

# Wait for registry to be ready
for i in $(seq 1 15); do
	curl -k -s "https://localhost:${_port}/v2/" -o /dev/null 2>/dev/null && break
	sleep 1
done

echo "--- Docker registry (Basic auth, port $_port) ---"

_check "Basic auth: correct credentials" "pass" \
	reg_check_v2_auth "https://localhost:${_port}" "$_user" "$_pw"

_check "Basic auth: wrong password" "fail" \
	reg_check_v2_auth "https://localhost:${_port}" "$_user" "wrongpass"

_check "Basic auth: wrong username" "fail" \
	reg_check_v2_auth "https://localhost:${_port}" "nobody" "$_pw"

_check "Basic auth: empty credentials" "fail" \
	reg_check_v2_auth "https://localhost:${_port}" "" ""

_check "Unreachable host" "fail" \
	reg_check_v2_auth "https://localhost:19999" "$_user" "$_pw"

# --- Optional: Bearer auth (omr) if running locally ---
_qng_names=$(podman ps --format '{{.Names}}' 2>/dev/null || true)
if echo "$_qng_names" | grep -q systemd-quay; then
	echo ""
	echo "--- Local omr (Bearer auth, port 8443) ---"
	_qng_user="init"
	_qng_pw=$(awk -F"'" '/^reg_pw=/{print $2}' mirror/mirror.conf 2>/dev/null || true)
	if [ -n "$_qng_pw" ]; then
		_check "Bearer auth: correct credentials" "pass" \
			reg_check_v2_auth "https://localhost:8443" "$_qng_user" "$_qng_pw"

		_check "Bearer auth: wrong password" "fail" \
			reg_check_v2_auth "https://localhost:8443" "$_qng_user" "wrongpass"
	else
		echo "SKIP: Could not read omr credentials from mirror/mirror.conf"
	fi
else
	echo ""
	echo "SKIP: No local omr registry — Bearer auth tests skipped"
fi

# --- Summary ---
echo ""
echo "=== Results: $_pass passed, $_fail failed (of $_total) ==="
echo ""

[ "$_fail" -gt 0 ] && exit 1
exit 0
