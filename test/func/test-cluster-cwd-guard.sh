#!/bin/bash
# aba cluster from inside a cluster directory must not write that cluster.conf.

set -eo pipefail

cd "$(dirname "$0")/../.."

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

dir=$(mktemp -d "$PWD/test-cluster-cwd-XXXX")
trap 'rm -rf "$dir"' EXIT
printf '%s\n' '# Cluster Makefile' > "$dir/Makefile"
printf '%s\n' 'num_masters=3' 'master_mem=25' > "$dir/cluster.conf"
before=$(cat "$dir/cluster.conf")

set +e
out=$(cd "$dir" && aba cluster --name other --type sno --mmem 99 --yes 2>&1)
rc=$?
set -e

after=$(cat "$dir/cluster.conf")
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'ABA repo root'; then
	_pass "aba cluster from a cluster directory is refused"
else
	_fail "aba cluster from a cluster directory is refused (rc=$rc): $out"
fi
if [ "$before" = "$after" ]; then
	_pass "cluster.conf in the current directory is unchanged"
else
	_fail "cluster.conf in the current directory is unchanged: $after"
fi

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
