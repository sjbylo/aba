#!/bin/bash
# test-govc-error-handling.sh — Validate the vmp_exists / vm_exists_any / vmw-exists.sh
# error handling fix: vCenter unreachable must return exit=2 (not exit=1).
#
# Run from the ABA workspace root:
#   bash test/func/test-govc-error-handling.sh
#
# Requires: govc configured (vmware.conf), at least one real VM name (con1).

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1

PASS=0 FAIL=0
check() {
	local name=$1 expected=$2 actual=$3
	if [ "$actual" = "$expected" ]; then
		echo "  ✓ PASS: $name (exit=$actual)"
		PASS=$((PASS + 1))
	else
		echo "  ✗ FAIL: $name — expected exit=$expected, got exit=$actual"
		FAIL=$((FAIL + 1))
	fi
}

# --- Setup: temp cluster dir with vmware.conf ---
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT
ln -sfn "$PWD/scripts" "$TDIR/scripts"
ln -sfn "$PWD/templates" "$TDIR/templates"
cp vmware.conf "$TDIR/vmware.conf"
cd "$TDIR"

echo "=== Unit tests: vmp_exists / vmp_is_on / vmp_info ==="
echo ""

# Source the ABA environment
source scripts/include_all.sh 2>/dev/null
source <(normalize-vmware-conf) 2>/dev/null
source scripts/vm-vmw.sh 2>/dev/null
source scripts/vm-provider.sh 2>/dev/null
vm_provider_load vmw 2>/dev/null

# TEST 1: vmp_exists — VM does NOT exist → exit 1
echo "--- vmp_exists (non-existent VM) ---"
rc=0; vmp_exists "govc-test-nonexistent-vm-$$" 2>/dev/null || rc=$?
check "vmp_exists non-existent" 1 "$rc"

# TEST 2: vmp_exists — VM exists (con1) → exit 0
echo "--- vmp_exists (existing VM: con1) ---"
rc=0; vmp_exists "con1" 2>/dev/null || rc=$?
check "vmp_exists existing" 0 "$rc"

# TEST 3: vmp_is_on — powered-on VM → exit 0
echo "--- vmp_is_on (con1) ---"
rc=0; vmp_is_on "con1" 2>/dev/null || rc=$?
check "vmp_is_on powered-on" 0 "$rc"

# TEST 4: vmp_info — existing VM → prints info, exit 0
echo "--- vmp_info (con1) ---"
info=""
rc=0; info=$(vmp_info "con1" 2>/dev/null) || rc=$?
if [ $rc -eq 0 ] && [ -n "$info" ]; then
	echo "  ✓ PASS: vmp_info existing (exit=0, info='$info')"
	PASS=$((PASS + 1))
else
	echo "  ✗ FAIL: vmp_info existing — exit=$rc, info='$info'"
	FAIL=$((FAIL + 1))
fi

# TEST 5: vmp_exists — bad credentials → exit 2 (unreachable)
echo "--- vmp_exists (bad credentials — simulates unreachable vCenter) ---"
rc=0
GOVC_USERNAME=INVALID_USER GOVC_PASSWORD=INVALID_PASS vmp_exists "con1" 2>/dev/null || rc=$?
check "vmp_exists unreachable" 2 "$rc"

# TEST 6: vm_exists_any — no VMs → exit 1
echo ""
echo "--- vm_exists_any (no VMs) ---"
CLUSTER_NAME=govc-test-fake-$$; CP_NAMES="govc-test-fake-$$"; WORKER_NAMES=""
CP_REPLICAS=1; WORKER_REPLICAS=0
rc=0; vm_exists_any 2>/dev/null || rc=$?
check "vm_exists_any no-VMs" 1 "$rc"

# TEST 7: vm_exists_any — real VM → exit 0
echo "--- vm_exists_any (real VM: con1) ---"
CLUSTER_NAME=con1; CP_NAMES="con1"; WORKER_NAMES=""
rc=0; vm_exists_any 2>/dev/null || rc=$?
check "vm_exists_any found" 0 "$rc"

# TEST 8: vm_exists_any — bad credentials → exit 2
echo "--- vm_exists_any (bad credentials) ---"
CLUSTER_NAME=con1; CP_NAMES="con1"; WORKER_NAMES=""
rc=0
GOVC_USERNAME=INVALID_USER GOVC_PASSWORD=INVALID_PASS vm_exists_any 2>/dev/null || rc=$?
check "vm_exists_any unreachable" 2 "$rc"

echo ""
echo "=== Integration tests: vmw-exists.sh ==="
echo ""
cd "$TDIR"

# TEST 9: vmw-exists.sh — no VMs → exit 1
echo "--- vmw-exists.sh (no VMs) ---"
rc=0
CLUSTER_NAME=govc-test-fake-$$ CP_REPLICAS=1 WORKER_REPLICAS=0 \
	CP_NAMES=govc-test-fake-$$ WORKER_NAMES="" \
	bash scripts/vmw-exists.sh 2>/dev/null || rc=$?
check "vmw-exists.sh no-VMs" 1 "$rc"

# TEST 10: vmw-exists.sh — real VM → exit 0
echo "--- vmw-exists.sh (real VM: con1) ---"
rc=0
CLUSTER_NAME=con1 CP_REPLICAS=1 WORKER_REPLICAS=0 \
	CP_NAMES=con1 WORKER_NAMES="" \
	bash scripts/vmw-exists.sh 2>/dev/null || rc=$?
check "vmw-exists.sh found" 0 "$rc"

# TEST 11: vmw-exists.sh — unreachable vCenter → exit 2
# The script re-sources vmware.conf, which overwrites GOVC_* from the environment.
# Point GOVC_URL at a closed local port so normalize cannot restore working creds.
echo "--- vmw-exists.sh (unreachable vCenter) ---"
cp vmware.conf vmware.conf.ok
sed 's|^GOVC_URL=.*|GOVC_URL=https://127.0.0.1:1|' vmware.conf.ok > vmware.conf
rc=0
CLUSTER_NAME=con1 CP_REPLICAS=1 WORKER_REPLICAS=0 \
	CP_NAMES=con1 WORKER_NAMES="" \
	bash scripts/vmw-exists.sh 2>/dev/null || rc=$?
cp vmware.conf.ok vmware.conf
check "vmw-exists.sh unreachable" 2 "$rc"

echo ""
echo "=== Regression: jq-safe JSON + refresh capture ==="
echo ""

# TEST 12: _vmw_vm_json stdout is parseable JSON (no try_cmd/govc chatter).
# The 2>&1 regression produced: parse error: Invalid numeric literal at line 4.
echo "--- _vmw_vm_json stdout is valid JSON ---"
json=""
rc=0
json=$(_vmw_vm_json "con1") || rc=$?
if [ $rc -ne 0 ]; then
	echo "  ✗ FAIL: _vmw_vm_json con1 — exit=$rc"
	FAIL=$((FAIL + 1))
elif printf '%s' "$json" | grep -q '\[ABA\]'; then
	echo "  ✗ FAIL: _vmw_vm_json con1 — try_cmd chatter on stdout"
	FAIL=$((FAIL + 1))
elif ! printf '%s\n' "$json" | jq -e '.virtualMachines[0].runtime.powerState' >/dev/null; then
	echo "  ✗ FAIL: _vmw_vm_json con1 — jq cannot parse stdout"
	FAIL=$((FAIL + 1))
else
	echo "  ✓ PASS: _vmw_vm_json stdout is JSON (exit=0)"
	PASS=$((PASS + 1))
fi

# TEST 13: missing VM still yields parseable JSON (or empty), never chatter.
echo "--- _vmw_vm_json missing VM is jq-safe ---"
json=""
rc=0
json=$(_vmw_vm_json "govc-test-nonexistent-vm-$$") || rc=$?
if [ $rc -ne 0 ]; then
	echo "  ✗ FAIL: _vmw_vm_json missing — expected exit=0, got $rc"
	FAIL=$((FAIL + 1))
elif printf '%s' "$json" | grep -q '\[ABA\]'; then
	echo "  ✗ FAIL: _vmw_vm_json missing — try_cmd chatter on stdout"
	FAIL=$((FAIL + 1))
elif [ -n "$json" ] && ! printf '%s\n' "$json" | jq -e '.' >/dev/null; then
	echo "  ✗ FAIL: _vmw_vm_json missing — stdout is not JSON"
	FAIL=$((FAIL + 1))
else
	echo "  ✓ PASS: _vmw_vm_json missing is jq-safe (exit=0)"
	PASS=$((PASS + 1))
fi

# TEST 14: refresh-style capture under ERR trap + set -e (the .autorefresh hole).
# Without ||, exit 1 from vmw-exists.sh is fatal and ISO upload never reaches create.
echo "--- refresh capture of vmw-exists.sh no-VMs (set -e + ERR trap) ---"
cap=$(
	set -e
	_exists_rc=0
	CLUSTER_NAME=govc-test-fake-$$ CP_REPLICAS=1 WORKER_REPLICAS=0 \
		CP_NAMES=govc-test-fake-$$ WORKER_NAMES="" \
		bash scripts/vmw-exists.sh || _exists_rc=$?
	echo "$_exists_rc"
) || cap="ABORT:$?"
check "refresh capture no-VMs" 1 "$cap"

echo ""
echo "═══════════════════════════════════════════"
printf "  PASS: %d  FAIL: %d\n" "$PASS" "$FAIL"
echo "═══════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
	echo "  ✓ ALL TESTS PASSED"
	exit 0
else
	echo "  ✗ SOME TESTS FAILED"
	exit 1
fi
