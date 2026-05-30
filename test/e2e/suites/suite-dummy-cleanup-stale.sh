#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Cleanup -- Stale References
# =============================================================================
# Framework test: create cleanup files that reference directories which
# no longer exist (or never existed). Verifies _pre_suite_cleanup and
# runner.sh handle gracefully -- no crashes, just warnings.
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
	"Create stale cleanup references" \
	"Verify stale dirs do not exist" \
	"Cleanup: suite_end processes stale files"

suite_begin "dummy-cleanup-stale"

_FAKE_DIR="$HOME/aba"

# ============================================================================
# 1. Create cleanup files pointing to non-existent directories
# ============================================================================
test_begin "Create stale cleanup references"

# Register resources that don't actually exist on disk
e2e_add_to_cluster_cleanup "${_FAKE_DIR}/e2e-nonexistent-cluster"
e2e_add_to_mirror_cleanup "${_FAKE_DIR}/e2e-nonexistent-mirror"

e2e_run "Verify cleanup files created" "
	echo '--- Cluster cleanup file ---'
	cat \$HOME/.e2e-harness/logs/dummy-cleanup-stale.cleanup
	echo '--- Mirror cleanup file ---'
	cat \$HOME/.e2e-harness/logs/dummy-cleanup-stale.mirror-cleanup
"

test_end

# ============================================================================
# 2. Confirm the referenced dirs really don't exist
# ============================================================================
test_begin "Verify stale dirs do not exist"

e2e_run "Verify cluster dir absent" "test ! -d ${_FAKE_DIR}/e2e-nonexistent-cluster"
e2e_run "Verify mirror dir absent" "test ! -d ${_FAKE_DIR}/e2e-nonexistent-mirror"

test_end

# ============================================================================
# 3. Cleanup: suite_end triggers cleanup, which must handle missing dirs
# ============================================================================
test_begin "Cleanup: suite_end processes stale files"

# The real test happens when suite_end / _runner_cleanup runs:
# it should see the cleanup files, SSH to the target, find the dirs missing,
# log a warning, and still exit cleanly.
e2e_run "Suite will end -- cleanup should handle stale references gracefully" \
	"echo 'Stale references registered. suite_end will process them.'"

test_end

suite_end; _rc=$?

exit $_rc
