#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Fail -- framework lifecycle testing
# =============================================================================
# Minimal suite that always fails on test 2.  Used by test-framework.sh
# to verify failure detection, RC file contents, and interactive prompt.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/setup.sh"

e2e_setup

# Disable interactive mode -- we want immediate failure, no retry prompt
export _E2E_INTERACTIVE=""

plan_tests \
	"Dummy: passing step" \
	"Dummy: deliberate failure"

suite_begin "dummy-fail"

test_begin "Dummy: passing step"
e2e_run "Echo ok" "echo 'This step passes'"
test_end 0

test_begin "Dummy: deliberate failure"
e2e_run "Fail on purpose" "false"
test_end 1

suite_end
