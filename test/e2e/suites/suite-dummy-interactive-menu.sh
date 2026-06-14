#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Interactive Menu Test
# =============================================================================
# Framework test: exercises the interactive menu by having e2e_run commands
# that fail deliberately. The operator (or automation) sends menu keys via
# tmux to test [s]kip, [S]kip-suite, [0]restart, [R]etry.
#
# E2E_SKIP_SNAPSHOT_REVERT=1 -- no VMware infrastructure needed.
# =============================================================================

set -u

export E2E_SKIP_SNAPSHOT_REVERT=1

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"

# --- Suite -------------------------------------------------------------------

e2e_setup

plan_tests \
	"Step 1: always passes" \
	"Step 2: deliberate failure (menu test)" \
	"Step 3: should run after skip"

suite_begin "dummy-interactive-menu"

# ============================================================================
# 1. A step that always passes
# ============================================================================
test_begin "Step 1: always passes"
e2e_run "Echo hello" "echo 'hello from step 1'"
test_end

# ============================================================================
# 2. Deliberate failure -- triggers interactive menu
# ============================================================================
test_begin "Step 2: deliberate failure (menu test)"
e2e_run "This command fails" "false"
test_end

# ============================================================================
# 3. Should run if step 2 was skipped
# ============================================================================
test_begin "Step 3: should run after skip"
e2e_run "Echo world" "echo 'hello from step 3'"
test_end

suite_end; _rc=$?

exit $_rc
