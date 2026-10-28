#!/bin/bash
# Test: CLI flags for --disk-hint, --bond-mode, and aba image set {add|remove|list}
# Verifies that new CLI flags write correct values to cluster.conf and that
# the image set subcommand manages curated image groups in images.conf.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

_tmp=$(mktemp -d /tmp/aba-test-cli-XXXXXX)
trap 'rm -rf "$_tmp" testcl-dh1 testcl-dh2 testcl-dh3' EXIT

export ABA_DO_NOT_UPDATE=1

echo "=== CLI: --disk-hint and --bond-mode flags ==="

# --- Test: global --disk-hint and --bond-mode during cluster create ---
./scripts/aba.sh cluster --name testcl-dh1 --type sno --starting-ip 10.0.0.100 \
	--disk-hint /dev/sda --bond-mode active-backup --step cluster.conf &>/dev/null
if grep -q "^disk_hint=/dev/sda" testcl-dh1/cluster.conf 2>/dev/null; then
	_pass "global --disk-hint written to cluster.conf"
else
	_fail "global --disk-hint not written to cluster.conf"
fi
if grep -q "^bond_mode=active-backup" testcl-dh1/cluster.conf 2>/dev/null; then
	_pass "global --bond-mode written to cluster.conf"
else
	_fail "global --bond-mode not written to cluster.conf"
fi

# --- Test: per-role flags during cluster create ---
./scripts/aba.sh cluster --name testcl-dh2 --type compact --starting-ip 10.0.0.100 \
	--disk-hint-master /dev/nvme0n1 --disk-hint-worker /dev/sdb \
	--bond-mode-master 802.3ad --bond-mode-worker balance-xor --step cluster.conf &>/dev/null
if grep -q "^disk_hint_master=/dev/nvme0n1" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "per-role --disk-hint-master written to cluster.conf"
else
	_fail "per-role --disk-hint-master not written to cluster.conf"
fi
if grep -q "^disk_hint_worker=/dev/sdb" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "per-role --disk-hint-worker written to cluster.conf"
else
	_fail "per-role --disk-hint-worker not written to cluster.conf"
fi
if grep -q "^bond_mode_master=802.3ad" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "per-role --bond-mode-master written to cluster.conf"
else
	_fail "per-role --bond-mode-master not written to cluster.conf"
fi
if grep -q "^bond_mode_worker=balance-xor" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "per-role --bond-mode-worker written to cluster.conf"
else
	_fail "per-role --bond-mode-worker not written to cluster.conf"
fi

# --- Test: global disk_hint remains empty when only per-role set ---
if grep -q "^disk_hint=$" testcl-dh2/cluster.conf 2>/dev/null || \
   grep -qP "^disk_hint=\t" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "global disk_hint stays empty when only per-role flags used"
else
	_fail "global disk_hint unexpectedly set when only per-role flags used"
fi

# --- Test: update existing cluster.conf ---
./scripts/aba.sh -d testcl-dh2 --disk-hint /dev/vda --bond-mode active-backup --validate &>/dev/null
if grep -q "^disk_hint=/dev/vda" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "update existing cluster.conf: --disk-hint overwrites"
else
	_fail "update existing cluster.conf: --disk-hint not overwritten"
fi
if grep -q "^bond_mode=active-backup" testcl-dh2/cluster.conf 2>/dev/null; then
	_pass "update existing cluster.conf: --bond-mode overwrites"
else
	_fail "update existing cluster.conf: --bond-mode not overwritten"
fi

# --- Test: combined global + per-role ---
./scripts/aba.sh cluster --name testcl-dh3 --type standard --starting-ip 10.0.0.100 \
	--disk-hint /dev/sda --disk-hint-master /dev/nvme0n1 \
	--bond-mode active-backup --bond-mode-worker balance-tlb --step cluster.conf &>/dev/null
if grep -q "^disk_hint=/dev/sda" testcl-dh3/cluster.conf 2>/dev/null && \
   grep -q "^disk_hint_master=/dev/nvme0n1" testcl-dh3/cluster.conf 2>/dev/null; then
	_pass "combined global + per-role disk_hint"
else
	_fail "combined global + per-role disk_hint"
fi
if grep -q "^bond_mode=active-backup" testcl-dh3/cluster.conf 2>/dev/null && \
   grep -q "^bond_mode_worker=balance-tlb" testcl-dh3/cluster.conf 2>/dev/null; then
	_pass "combined global + per-role bond_mode"
else
	_fail "combined global + per-role bond_mode"
fi

# --- Test: disk_hint criteria syntax ---
./scripts/aba.sh -d testcl-dh1 --disk-hint "model=VBOX,minSizeGigabytes=200" --validate &>/dev/null
if grep -q '^disk_hint=model=VBOX,minSizeGigabytes=200' testcl-dh1/cluster.conf 2>/dev/null; then
	_pass "criteria-style disk_hint written correctly"
else
	_fail "criteria-style disk_hint not written correctly"
fi

# --- Test: invalid bond mode rejected ---
_out=$(./scripts/aba.sh -d testcl-dh1 --bond-mode "nonsense" --validate 2>&1)
if [ $? -ne 0 ] && echo "$_out" | grep -q "invalid bond mode"; then
	_pass "invalid bond mode rejected"
else
	_fail "invalid bond mode not rejected (exit=$?)"
fi

# --- Test: missing argument rejected ---
_out=$(./scripts/aba.sh -d testcl-dh1 --disk-hint 2>&1)
if [ $? -ne 0 ]; then
	_pass "missing --disk-hint argument rejected"
else
	_fail "missing --disk-hint argument not rejected"
fi
_out=$(./scripts/aba.sh -d testcl-dh1 --bond-mode 2>&1)
if [ $? -ne 0 ]; then
	_pass "missing --bond-mode argument rejected"
else
	_fail "missing --bond-mode argument not rejected"
fi

echo ""
echo "=== CLI: aba image set {add|remove|list} ==="

# Save original images.conf to restore later
_orig_images=""
[ -f images.conf ] && _orig_images=$(cat images.conf)

# --- Test: image set list ---
_out=$(./scripts/aba.sh image set list 2>&1)
if echo "$_out" | grep -q "ocp" && echo "$_out" | grep -q "virt" && echo "$_out" | grep -q "ai"; then
	_pass "image set list shows all 3 sets (ocp, virt, ai)"
else
	_fail "image set list missing sets"
fi

# --- Test: image set add virt ---
_out=$(./scripts/aba.sh image set add virt 2>&1)
if echo "$_out" | grep -q "added.*5 images"; then
	_pass "image set add virt: success message with count"
else
	_fail "image set add virt: unexpected output: $_out"
fi
if grep -q "^# image-set: virt" images.conf 2>/dev/null; then
	_pass "image set add virt: marker block in images.conf"
else
	_fail "image set add virt: no marker block in images.conf"
fi
if grep -q "rhel-guest-image" images.conf 2>/dev/null; then
	_pass "image set add virt: contains expected image"
else
	_fail "image set add virt: missing expected image"
fi

# --- Test: image set list shows virt as added ---
_out=$(./scripts/aba.sh image set list 2>&1)
if echo "$_out" | grep "virt" | grep -q "added"; then
	_pass "image set list: virt shows as added"
else
	_fail "image set list: virt not showing as added"
fi

# --- Test: image set add virt again (re-add = replace) ---
_out=$(./scripts/aba.sh image set add virt 2>&1)
if echo "$_out" | grep -q "added.*5 images"; then
	_pass "image set re-add virt: replaces without error"
else
	_fail "image set re-add virt: unexpected output: $_out"
fi
_count=$(grep -c "^# image-set: virt" images.conf 2>/dev/null)
if [ "$_count" -eq 1 ]; then
	_pass "image set re-add virt: only one marker block"
else
	_fail "image set re-add virt: expected 1 marker, got $_count"
fi

# --- Test: image set remove virt ---
_out=$(./scripts/aba.sh image set remove virt 2>&1)
if echo "$_out" | grep -q "removed"; then
	_pass "image set remove virt: success message"
else
	_fail "image set remove virt: unexpected output: $_out"
fi
if ! grep -q "^# image-set: virt" images.conf 2>/dev/null; then
	_pass "image set remove virt: marker block gone from images.conf"
else
	_fail "image set remove virt: marker block still in images.conf"
fi

# --- Test: image set remove bogus (should fail) ---
_out=$(./scripts/aba.sh image set remove bogus 2>&1)
if [ $? -ne 0 ]; then
	_pass "image set remove bogus: fails with error"
else
	_fail "image set remove bogus: should have failed"
fi

# --- Test: image set add bogus (should fail) ---
_out=$(./scripts/aba.sh image set add bogus 2>&1)
if [ $? -ne 0 ]; then
	_pass "image set add bogus: fails with error"
else
	_fail "image set add bogus: should have failed"
fi

# --- Test: image set (no action) should fail ---
_out=$(./scripts/aba.sh image set 2>&1)
if [ $? -ne 0 ]; then
	_pass "image set with no action: fails with usage"
else
	_fail "image set with no action: should have failed"
fi

# --- Test: image set add (no set name) should fail ---
_out=$(./scripts/aba.sh image set add 2>&1)
if [ $? -ne 0 ]; then
	_pass "image set add with no set name: fails with usage"
else
	_fail "image set add with no set name: should have failed"
fi

# --- Test: add ocp set ---
_out=$(./scripts/aba.sh image set add ocp 2>&1)
if echo "$_out" | grep -q "added"; then
	_pass "image set add ocp: succeeds"
else
	_fail "image set add ocp: unexpected output: $_out"
fi

# Clean up: remove ocp set we just added (if it wasn't there originally)
if [ -n "$_orig_images" ] && ! echo "$_orig_images" | grep -q "^# image-set: ocp"; then
	./scripts/aba.sh image set remove ocp &>/dev/null
fi

# Restore original images.conf
if [ -n "$_orig_images" ]; then
	echo "$_orig_images" > images.conf
elif [ -f images.conf ]; then
	# If there was no original, only remove if it's now empty or only has our test data
	:
fi

# --- Summary ---
echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
