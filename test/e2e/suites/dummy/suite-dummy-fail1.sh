#!/usr/bin/env bash
# Dummy suite: intentional FAIL
set -u
export E2E_SKIP_SNAPSHOT_REVERT=1
_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"

e2e_setup
plan_tests "Pass step" "Fail step"
suite_begin "dummy-fail1"

test_begin "Pass step"
e2e_run "Echo OK" "echo pass"
test_end 0

test_begin "Fail step"
e2e_run "Sleep 2s" "sleep 2"
test_end 1

suite_end
