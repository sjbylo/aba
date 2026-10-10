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

_VENDORS=(docker quay-ng quay)

# Build test names
_tnames=("Setup: install aba and configure")
for _v in "${_VENDORS[@]}"; do
	_tnames+=("$_v: stop/start cycle")
done
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
# Cleanup
# ============================================================================
test_begin "Cleanup"

e2e_run "Remove mirror dir" \
	"rm -rf $_MIRROR_NAME"

test_end

suite_end
