#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Pass -- framework lifecycle testing
# =============================================================================
# Minimal suite that always passes.  Used by test-framework.sh to exercise
# the run.sh coordinator, runner.sh, deploy, stop, restart, status, etc.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/setup.sh"

e2e_setup

plan_tests \
	"Dummy: echo hello" \
	"Dummy: sleep and succeed"

suite_begin "dummy-pass"

test_begin "Dummy: echo hello"
e2e_run "Echo hello" "echo 'Hello from dummy-pass on pool ${POOL_NUM:-?}'"
test_end 0

test_begin "Dummy: sleep and succeed"
e2e_run "Short sleep" "sleep 3"
e2e_run "Echo done" "echo 'dummy-pass complete'"
test_end 0

suite_end
