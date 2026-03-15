#!/usr/bin/env bash
# Dummy suite: fast pass (25s total)
set -u
export E2E_SKIP_SNAPSHOT_REVERT=1
_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"

e2e_setup
plan_tests "Test A" "Test B"
suite_begin "dummy-fast5"

test_begin "Test A"
e2e_run "Sleep 25s" "sleep 25"
e2e_run "Echo OK" "echo dummy-fast5-A"
test_end 0

test_begin "Test B"
e2e_run "Sleep 5s" "sleep 5"
e2e_run "Echo OK" "echo dummy-fast5-B"
test_end 0

suite_end
echo "SUCCESS: dummy-fast5"
