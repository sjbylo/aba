#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Long-Running Steps
# =============================================================================
# Framework test: has deliberately long-running e2e_run steps so Ctrl-C
# can be sent mid-command to verify the interactive menu appears.
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
	"Step 1: quick pass" \
	"Step 2: long-running (Ctrl-C target)" \
	"Step 3: should run after skip"

suite_begin "dummy-long-running"

# ============================================================================
# 1. Quick pass
# ============================================================================
test_begin "Step 1: quick pass"
e2e_run "Echo hello" "echo 'hello from step 1'"
test_end

# ============================================================================
# 2. Long-running step -- send Ctrl-C here to test menu
# ============================================================================
test_begin "Step 2: long-running (Ctrl-C target)"
e2e_run "Sleeping 300s (send Ctrl-C to test menu)" "echo 'Sleeping... send Ctrl-C now'; sleep 300"
test_end

# ============================================================================
# 3. Should run if step 2 was skipped
# ============================================================================
test_begin "Step 3: should run after skip"
e2e_run "Echo world" "echo 'hello from step 3'"
test_end

suite_end
