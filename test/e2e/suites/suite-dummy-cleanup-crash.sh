#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Cleanup -- Crash Path
# =============================================================================
# Framework test: register fake clusters + mirrors via the cleanup API,
# then EXIT 1 WITHOUT cleaning up. The NEXT suite's _pre_suite_cleanup
# must find the orphaned cleanup files and process them.
#
# Run this BEFORE suite-dummy-cleanup-happy to test the crash recovery path:
#   run.sh run --suite dummy-cleanup-crash,dummy-cleanup-happy -p 1
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
	"Create fake cluster + mirror resources" \
	"Crash: exit without cleanup"

suite_begin "dummy-cleanup-crash"

_FAKE_DIR="$HOME/aba"

# ============================================================================
# 1. Create fake resources and register for cleanup
# ============================================================================
test_begin "Create fake cluster + mirror resources"

e2e_run "Create fake SNO cluster dir" "
	mkdir -p ${_FAKE_DIR}/e2e-fake-crash-sno
	cat > ${_FAKE_DIR}/e2e-fake-crash-sno/Makefile <<'MKEOF'
delete:
	@echo 'FAKE: deleting cluster e2e-fake-crash-sno'
	@rm -rf \$(CURDIR)
MKEOF
"
e2e_add_to_cluster_cleanup "${_FAKE_DIR}/e2e-fake-crash-sno"

e2e_run "Create fake mirror dir" "
	mkdir -p ${_FAKE_DIR}/e2e-fake-crash-mirror
	cat > ${_FAKE_DIR}/e2e-fake-crash-mirror/Makefile <<'MKEOF'
uninstall:
	@echo 'FAKE: uninstalling mirror e2e-fake-crash-mirror'
	@rm -rf \$(CURDIR)
MKEOF
"
e2e_add_to_mirror_cleanup "${_FAKE_DIR}/e2e-fake-crash-mirror"

e2e_run "Verify fake resources registered" "
	echo '--- Cluster cleanup file ---'
	cat \$HOME/.e2e-harness/logs/dummy-cleanup-crash.cleanup
	echo '--- Mirror cleanup file ---'
	cat \$HOME/.e2e-harness/logs/dummy-cleanup-crash.mirror-cleanup
"

test_end

# ============================================================================
# 2. Crash: exit 1 WITHOUT cleanup (simulates suite abort/kill)
# ============================================================================
test_begin "Crash: exit without cleanup"

echo ""
echo "  *** INTENTIONAL CRASH: exiting without cleanup ***"
echo "  Fake resources left behind for _pre_suite_cleanup to process."
echo "  Expected: next suite's pre-cleanup finds and deletes these."
echo ""

# Exit 1 to simulate a crash. The cleanup files (.cleanup, .mirror-cleanup)
# remain on disk. runner.sh's EXIT trap calls _runner_cleanup which tries
# to clean up, and _pre_suite_cleanup on the next suite run processes
# any remaining files.
exit 1
