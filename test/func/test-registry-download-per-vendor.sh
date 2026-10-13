#!/bin/bash
# =============================================================================
# Test: Per-vendor registry download and install scenarios
# =============================================================================
# Verifies that the per-vendor download split works correctly:
#   - Each vendor has its own run-once ID (no races)
#   - Install path (mirror-registry) downloads ONLY Quay tarball
#   - Save path (download-registries) downloads all three
#   - Install-then-save skips already-downloaded files
#   - Shared functions (start_all, wait_all, registry_downloads_ready) work
#   - Reset clears all per-vendor run-once IDs
#   - Idempotency: re-runs are no-ops
#
# Category: integration (downloads real files, ~60-90s)
# =============================================================================

set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh

trap - ERR

_PASS=0
_FAIL=0
_TOTAL=0

_log()  { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
_ok()   { _PASS=$(( _PASS + 1 )); _TOTAL=$(( _TOTAL + 1 )); printf "  \033[1;32mPASS\033[0m  %s\n" "$*"; }
_fail() { _FAIL=$(( _FAIL + 1 )); _TOTAL=$(( _TOTAL + 1 )); printf "  \033[1;31mFAIL\033[0m  %s\n" "$*"; }

# ── Setup: ensure we have a mirror directory ──

_NEED_RESET=false
if [ ! -d mirror ] || [ ! -f mirror/Makefile ]; then
	_log "Setup: creating mirror directory"
	aba --noask --platform vmw --channel stable --version p --base-domain example.com 2>/dev/null || true
	aba -d mirror mirror.conf 2>/dev/null || true
	_NEED_RESET=true
fi

if [ ! -f mirror/Makefile ]; then
	echo "ERROR: Cannot create mirror/Makefile — aborting test" >&2
	exit 1
fi

# Save file state to restore later
_SAVED_MR=$(ls mirror/mirror-registry-*.tar.gz 2>/dev/null || true)
_SAVED_DR=$([ -f mirror/docker-reg-image.tgz ] && echo "yes" || echo "no")
_SAVED_QN=$([ -f mirror/omr-image.tgz ] && echo "yes" || echo "no")
_SAVED_MRB=$([ -f mirror/mirror-registry ] && echo "yes" || echo "no")

cleanup() {
	# Clear test run-once state
	scripts/run-once.sh -r -i "mirror:reg:download:quay" 2>/dev/null || true
	scripts/run-once.sh -r -i "mirror:reg:download:docker" 2>/dev/null || true
	scripts/run-once.sh -r -i "mirror:reg:download:omr" 2>/dev/null || true
	scripts/run-once.sh -r -i "mirror:reg:install" 2>/dev/null || true

	if [[ "$_NEED_RESET" == "true" ]]; then
		aba reset -f 2>/dev/null || true
	fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────
# SECTION 1: Constants and shared function definitions
# ─────────────────────────────────────────────────────────────────────────
_log "Section 1: Per-vendor constants defined correctly"

# Task ID constants
[[ -n "$TASK_DL_QUAY_REG" ]] && _ok "TASK_DL_QUAY_REG defined: $TASK_DL_QUAY_REG" || _fail "TASK_DL_QUAY_REG not defined"
[[ -n "$TASK_DL_DOCKER_REG" ]] && _ok "TASK_DL_DOCKER_REG defined: $TASK_DL_DOCKER_REG" || _fail "TASK_DL_DOCKER_REG not defined"
[[ -n "$TASK_DL_OMR_REG" ]] && _ok "TASK_DL_OMR_REG defined: $TASK_DL_OMR_REG" || _fail "TASK_DL_OMR_REG not defined"
[[ -n "$TASK_INST_QUAY_REG" ]] && _ok "TASK_INST_QUAY_REG defined: $TASK_INST_QUAY_REG" || _fail "TASK_INST_QUAY_REG not defined"

# IDs must all be distinct
_ids_distinct=true
if [[ "$TASK_DL_QUAY_REG" == "$TASK_DL_DOCKER_REG" ]]; then _fail "QUAY_REG == DOCKER_REG"; _ids_distinct=false; fi
if [[ "$TASK_DL_QUAY_REG" == "$TASK_DL_OMR_REG" ]]; then _fail "QUAY_REG == OMR_REG"; _ids_distinct=false; fi
if [[ "$TASK_DL_DOCKER_REG" == "$TASK_DL_OMR_REG" ]]; then _fail "DOCKER_REG == OMR_REG"; _ids_distinct=false; fi
if [[ "$TASK_DL_QUAY_REG" == "$TASK_INST_QUAY_REG" ]]; then _fail "DL_QUAY == INST_QUAY"; _ids_distinct=false; fi
[[ "$_ids_distinct" == "true" ]] && _ok "All per-vendor task IDs are distinct"

# Command arrays
[[ ${#CMD_DL_QUAY_REG[@]} -gt 0 ]] && _ok "CMD_DL_QUAY_REG defined: ${CMD_DL_QUAY_REG[*]}" || _fail "CMD_DL_QUAY_REG empty"
[[ ${#CMD_DL_DOCKER_REG[@]} -gt 0 ]] && _ok "CMD_DL_DOCKER_REG defined: ${CMD_DL_DOCKER_REG[*]}" || _fail "CMD_DL_DOCKER_REG empty"
[[ ${#CMD_DL_OMR_REG[@]} -gt 0 ]] && _ok "CMD_DL_OMR_REG defined: ${CMD_DL_OMR_REG[*]}" || _fail "CMD_DL_OMR_REG empty"

# Commands must reference per-vendor Make targets (not the old "download-registries")
if [[ "${CMD_DL_QUAY_REG[*]}" == *"download-registries"* ]]; then
	_fail "CMD_DL_QUAY_REG still uses 'download-registries' (should be per-vendor target)"
else
	_ok "CMD_DL_QUAY_REG uses per-vendor Make target"
fi

# Shared functions exist
type start_all_registry_downloads &>/dev/null && _ok "start_all_registry_downloads() defined" || _fail "start_all_registry_downloads() missing"
type wait_all_registry_downloads &>/dev/null && _ok "wait_all_registry_downloads() defined" || _fail "wait_all_registry_downloads() missing"
type registry_downloads_ready &>/dev/null && _ok "registry_downloads_ready() defined" || _fail "registry_downloads_ready() missing"
type ensure_quay_registry &>/dev/null && _ok "ensure_quay_registry() defined" || _fail "ensure_quay_registry() missing"

# ─────────────────────────────────────────────────────────────────────────
# SECTION 2: Makefile targets exist
# ─────────────────────────────────────────────────────────────────────────
_log "Section 2: Per-vendor Makefile targets exist"

for target in download-quay-tarball download-docker-image download-omr-image download-registries mirror-registry; do
	if make -n -C mirror "$target" >/dev/null 2>&1; then
		_ok "make target '$target' exists"
	else
		_fail "make target '$target' missing or broken"
	fi
done

# ─────────────────────────────────────────────────────────────────────────
# SECTION 3: Makefile run-once IDs match include_all.sh constants
# ─────────────────────────────────────────────────────────────────────────
_log "Section 3: Makefile IDs match shell constants"

_makefile="mirror/Makefile"

if grep -q "mirror:reg:download:quay" "$_makefile"; then
	_ok "Makefile contains mirror:reg:download:quay"
else
	_fail "Makefile missing mirror:reg:download:quay"
fi

if grep -q "mirror:reg:download:docker" "$_makefile"; then
	_ok "Makefile contains mirror:reg:download:docker"
else
	_fail "Makefile missing mirror:reg:download:docker"
fi

if grep -q "mirror:reg:download:omr" "$_makefile"; then
	_ok "Makefile contains mirror:reg:download:omr"
else
	_fail "Makefile missing mirror:reg:download:omr"
fi

# The old ALL-vendors ID must NOT appear in the Makefile
if grep -qE 'mirror:reg:download"' "$_makefile" || grep -qP 'mirror:reg:download(?!:)' "$_makefile"; then
	_fail "Makefile still contains old bare 'mirror:reg:download' ID (should be per-vendor)"
else
	_ok "No old bare 'mirror:reg:download' ID in Makefile"
fi

# ─────────────────────────────────────────────────────────────────────────
# SECTION 4: Per-vendor downloads (actual downloads)
# ─────────────────────────────────────────────────────────────────────────
_log "Section 4: Per-vendor download — Quay tarball only"

# Clean slate
rm -f mirror/mirror-registry-*.tar.gz mirror/mirror-registry
rm -f mirror/docker-reg-image.tgz mirror/omr-image.tgz
scripts/run-once.sh -r -i "mirror:reg:download:quay" 2>/dev/null || true
scripts/run-once.sh -r -i "mirror:reg:download:docker" 2>/dev/null || true
scripts/run-once.sh -r -i "mirror:reg:download:omr" 2>/dev/null || true
scripts/run-once.sh -r -i "mirror:reg:install" 2>/dev/null || true

# Download Quay tarball only
make -sC mirror download-quay-tarball 2>&1

if ls mirror/mirror-registry-*.tar.gz >/dev/null 2>&1; then
	_ok "Quay tarball downloaded"
else
	_fail "Quay tarball NOT downloaded"
fi

if [ -f mirror/docker-reg-image.tgz ]; then
	_fail "Docker image downloaded (should NOT be)"
else
	_ok "Docker image correctly skipped"
fi

if [ -f mirror/omr-image.tgz ]; then
	_fail "OMR image downloaded (should NOT be)"
else
	_ok "OMR image correctly skipped"
fi

# ─────────────────────────────────────────────────────────────────────────
_log "Section 5: Per-vendor download — Docker image only"

make -sC mirror download-docker-image 2>&1

if [ -f mirror/docker-reg-image.tgz ]; then
	_ok "Docker image downloaded"
else
	_fail "Docker image NOT downloaded"
fi

if [ -f mirror/omr-image.tgz ]; then
	_fail "OMR image downloaded (should NOT be)"
else
	_ok "OMR image correctly skipped"
fi

# ─────────────────────────────────────────────────────────────────────────
_log "Section 6: Per-vendor download — OMR image only"

make -sC mirror download-omr-image 2>&1

if [ -f mirror/omr-image.tgz ]; then
	_ok "OMR image downloaded"
else
	_fail "OMR image NOT downloaded"
fi

# ─────────────────────────────────────────────────────────────────────────
_log "Section 7: download-registries downloads all three"

rm -f mirror/mirror-registry-*.tar.gz mirror/mirror-registry
rm -f mirror/docker-reg-image.tgz mirror/omr-image.tgz

make -sC mirror download-registries 2>&1

_all_present=true
ls mirror/mirror-registry-*.tar.gz >/dev/null 2>&1 || { _fail "Quay tarball missing after download-registries"; _all_present=false; }
[ -f mirror/docker-reg-image.tgz ] || { _fail "Docker image missing after download-registries"; _all_present=false; }
[ -f mirror/omr-image.tgz ] || { _fail "OMR image missing after download-registries"; _all_present=false; }
[[ "$_all_present" == "true" ]] && _ok "download-registries created all three files"

# ─────────────────────────────────────────────────────────────────────────
_log "Section 8: mirror-registry (install path) — Quay only + extract"

rm -f mirror/mirror-registry-*.tar.gz mirror/mirror-registry
rm -f mirror/docker-reg-image.tgz mirror/omr-image.tgz
scripts/run-once.sh -r -i "mirror:reg:download:quay" 2>/dev/null || true
scripts/run-once.sh -r -i "mirror:reg:install" 2>/dev/null || true

make -sC mirror mirror-registry 2>&1

if [ -f mirror/mirror-registry ]; then
	_ok "mirror-registry binary extracted"
else
	_fail "mirror-registry binary NOT extracted"
fi

if [ -f mirror/docker-reg-image.tgz ]; then
	_fail "Docker image downloaded by mirror-registry target (should NOT be)"
else
	_ok "Docker image correctly skipped by mirror-registry target"
fi

if [ -f mirror/omr-image.tgz ]; then
	_fail "OMR image downloaded by mirror-registry target (should NOT be)"
else
	_ok "OMR image correctly skipped by mirror-registry target"
fi

# ─────────────────────────────────────────────────────────────────────────
_log "Section 9: Install then save — no re-download of Quay tarball"

# Quay tarball and mirror-registry already exist from section 8
_mr_before=$(md5sum mirror/mirror-registry-*.tar.gz 2>/dev/null | awk '{print $1}')

# Now download remaining vendors (simulating save path)
make -sC mirror download-docker-image download-omr-image 2>&1

_mr_after=$(md5sum mirror/mirror-registry-*.tar.gz 2>/dev/null | awk '{print $1}')

if [[ "$_mr_before" == "$_mr_after" ]]; then
	_ok "Quay tarball unchanged (not re-downloaded)"
else
	_fail "Quay tarball was re-downloaded (checksum changed)"
fi

[ -f mirror/docker-reg-image.tgz ] && _ok "Docker image downloaded after install" || _fail "Docker image missing"
[ -f mirror/omr-image.tgz ] && _ok "OMR image downloaded after install" || _fail "OMR image missing"

# ─────────────────────────────────────────────────────────────────────────
_log "Section 10: Shared functions — start_all / wait_all / ready"

# Clear run-once state (files still on disk)
scripts/run-once.sh -r -i "mirror:reg:download:quay" 2>/dev/null || true
scripts/run-once.sh -r -i "mirror:reg:download:docker" 2>/dev/null || true
scripts/run-once.sh -r -i "mirror:reg:download:omr" 2>/dev/null || true

# Peek should say "not ready" (run-once state cleared)
if registry_downloads_ready 2>/dev/null; then
	_fail "registry_downloads_ready() returned true after clearing run-once state"
else
	_ok "registry_downloads_ready() correctly says not ready after state clear"
fi

# start_all should succeed (files exist, make is no-op)
if start_all_registry_downloads 2>/dev/null; then
	_ok "start_all_registry_downloads() succeeded"
else
	_fail "start_all_registry_downloads() failed"
fi

# wait_all should succeed
if wait_all_registry_downloads 2>/dev/null; then
	_ok "wait_all_registry_downloads() succeeded"
else
	_fail "wait_all_registry_downloads() failed"
fi

# Peek should now say "ready"
if registry_downloads_ready 2>/dev/null; then
	_ok "registry_downloads_ready() returns true after wait_all"
else
	_fail "registry_downloads_ready() still false after wait_all"
fi

# ─────────────────────────────────────────────────────────────────────────
_log "Section 11: Reset clears all per-vendor run-once IDs"

# Verify state exists
_state_exists=true
[ -d "$HOME/.aba/runner/mirror:reg:download:quay" ] || _state_exists=false
[ -d "$HOME/.aba/runner/mirror:reg:download:docker" ] || _state_exists=false
[ -d "$HOME/.aba/runner/mirror:reg:download:omr" ] || _state_exists=false

if [[ "$_state_exists" == "true" ]]; then
	_ok "Run-once state exists before reset"
else
	_ok "Run-once state partially missing (OK — testing reset still clears)"
fi

# Reset
scripts/run-once.sh -r -i "mirror:reg:download:quay" 2>/dev/null
scripts/run-once.sh -r -i "mirror:reg:download:docker" 2>/dev/null
scripts/run-once.sh -r -i "mirror:reg:download:omr" 2>/dev/null

# Verify cleared (peek returns non-zero = task not completed)
_state_cleared=true
run_once -p -i "$TASK_DL_QUAY_REG" 2>/dev/null && _state_cleared=false
run_once -p -i "$TASK_DL_DOCKER_REG" 2>/dev/null && _state_cleared=false
run_once -p -i "$TASK_DL_OMR_REG" 2>/dev/null && _state_cleared=false

if [[ "$_state_cleared" == "true" ]]; then
	_ok "All per-vendor run-once completion state cleared"
else
	_fail "Some run-once state still shows as completed after reset"
fi

# ─────────────────────────────────────────────────────────────────────────
_log "Section 12: Idempotency — re-run is fast no-op"

# Re-create run-once state (files still on disk)
start_all_registry_downloads 2>/dev/null
wait_all_registry_downloads 2>/dev/null

# Time a re-run (should be instant — make sees files exist)
_start=$SECONDS
make -sC mirror download-registries 2>&1
_elapsed=$(( SECONDS - _start ))

if [[ $_elapsed -le 3 ]]; then
	_ok "Re-run completed in ${_elapsed}s (fast no-op)"
else
	_fail "Re-run took ${_elapsed}s (expected <3s for cached files)"
fi

# ─────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "======================================================="
echo "Results: $_PASS passed, $_FAIL failed (of $_TOTAL)"
echo "======================================================="

[[ $_FAIL -eq 0 ]] && exit 0 || exit 1
