#!/bin/bash
# Test: cluster-clean.sh refuses when .install-complete exists; force=1 allowed.
# Regression for: Clean-while-installed orphaning VMs (BACKLOG #B85 context).

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_tmp=$(mktemp -d /tmp/aba-clean-gate.XXXXXX)
trap 'rm -rf "$_tmp"' EXIT

echo "=== test-cluster-clean-gate ==="

# Fake aba root so Makefile.cluster's SCRIPTS=../scripts resolves
mkdir -p "$_tmp/cluster"
ln -sfn "$PWD/scripts" "$_tmp/scripts"
ln -sfn "$PWD/templates" "$_tmp/templates"
ln -sfn "../templates/Makefile.cluster" "$_tmp/cluster/Makefile"
ln -sfn ../scripts "$_tmp/cluster/scripts"
ln -sfn ../templates "$_tmp/cluster/templates"
# include_all looks for aba.conf at repo root (../aba.conf from cluster)
ln -sfn "$PWD/aba.conf" "$_tmp/aba.conf" 2>/dev/null || touch "$_tmp/aba.conf"
touch "$_tmp/cluster/cluster.conf" "$_tmp/cluster/install-config.yaml" \
	"$_tmp/cluster/agent-config.yaml" "$_tmp/cluster/.install-complete"

# --- Refused while installed ---
if ( cd "$_tmp/cluster" && bash scripts/cluster-clean.sh ) >/tmp/aba-clean-gate.out 2>&1; then
	_fail "clean should fail while .install-complete exists"
else
	_pass "clean fails while installed"
fi
if grep -qiE 'Refusing to clean|install-complete|aba -d .* delete' /tmp/aba-clean-gate.out; then
	_pass "error mentions refuse / delete"
else
	_fail "error text missing refuse/delete guidance"
	cat /tmp/aba-clean-gate.out
fi
if [[ -f "$_tmp/cluster/.install-complete" && -f "$_tmp/cluster/agent-config.yaml" ]]; then
	_pass "artifacts kept after refused clean"
else
	_fail "artifacts were removed despite refusal"
fi

# --- make clean (no force) also refuses ---
if make -sC "$_tmp/cluster" clean >/tmp/aba-clean-gate-make.out 2>&1; then
	_fail "make clean should fail while installed"
else
	_pass "make clean fails while installed"
fi

# --- force=1 allowed (post-delete path) ---
if make -sC "$_tmp/cluster" clean force=1 >/tmp/aba-clean-gate-force.out 2>&1; then
	_pass "make clean force=1 succeeds"
else
	_fail "make clean force=1 failed"
	cat /tmp/aba-clean-gate-force.out
fi
if [[ ! -f "$_tmp/cluster/.install-complete" && ! -f "$_tmp/cluster/agent-config.yaml" ]]; then
	_pass "force clean removed marker and agent-config"
else
	_fail "force clean left artifacts behind"
fi
if [[ -f "$_tmp/cluster/cluster.conf" ]]; then
	_pass "cluster.conf preserved"
else
	_fail "cluster.conf was removed"
fi

# --- clean without install marker succeeds ---
touch "$_tmp/cluster/install-config.yaml" "$_tmp/cluster/agent-config.yaml"
if ( cd "$_tmp/cluster" && bash scripts/cluster-clean.sh ) >/dev/null 2>&1; then
	_pass "clean succeeds when not installed"
else
	_fail "clean should succeed when .install-complete absent"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
