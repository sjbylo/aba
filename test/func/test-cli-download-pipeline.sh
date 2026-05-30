#!/bin/bash
# Test: CLI download pipeline — parallel downloads, race protection, version change
#
# Aggressively tests the cli/Makefile download pipeline:
#   1. Basic download + extract cycle
#   2. Parallel race: two processes trigger the same tarball — no corruption
#   3. Version change: ocp_version change triggers re-download
#   4. Stale run_once state: tarball deleted, state says "done" — must re-download
#   5. cli-download-all.sh modes: default (non-blocking), --wait (blocking), --reset
#   6. Idempotent re-run: everything up-to-date is a fast no-op
#   7. Concurrent download + install: install waits for download, extracts clean binary
#
# Usage:  bash test/func/test-cli-download-pipeline.sh
# Duration: ~3-4 minutes (downloads real tarballs from mirror.openshift.com)

set -o pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh
trap - ERR

OCP_VER=$(grep '^ocp_version=' aba.conf | cut -d= -f2 | awk '{print $1}')
[ -z "$OCP_VER" ] && echo "FATAL: ocp_version not set in aba.conf" && exit 1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass_count=0
fail_count=0

test_pass() {
	echo -e "  ${GREEN}PASS${NC}: $1"
	pass_count=$((pass_count + 1))
}

test_fail() {
	echo -e "  ${RED}FAIL${NC}: $1"
	fail_count=$((fail_count + 1))
}

section() {
	echo ""
	echo "=================================================================="
	echo "  $1"
	echo "=================================================================="
}

verify_tarball() {
	local f="$1"
	if [ ! -f "$f" ]; then
		echo "MISSING"
		return 1
	fi
	if ! gzip -t "$f" 2>/dev/null; then
		echo "CORRUPT"
		return 1
	fi
	echo "OK"
	return 0
}

verify_binary() {
	local bin="$1"
	if [ ! -x "$bin" ]; then
		echo "MISSING"
		return 1
	fi
	if ! "$bin" --help >/dev/null 2>&1; then
		echo "INVALID"
		return 1
	fi
	echo "OK"
	return 0
}

# Save original state to restore at the end
SAVED_OC=$(ls ~/bin/oc 2>/dev/null && cp -p ~/bin/oc /tmp/.aba-test-oc-backup 2>/dev/null; echo ok)
SAVED_OI=$(ls ~/bin/openshift-install 2>/dev/null && cp -p ~/bin/openshift-install /tmp/.aba-test-oi-backup 2>/dev/null; echo ok)

cleanup() {
	echo ""
	echo "Restoring original binaries..."
	[ -f /tmp/.aba-test-oc-backup ] && cp -p /tmp/.aba-test-oc-backup ~/bin/oc 2>/dev/null
	[ -f /tmp/.aba-test-oi-backup ] && cp -p /tmp/.aba-test-oi-backup ~/bin/openshift-install 2>/dev/null
	rm -f /tmp/.aba-test-oc-backup /tmp/.aba-test-oi-backup
}
trap cleanup EXIT

echo "CLI Download Pipeline Test"
echo "ocp_version=$OCP_VER"
echo ""

# ──────────────────────────────────────────────────────────────────────
section "Test 1: Clean download + extract cycle"
# Delete tarball + binary, run make — should download and extract cleanly
# ──────────────────────────────────────────────────────────────────────

rm -f ~/bin/oc ~/bin/kubectl
local_tar=$(make --no-print-directory -sC cli -p 2>/dev/null | grep '^local_oc_tar_file' | head -1 | awk '{print $3}')
[ -z "$local_tar" ] && local_tar="openshift-client-linux-amd64-rhel9-${OCP_VER}.tar.gz"
rm -f "cli/$local_tar" "cli/${local_tar}.sha256"
make -sC cli reset-download-oc 2>/dev/null || true

output=$(make -C cli ~/bin/oc 2>&1)
rc=$?

if [ $rc -eq 0 ]; then
	test_pass "make ~/bin/oc exited 0"
else
	test_fail "make ~/bin/oc exited $rc"
fi

result=$(verify_tarball "cli/$local_tar")
if [ "$result" = "OK" ]; then
	test_pass "Tarball $local_tar is valid gzip"
else
	test_fail "Tarball $local_tar: $result"
fi

result=$(verify_binary ~/bin/oc)
if [ "$result" = "OK" ]; then
	test_pass "~/bin/oc executes correctly"
else
	test_fail "~/bin/oc: $result"
fi

ver=$(~/bin/oc version --client 2>&1 | head -1 | awk '{print $3}')
if [ "$ver" = "$OCP_VER" ]; then
	test_pass "oc version matches ocp_version ($OCP_VER)"
else
	test_fail "oc version=$ver expected=$OCP_VER"
fi

# ──────────────────────────────────────────────────────────────────────
section "Test 2: Parallel race — two processes trigger same tarball"
# Both trigger $(rhel9_oc_tar_file) simultaneously.
# run_once must serialize: only one curl, no corruption.
# ──────────────────────────────────────────────────────────────────────

rm -f ~/bin/oc ~/bin/kubectl "cli/$local_tar" "cli/${local_tar}.sha256"
make -sC cli reset-download-oc 2>/dev/null || true

# Process A: make download-oc (downloads both rhel8+rhel9)
make -C cli download-oc >/tmp/.aba-test-dl-A.log 2>&1 &
pid_a=$!

# Tiny delay so A's run_once registers first, then B hits the same ID
sleep 0.3

# Process B: make ~/bin/oc (triggers $(local_oc_tar_file) + extracts)
make -C cli ~/bin/oc >/tmp/.aba-test-dl-B.log 2>&1 &
pid_b=$!

echo "  Process A (download-oc): PID $pid_a"
echo "  Process B (~/bin/oc):    PID $pid_b"

wait $pid_a
rc_a=$?
wait $pid_b
rc_b=$?

echo "  Process A exit: $rc_a"
echo "  Process B exit: $rc_b"

if [ $rc_a -eq 0 ] && [ $rc_b -eq 0 ]; then
	test_pass "Both processes exited 0 (no error)"
else
	test_fail "Process A=$rc_a, B=$rc_b (expected both 0)"
fi

result=$(verify_tarball "cli/$local_tar")
if [ "$result" = "OK" ]; then
	test_pass "Tarball not corrupted after parallel access"
else
	test_fail "Tarball corrupted after parallel access: $result"
fi

result=$(verify_binary ~/bin/oc)
if [ "$result" = "OK" ]; then
	test_pass "Binary valid after parallel download+install"
else
	test_fail "Binary invalid after parallel access: $result"
fi

# The critical check: binary integrity, not curl count.
# run_once may let both processes enter the recipe, but only one downloads
# while the other waits. Both may log "Downloading" if they run sequentially.
# What matters: no corruption.
sha_a=$(sha256sum "cli/$local_tar" 2>/dev/null | awk '{print $1}')
sha_ref=$(tar -C /tmp -xmzf "cli/$local_tar" oc 2>/dev/null && sha256sum /tmp/oc | awk '{print $1}')
sha_bin=$(sha256sum ~/bin/oc 2>/dev/null | awk '{print $1}')
rm -f /tmp/oc
if [ -n "$sha_bin" ] && [ "$sha_bin" = "$sha_ref" ]; then
	test_pass "Installed binary matches tarball content (integrity verified)"
else
	test_fail "Installed binary SHA mismatch (corruption): bin=$sha_bin tarball=$sha_ref"
fi

rm -f /tmp/.aba-test-dl-A.log /tmp/.aba-test-dl-B.log

# ──────────────────────────────────────────────────────────────────────
section "Test 3: Stale run_once state — tarball deleted, state says done"
# Delete tarball but keep run_once state. Must detect and re-download.
# ──────────────────────────────────────────────────────────────────────

rm -f ~/bin/oc ~/bin/kubectl "cli/$local_tar" "cli/${local_tar}.sha256"
# Do NOT reset run_once state — that's the point of this test

output=$(make -C cli ~/bin/oc 2>&1)
rc=$?

if [ $rc -eq 0 ]; then
	test_pass "make ~/bin/oc recovered from stale state (exit 0)"
else
	test_fail "make ~/bin/oc failed to recover from stale state (exit $rc)"
fi

if echo "$output" | grep -q 'Cannot open'; then
	test_fail "tar saw missing tarball — stale state not detected"
else
	test_pass "No 'Cannot open' error (stale state was reset)"
fi

result=$(verify_binary ~/bin/oc)
if [ "$result" = "OK" ]; then
	test_pass "Binary valid after stale-state recovery"
else
	test_fail "Binary invalid after stale-state recovery: $result"
fi

# ──────────────────────────────────────────────────────────────────────
section "Test 4: Idempotent re-run — already up to date"
# Everything exists and is current. Should be a fast no-op.
# ──────────────────────────────────────────────────────────────────────

start_t=$SECONDS
output=$(make -C cli ~/bin/oc 2>&1)
elapsed=$((SECONDS - start_t))

if echo "$output" | grep -q 'Extracting'; then
	test_fail "Idempotent run re-extracted (should be no-op)"
else
	test_pass "Idempotent run: no extraction"
fi

if echo "$output" | grep -q 'Downloading'; then
	test_fail "Idempotent run re-downloaded (should be no-op)"
else
	test_pass "Idempotent run: no download"
fi

if [ $elapsed -le 3 ]; then
	test_pass "Idempotent run fast (${elapsed}s <= 3s)"
else
	test_fail "Idempotent run slow (${elapsed}s > 3s)"
fi

# ──────────────────────────────────────────────────────────────────────
section "Test 5: cli-download-all.sh modes"
# ──────────────────────────────────────────────────────────────────────

# 5a: --wait when all downloads exist — should return quickly and silently
start_t=$SECONDS
output=$(scripts/cli-download-all.sh --wait 2>&1)
rc=$?
elapsed=$((SECONDS - start_t))

if [ $rc -eq 0 ]; then
	test_pass "cli-download-all.sh --wait exits 0"
else
	test_fail "cli-download-all.sh --wait exits $rc"
fi

if [ $elapsed -le 5 ]; then
	test_pass "--wait fast when nothing to do (${elapsed}s)"
else
	test_fail "--wait slow (${elapsed}s > 5s)"
fi

# 5b: --reset then --wait — should re-download
scripts/cli-download-all.sh --reset 2>/dev/null
rm -f "cli/$local_tar" "cli/${local_tar}.sha256"

start_t=$SECONDS
output=$(scripts/cli-download-all.sh --wait 2>&1)
rc=$?
elapsed=$((SECONDS - start_t))

if [ $rc -eq 0 ]; then
	test_pass "--reset then --wait exits 0"
else
	test_fail "--reset then --wait exits $rc"
fi

result=$(verify_tarball "cli/$local_tar")
if [ "$result" = "OK" ]; then
	test_pass "Tarball re-downloaded after --reset"
else
	test_fail "Tarball after --reset: $result"
fi

# 5c: default mode (non-blocking) — should return quickly
scripts/cli-download-all.sh --reset 2>/dev/null
rm -f "cli/$local_tar" "cli/${local_tar}.sha256"

start_t=$SECONDS
scripts/cli-download-all.sh 2>/dev/null
elapsed=$((SECONDS - start_t))

if [ $elapsed -le 3 ]; then
	test_pass "Default mode returns quickly (${elapsed}s, download in background)"
else
	test_fail "Default mode too slow (${elapsed}s > 3s)"
fi

# Wait for background download to finish before next test
scripts/cli-download-all.sh --wait 2>/dev/null

result=$(verify_tarball "cli/$local_tar")
if [ "$result" = "OK" ]; then
	test_pass "Background download completed successfully"
else
	test_fail "Background download tarball: $result"
fi

# ──────────────────────────────────────────────────────────────────────
section "Test 6: Version change triggers re-download"
# openshift-install tarball filename includes ocp_version.
# Changing ocp_version must trigger a re-download + re-extract.
# ──────────────────────────────────────────────────────────────────────

# Use openshift-install for this test (its tarball name embeds ocp_version)
oi_tar="openshift-install-linux-${OCP_VER}.tar.gz"

# Ensure current version is installed
make -sC cli reset-download-openshift-install 2>/dev/null || true
rm -f ~/bin/openshift-install "cli/$oi_tar" "cli/${oi_tar}.sha256"
make -C cli ~/bin/openshift-install >/dev/null 2>&1
rc=$?

if [ $rc -eq 0 ]; then
	test_pass "Current version ($OCP_VER) installed"
else
	test_fail "Failed to install current version (exit $rc)"
fi

ver=$(~/bin/openshift-install version 2>&1 | head -1 | awk '{print $2}')
if [ "$ver" = "$OCP_VER" ]; then
	test_pass "openshift-install version = $OCP_VER"
else
	test_fail "openshift-install version=$ver expected=$OCP_VER"
fi

# Now test: if we pass a different ocp_version to make, the OLD binary
# should be detected as stale (tarball prerequisite for new version is missing).
# We use dry-run to avoid actually downloading a different version.
dry_output=$(make -C cli -n ~/bin/openshift-install ocp_version=0.0.1 2>&1)

if echo "$dry_output" | grep -q '_fetch-openshift-install'; then
	test_pass "Version change triggers re-download (dry-run shows _fetch)"
else
	test_fail "Version change NOT detected in dry-run"
fi

if echo "$dry_output" | grep -q '_extract-openshift-install\|Extracting'; then
	test_pass "Version change triggers re-extract (dry-run shows _extract)"
else
	test_fail "Version change does NOT trigger re-extract"
fi

# ──────────────────────────────────────────────────────────────────────
section "Test 7: Concurrent download + install (aggressive)"
# Hammer: 3 processes simultaneously download + install oc.
# All must succeed, binary must be valid at the end.
# ──────────────────────────────────────────────────────────────────────

rm -f ~/bin/oc ~/bin/kubectl "cli/$local_tar" "cli/${local_tar}.sha256"
make -sC cli reset-download-oc 2>/dev/null || true

pids=()
for i in 1 2 3; do
	(
		make -C cli ~/bin/oc >/dev/null 2>&1
		exit $?
	) &
	pids+=($!)
	sleep 0.1
done

echo "  Launched 3 concurrent make ~/bin/oc: PIDs ${pids[*]}"

all_ok=true
for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		all_ok=false
	fi
done

if $all_ok; then
	test_pass "All 3 concurrent make ~/bin/oc succeeded (extraction serialized by run_once)"
else
	test_fail "Some concurrent processes failed"
fi

result=$(verify_tarball "cli/$local_tar")
if [ "$result" = "OK" ]; then
	test_pass "Tarball intact after 3-way concurrent access"
else
	test_fail "Tarball after 3-way race: $result"
fi

result=$(verify_binary ~/bin/oc)
if [ "$result" = "OK" ]; then
	test_pass "Binary valid after 3-way concurrent access"
else
	test_fail "Binary after 3-way race: $result"
fi

# Final integrity: extract fresh and compare
tar -C /tmp -xmzf "cli/$local_tar" oc 2>/dev/null
if cmp -s /tmp/oc ~/bin/oc; then
	test_pass "Binary matches fresh extraction (no corruption)"
else
	test_fail "Binary differs from fresh extraction (CORRUPTION DETECTED)"
fi
rm -f /tmp/oc

# ──────────────────────────────────────────────────────────────────────
section "Test 8: make download blocks with output (UX check)"
# Ensures 'make download-oc' is synchronous and produces output
# ──────────────────────────────────────────────────────────────────────

rm -f "cli/$local_tar" "cli/${local_tar}.sha256"
make -sC cli reset-download-oc 2>/dev/null || true

start_t=$SECONDS
output=$(make -C cli download-oc 2>&1)
elapsed=$((SECONDS - start_t))
rc=$?

if [ $rc -eq 0 ]; then
	test_pass "make download-oc exits 0"
else
	test_fail "make download-oc exits $rc"
fi

if echo "$output" | grep -q 'Downloading'; then
	test_pass "make download-oc shows download progress"
else
	test_fail "make download-oc produced no download output (ran in background?)"
fi

if [ $elapsed -ge 2 ]; then
	test_pass "make download-oc blocked (${elapsed}s — synchronous)"
else
	test_fail "make download-oc returned too fast (${elapsed}s — may be async)"
fi

# ══════════════════════════════════════════════════════════════════════
echo ""
echo "=================================================================="
echo "                       RESULTS"
echo "=================================================================="
echo ""
echo -e "  ${GREEN}Passed${NC}: $pass_count"
echo -e "  ${RED}Failed${NC}: $fail_count"
echo ""

if [ $fail_count -eq 0 ]; then
	echo -e "${GREEN}ALL TESTS PASSED${NC}"
	exit 0
else
	echo -e "${RED}SOME TESTS FAILED${NC}"
	exit 1
fi
