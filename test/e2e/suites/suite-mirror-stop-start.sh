#!/usr/bin/env bash
# =============================================================================
# Suite: Mirror Stop/Start
# =============================================================================
# Verifies aba -d mirror stop/start for all three registry vendors.
#
# For each vendor:
#   1. Install registry locally
#   2. Verify running (port listening)
#   3. Stop → verify port closed, data dir intact
#   4. Stop again → idempotent (no error)
#   5. Start → verify port open
#   6. Start again → idempotent (no error)
#   7. Verify registry functional (aba verify)
#   8. Uninstall
#
# Prerequisites:
#   - Internet-connected host with aba installed (conN pool VM)
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/suite-helpers.sh"

# --- Configuration ----------------------------------------------------------

_MIRROR_NAME="e2e-stop-start"
_PORT=5333

_VENDORS=(docker omr quay)

# Build test names
_tnames=("Setup: install aba and configure")
for _v in "${_VENDORS[@]}"; do
	_tnames+=("$_v: stop/start cycle")
done
_tnames+=("omr: stop → uninstall → reinstall (data preserved)")
_tnames+=("omr: --runtime state and status output")
_tnames+=("Cleanup")

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests "${_tnames[@]}"

suite_begin "mirror-stop-start"

preflight_ssh

# ============================================================================
# Setup
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_install_aba

suite_configure_aba
suite_verify_aba_conf

e2e_run "Create mirror dir" "aba mirror --name $_MIRROR_NAME"
e2e_add_to_mirror_cleanup "$PWD/$_MIRROR_NAME"

test_end

# ============================================================================
# Per-vendor stop/start test
# ============================================================================
for _v in "${_VENDORS[@]}"; do

test_begin "$_v: stop/start cycle"

# --- Install ---
e2e_run "Install $_v registry (port $_PORT)" \
	"aba -d $_MIRROR_NAME install --vendor $_v --reg-port $_PORT -y"

e2e_run "Verify registry running" \
	"aba -d $_MIRROR_NAME verify"

e2e_run "Port $_PORT is listening" \
	"ss -tlnp 2>/dev/null | grep -q ':${_PORT} '"

# --- Stop ---
e2e_run "Stop $_v registry" \
	"aba -d $_MIRROR_NAME stop"

e2e_run "Port $_PORT not listening after stop" \
	"! ss -tlnp 2>/dev/null | grep -q ':${_PORT} '"

e2e_run "Data dir still exists after stop" \
	"source \$HOME/.aba/mirror/$_MIRROR_NAME/state.sh && test -d \$reg_root"

# --- Stop idempotent ---
e2e_run "Stop again (idempotent)" \
	"aba -d $_MIRROR_NAME stop"

# --- Start ---
e2e_run "Start $_v registry" \
	"aba -d $_MIRROR_NAME start"

e2e_run "Port $_PORT listening after start" \
	"ss -tlnp 2>/dev/null | grep -q ':${_PORT} '"

# --- Start idempotent ---
e2e_run "Start again (idempotent)" \
	"aba -d $_MIRROR_NAME start"

# --- Verify functional ---
e2e_run "Registry functional after restart" \
	"aba -d $_MIRROR_NAME verify"

# --- Uninstall (clean for next vendor) ---
e2e_run "Uninstall $_v registry" \
	"aba -d $_MIRROR_NAME uninstall --delete-data -y"

test_end

done

# ============================================================================
# Stop → uninstall → reinstall (data preserved)
# ============================================================================
# Regression test for: uninstall a stopped mirror left the Quadlet unit behind,
# causing reinstall to fail with "existing installation found".  The fix: uninstall
# reads reg_running from state.sh, starts the mirror first if stopped, then
# runs mirror-registry uninstall cleanly.
test_begin "omr: stop → uninstall → reinstall (data preserved)"

e2e_run "Install omr registry" \
	"aba -d $_MIRROR_NAME install --vendor omr --reg-port $_PORT -y"

e2e_run "Sync images (populate registry)" \
	"aba -d $_MIRROR_NAME sync --retry"

e2e_run "Verify release image exists before cycle" \
	"cd $_MIRROR_NAME && source ../scripts/include_all.sh && source <(normalize-aba-conf) && source <(normalize-mirror-conf) && export regcreds_dir=\$HOME/.aba/mirror/$_MIRROR_NAME && check_release_image"

e2e_run "Stop registry" \
	"aba -d $_MIRROR_NAME stop"

e2e_run "Verify port closed after stop" \
	"! ss -tlnp 2>/dev/null | grep -q ':${_PORT} '"

e2e_run "Uninstall stopped mirror (keep data)" \
	"aba -d $_MIRROR_NAME uninstall -y"

e2e_run "Verify Quadlet unit removed" \
	"! test -f \$HOME/.config/containers/systemd/quay.container"

e2e_run "Verify data dir still exists" \
	"source \$HOME/.aba/mirror/$_MIRROR_NAME/state.sh 2>/dev/null || true; test -d \${reg_root:-/nonexistent} || test -f \$HOME/omr/auth/admin-password"

e2e_run "Reinstall (should reuse existing data)" \
	"aba -d $_MIRROR_NAME install --vendor omr --reg-port $_PORT -y"

e2e_run "Verify registry running after reinstall" \
	"aba -d $_MIRROR_NAME verify"

e2e_run "Verify release image survived the cycle" \
	"cd $_MIRROR_NAME && source ../scripts/include_all.sh && source <(normalize-aba-conf) && source <(normalize-mirror-conf) && export regcreds_dir=\$HOME/.aba/mirror/$_MIRROR_NAME && check_release_image"

e2e_run "Uninstall (clean for next test)" \
	"aba -d $_MIRROR_NAME uninstall --delete-data -y"

test_end

# ============================================================================
# --runtime state and CLI status output
# ============================================================================
# Verifies that mirror-status.sh --runtime returns correct reg_state for each
# lifecycle phase, and that the human-readable status output shows the right
# labels (especially "stopped" instead of "MISSING").
test_begin "omr: --runtime state and status output"

e2e_run "Install omr registry" \
	"aba -d $_MIRROR_NAME install --vendor omr --reg-port $_PORT -y"

# --- Running state ---
e2e_run "Runtime: reg_state=installed when running (no sync)" \
	"cd $_MIRROR_NAME && ../scripts/mirror-status.sh --runtime | grep -q 'reg_state=installed'"

e2e_run "Status: shows (installed) when running" \
	"aba -d $_MIRROR_NAME status 2>&1 | grep -q '(installed)'"

# --- Stopped state ---
e2e_run "Stop registry" \
	"aba -d $_MIRROR_NAME stop"

e2e_run "Runtime: reg_state=stopped after stop" \
	"cd $_MIRROR_NAME && ../scripts/mirror-status.sh --runtime | grep -q 'reg_state=stopped'"

e2e_run "Runtime: reg_listening=false after stop" \
	"cd $_MIRROR_NAME && ../scripts/mirror-status.sh --runtime | grep -q 'reg_listening=false'"

e2e_run "Status: shows (stopped) not (installed)" \
	"aba -d $_MIRROR_NAME status 2>&1 | grep -q '(stopped)'"

e2e_run "Status: shows 'unknown (registry is stopped)' not MISSING" \
	"aba -d $_MIRROR_NAME status 2>&1 | grep -q 'unknown (registry is stopped)'"

# --- Start again ---
e2e_run "Start registry" \
	"aba -d $_MIRROR_NAME start"

e2e_run "Runtime: reg_state back to installed after start" \
	"cd $_MIRROR_NAME && ../scripts/mirror-status.sh --runtime | grep -q 'reg_state=installed'"

e2e_run "Status: shows (installed) after start" \
	"aba -d $_MIRROR_NAME status 2>&1 | grep -q '(installed)'"

# --- Absent state ---
e2e_run "Uninstall registry" \
	"aba -d $_MIRROR_NAME uninstall --delete-data -y"

e2e_run "Runtime: reg_state=absent after uninstall" \
	"cd $_MIRROR_NAME && ../scripts/mirror-status.sh --runtime | grep -q 'reg_state=absent'"

test_end

# ============================================================================
# Cleanup
# ============================================================================
test_begin "Cleanup"

e2e_run "Remove mirror dir" \
	"rm -rf $_MIRROR_NAME"

test_end

suite_end
