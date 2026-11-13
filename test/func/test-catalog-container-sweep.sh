#!/bin/bash
# Test: catalog container names encode a live owner pid
# Regression: the startup sweep deleted a container another download was copying.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== Catalog container sweep: owner pid ==="

_sleeper=
cleanup() {
	if [ -n "$_sleeper" ]; then
		kill "$_sleeper" 2>/dev/null || true
		wait "$_sleeper" 2>/dev/null || true
	fi
}
trap cleanup EXIT

# Sourcing must stop before auth, pull, or the sweep.
source scripts/download-catalog-index.sh

if type -t _catalog_container_in_use >/dev/null; then
	_pass "helper is defined"
else
	_fail "helper is defined"
	echo ""
	echo "Results: $pass passed, $fail failed"
	exit "$fail"
fi

if type -t aba_abort >/dev/null; then
	_fail "sourcing stopped before the extractor"
else
	_pass "sourcing stopped before the extractor"
fi

_assert_pid() {
	local name="$1" want="$2" got
	if got=$(_catalog_container_owner_pid "$name"); then
		if [ "$got" = "$want" ]; then
			_pass "$name -> $want"
		else
			_fail "$name -> '$got', wanted '$want'"
		fi
	else
		_fail "$name -> no pid, wanted '$want'"
	fi
}

_assert_no_pid() {
	local name="$1"
	if _catalog_container_owner_pid "$name" >/dev/null; then
		_fail "$name has no owner pid"
	else
		_pass "$name has no owner pid"
	fi
}

_assert_pid "aba-catalog-redhat-operator-v4.19-4242" 4242
_assert_pid "aba-catalog-certified-operator-v4.18-4242" 4242
_assert_pid "aba-catalog-community-operator-v5.0-4242" 4242
_assert_pid "aba-catalog-redhat-operator-v4.19-4242-retry" 4242
_assert_pid "aba-catalog-community-operator-v5.1-4242-retry" 4242

# The version's digits must not be read as the owner.
_assert_no_pid "aba-catalog-certified-operator-v4.19"
_assert_no_pid "aba-catalog-redhat-operator-v4.19-retry"
_assert_no_pid "aba-catalog-stale-no-pid"
_assert_no_pid "aba-catalog-redhat-operator-v4.19-0"
_assert_no_pid "aba-catalog-redhat-operator-v4.19-08"

if _catalog_container_in_use "aba-catalog-redhat-operator-v4.19-0"; then
	_fail "pid 0 treated as live (kill -0 0 signals this process group)"
else
	_pass "pid 0 is not a live owner"
fi

if _catalog_container_in_use "aba-catalog-certified-operator-v4.20-$$"; then
	_pass "this test's pid counts as in use"
else
	_fail "this test's pid counts as in use"
fi

sleep infinity &
_sleeper=$!

if _catalog_container_in_use "aba-catalog-redhat-operator-v4.19-$_sleeper"; then
	_pass "live sleeper pid is in use"
else
	_fail "live sleeper pid is in use"
fi

if _catalog_container_in_use "aba-catalog-community-operator-v4.21-${_sleeper}-retry"; then
	_pass "live sleeper retry name is in use"
else
	_fail "live sleeper retry name is in use"
fi

kill "$_sleeper" 2>/dev/null || true
wait "$_sleeper" 2>/dev/null || true
_dead=$_sleeper
_sleeper=

if _catalog_container_in_use "aba-catalog-redhat-operator-v4.19-$_dead"; then
	_fail "dead pid still in use"
else
	_pass "dead pid is not in use"
fi

if _catalog_container_in_use "aba-catalog-redhat-operator-v4.19-${_dead}-retry"; then
	_fail "dead retry pid still in use"
else
	_pass "dead retry pid is not in use"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
