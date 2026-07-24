#!/usr/bin/env bash
# =============================================================================
# Suite: Dummy Cleanup -- Happy Path
# =============================================================================
# Framework test: register fake clusters + mirrors via the cleanup API,
# then delete them in the suite's own cleanup phase. Verifies the cleanup
# code paths work end-to-end without needing real OCP clusters or registries.
#
# Fake resources are directories with minimal Makefiles that support
# 'make delete' / 'make uninstall' targets (matching ABA's Makefile contract).
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
	"Create fake cluster resources" \
	"Create fake mirror resources" \
	"Verify fake resources exist" \
	"Cleanup: delete clusters via aba" \
	"Cleanup: uninstall mirrors via aba" \
	"Verify all resources removed"

suite_begin "dummy-cleanup-happy"

_FAKE_DIR="$HOME/aba"

# ============================================================================
# 1. Create fake cluster resources with Makefile delete targets
# ============================================================================
test_begin "Create fake cluster resources"

e2e_run "Create fake SNO cluster dir" "
	mkdir -p ${_FAKE_DIR}/e2e-fake-sno1
	cat > ${_FAKE_DIR}/e2e-fake-sno1/Makefile <<'MKEOF'
delete:
	@echo 'FAKE: deleting cluster e2e-fake-sno1'
	@rm -rf \$(CURDIR)
MKEOF
"
e2e_add_to_cluster_cleanup "${_FAKE_DIR}/e2e-fake-sno1"

e2e_run "Create fake compact cluster dir" "
	mkdir -p ${_FAKE_DIR}/e2e-fake-compact1
	cat > ${_FAKE_DIR}/e2e-fake-compact1/Makefile <<'MKEOF'
delete:
	@echo 'FAKE: deleting cluster e2e-fake-compact1'
	@rm -rf \$(CURDIR)
MKEOF
"
e2e_add_to_cluster_cleanup "${_FAKE_DIR}/e2e-fake-compact1"

test_end

# ============================================================================
# 2. Create fake mirror resources with Makefile uninstall targets
# ============================================================================
test_begin "Create fake mirror resources"

e2e_run "Create fake mirror dir" "
	mkdir -p ${_FAKE_DIR}/e2e-fake-mirror1
	cat > ${_FAKE_DIR}/e2e-fake-mirror1/Makefile <<'MKEOF'
uninstall:
	@echo 'FAKE: uninstalling mirror e2e-fake-mirror1'
	@rm -rf \$(CURDIR)
MKEOF
"
e2e_add_to_mirror_cleanup "${_FAKE_DIR}/e2e-fake-mirror1"

test_end

# ============================================================================
# 3. Verify resources exist before cleanup
# ============================================================================
test_begin "Verify fake resources exist"

e2e_run "Verify fake SNO exists" "test -d ${_FAKE_DIR}/e2e-fake-sno1"
e2e_run "Verify fake compact exists" "test -d ${_FAKE_DIR}/e2e-fake-compact1"
e2e_run "Verify fake mirror exists" "test -d ${_FAKE_DIR}/e2e-fake-mirror1"

test_end

# ============================================================================
# 4. Cleanup: delete fake clusters (make -C, since fake dirs have no aba structure)
# ============================================================================
test_begin "Cleanup: delete clusters via aba"

e2e_run "Delete fake SNO" "make -C ${_FAKE_DIR}/e2e-fake-sno1 delete"
e2e_remove_from_cluster_cleanup "${_FAKE_DIR}/e2e-fake-sno1"
e2e_run "Delete fake compact" "make -C ${_FAKE_DIR}/e2e-fake-compact1 delete"
e2e_remove_from_cluster_cleanup "${_FAKE_DIR}/e2e-fake-compact1"

test_end

# ============================================================================
# 5. Cleanup: uninstall fake mirrors
# ============================================================================
test_begin "Cleanup: uninstall mirrors via aba"

e2e_run "Uninstall fake mirror" "make -C ${_FAKE_DIR}/e2e-fake-mirror1 uninstall"
e2e_remove_from_mirror_cleanup "${_FAKE_DIR}/e2e-fake-mirror1"

test_end

# ============================================================================
# 6. Verify all resources removed
# ============================================================================
test_begin "Verify all resources removed"

e2e_run "Verify fake SNO removed" "test ! -d ${_FAKE_DIR}/e2e-fake-sno1"
e2e_run "Verify fake compact removed" "test ! -d ${_FAKE_DIR}/e2e-fake-compact1"
e2e_run "Verify fake mirror removed" "test ! -d ${_FAKE_DIR}/e2e-fake-mirror1"
e2e_run "Verify no cleanup files remain" "
	ls ${E2E_LOG_DIR:-\$HOME/.e2e-harness/logs}/dummy-cleanup-happy.cleanup && exit 1 || true
	ls ${E2E_LOG_DIR:-\$HOME/.e2e-harness/logs}/dummy-cleanup-happy.mirror-cleanup && exit 1 || true
	echo 'No stale cleanup files -- OK'
"

test_end

suite_end; _rc=$?

exit $_rc
