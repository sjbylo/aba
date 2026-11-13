#!/bin/bash
# Test: a real catalog download leaves live aba-catalog-* containers alone
# and still removes ones whose owner pid is dead.
# Regression: parallel downloads each swept every aba-catalog-* container,
# which unmounted a copy that was still running.

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== Catalog container sweep: live podman containers ==="

work=
tag=
live_pid=
retry_pid=
names=()

_cid() {
	podman inspect --format '{{.Id}}' "$1" 2>/dev/null
}

cleanup() {
	local n
	for n in "${names[@]}"; do
		podman rm -f "$n" >/dev/null 2>&1 || true
	done
	if [ -n "$live_pid" ]; then
		kill "$live_pid" 2>/dev/null || true
		wait "$live_pid" 2>/dev/null || true
	fi
	if [ -n "$retry_pid" ]; then
		kill "$retry_pid" 2>/dev/null || true
		wait "$retry_pid" 2>/dev/null || true
	fi
	[ -n "$tag" ] && podman rmi "$tag" >/dev/null 2>&1 || true
	[ -n "$work" ] && rm -rf "$work"
}

if ! command -v podman >/dev/null 2>&1; then
	echo "podman is required"
	exit 1
fi

work=$(mktemp -d)
# Fully qualified: short-name-mode=enforcing refuses an unqualified tag.
tag="localhost/aba-sweep-test:$$"
touch "$work/empty"
printf 'FROM scratch\nCOPY empty /empty\n' > "$work/Containerfile"
if ! podman build -q -t "$tag" -f "$work/Containerfile" "$work" >/dev/null; then
	_fail "build tiny image $tag"
	rm -rf "$work"
	podman rmi "$tag" >/dev/null 2>&1 || true
	echo ""
	echo "Results: $pass passed, $fail failed"
	exit "$fail"
fi
_pass "built tiny image $tag"

# Background jobs are subshells. An EXIT trap set before they start runs
# again when one of them dies, and that second run deletes this image.
sleep infinity &
live_pid=$!
sleep infinity &
retry_pid=$!

sleep 30 &
dead_pid=$!
kill "$dead_pid" 2>/dev/null || true
wait "$dead_pid" 2>/dev/null || true

trap cleanup EXIT

live_name="aba-catalog-redhat-operator-v4.19-${live_pid}"
retry_name="aba-catalog-community-operator-v4.21-${retry_pid}-retry"
dead_name="aba-catalog-certified-operator-v4.18-${dead_pid}"
stale_name="aba-catalog-stale-no-pid"
names=("$live_name" "$retry_name" "$dead_name" "$stale_name")

# A previous failed run may have left the fixed stale name.
podman rm -f "$stale_name" >/dev/null 2>&1 || true

for n in "${names[@]}"; do
	if ! podman create --pull=never --name "$n" "$tag" >/dev/null; then
		_fail "create container $n"
		echo ""
		echo "Results: $pass passed, $fail failed"
		exit "$fail"
	fi
done
_pass "created live, retry, dead-pid, and no-pid containers"

live_id=$(_cid "$live_name")
retry_id=$(_cid "$retry_name")

index=".index/redhat-operator-index-v4.19"
before_lines=0
had_aap=0
if [ -s "$index" ]; then
	before_lines=$(wc -l < "$index")
	grep -q '^ansible-automation-platform-operator ' "$index" && had_aap=1
fi

# Two startups. Each one sweeps. The second is the case that used to delete
# the container the first extract was still using.
if scripts/download-catalog-index.sh redhat-operator 4.19; then
	_pass "first download exited 0"
else
	_fail "first download exited $?"
fi

if scripts/download-catalog-index.sh redhat-operator 4.19; then
	_pass "second download exited 0"
else
	_fail "second download exited $?"
fi

if [ "$(_cid "$live_name")" = "$live_id" ] && [ -n "$live_id" ]; then
	_pass "live container kept ($live_name)"
else
	_fail "live container kept ($live_name)"
fi

if [ "$(_cid "$retry_name")" = "$retry_id" ] && [ -n "$retry_id" ]; then
	_pass "live retry container kept ($retry_name)"
else
	_fail "live retry container kept ($retry_name)"
fi

if [ -n "$(_cid "$dead_name")" ]; then
	_fail "dead-pid container removed ($dead_name)"
else
	_pass "dead-pid container removed ($dead_name)"
fi

if [ -n "$(_cid "$stale_name")" ]; then
	_fail "no-pid container removed ($stale_name)"
else
	_pass "no-pid container removed ($stale_name)"
fi

if [ ! -s "$index" ]; then
	_fail "redhat v4.19 index still present"
else
	after_lines=$(wc -l < "$index")
	if [ "$before_lines" -gt 0 ] && [ "$after_lines" -lt "$before_lines" ]; then
		_fail "index shrank ${before_lines} -> ${after_lines}"
	else
		_pass "index still has ${after_lines} operators"
	fi
fi

if [ "$had_aap" -eq 1 ]; then
	if grep -q '^ansible-automation-platform-operator ' "$index"; then
		_pass "ansible-automation-platform-operator still in the index"
	else
		_fail "ansible-automation-platform-operator still in the index"
	fi
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
