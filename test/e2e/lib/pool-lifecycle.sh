#!/usr/bin/env bash
# =============================================================================
# COMPATIBILITY WRAPPER -- Sources pool-ops.sh (the canonical location)
# =============================================================================
# pool-lifecycle.sh was merged into vm-ops.sh + pool-ops.sh in Phase 4.
# This wrapper exists so existing consumers (suites, setup.sh, setup-infra.sh)
# continue to work during the transition.
# =============================================================================

_E2E_LIB_DIR_COMPAT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_E2E_LIB_DIR_COMPAT/pool-ops.sh"
