#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- VM Operations (Composable Helpers)
# =============================================================================
# Pure _vm_* composable helpers for VM configuration. No orchestration logic --
# just individual VM steps that are composed by pool-ops.sh and runner.sh.
#
# Merged from vm-helpers.sh and pool-lifecycle.sh (Phase 4).
#
# IMPORTANT -- heredoc + stdin hazard:
#   Every _vm_* helper pipes a heredoc into 'ssh ... bash', so the remote
#   bash reads its script from stdin.  Commands like dnf/yum (Python-based)
#   can read from the same stdin even with -y, consuming lines that bash
#   has not yet executed.  To avoid this:
#     - Keep dnf/yum calls as the LAST command in a heredoc, or
#     - Redirect their stdin: dnf install -y ... < /dev/null
#   Never add new commands after a dnf/yum call in a heredoc block.
# =============================================================================

_E2E_LIB_DIR_VMOPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source remote helpers if not already loaded
if ! type _wait_for_ssh >/dev/null; then
	source "$_E2E_LIB_DIR_VMOPS/remote.sh"
fi
if ! type pool_domain >/dev/null; then
	source "$_E2E_LIB_DIR_VMOPS/config-helpers.sh"
fi

# Source split modules
source "$_E2E_LIB_DIR_VMOPS/vm-clone.sh"
source "$_E2E_LIB_DIR_VMOPS/vm-network.sh"
source "$_E2E_LIB_DIR_VMOPS/vm-provision.sh"
