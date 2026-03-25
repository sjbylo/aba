#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- Shared Setup Functions
# =============================================================================
# Reusable setup helpers for bastion management, registry cleanup, etc.
# ABA installation is handled inline by each suite (git clone or curl).
# =============================================================================

_E2E_LIB_DIR_SU="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source other libs if not already loaded
if ! type remote_exec &>/dev/null 2>&1; then
    source "$_E2E_LIB_DIR_SU/remote.sh"
fi
if ! type configure_internal_bastion &>/dev/null 2>&1; then
    source "$_E2E_LIB_DIR_SU/pool-lifecycle.sh"
fi

# --- setup_bastion ----------------------------------------------------------
#
# Initialize an internal (air-gapped) bastion VM by cloning from template.
# Clones the template, powers on, and applies configure_internal_bastion.
#
# Usage: setup_bastion CLONE_NAME [TEMPLATE] [DIS_SSH_USER]
#
# Example: setup_bastion dis1 aba-e2e-template-rhel8 steve
#
setup_bastion() {
    local clone_name="$1"
    local template="${2:-${VM_TEMPLATES[${INT_BASTION_RHEL_VER:-rhel8}]:-aba-e2e-template-rhel8}}"
    local test_user="${3:-${DIS_SSH_USER:-$VM_DEFAULT_USER}}"

    echo "=== setup_bastion: clone $template -> $clone_name ==="

    # Install govc if needed
    e2e_run "Install govc" "aba --dir cli ~/bin/govc"

    # Clone from template (destroys old clone if present)
    clone_vm "$template" "$clone_name"

    # Apply the internal bastion configuration profile
    configure_internal_bastion "$clone_name" "$VM_DEFAULT_USER" "$test_user"

    echo "=== setup_bastion complete: $clone_name ==="
}

# --- setup_connected_bastion ------------------------------------------------
#
# Initialize a connected (internet-facing) bastion VM by cloning from template.
#
# Usage: setup_connected_bastion CLONE_NAME [TEMPLATE]
#
setup_connected_bastion() {
    local clone_name="$1"
    local template="${2:-${VM_TEMPLATES[${INT_BASTION_RHEL_VER:-rhel8}]:-aba-e2e-template-rhel8}}"

    echo "=== setup_connected_bastion: clone $template -> $clone_name ==="

    # Clone from template (destroys old clone if present)
    clone_vm "$template" "$clone_name"

    # Apply connected bastion configuration profile
    configure_connected_bastion "$clone_name"

    echo "=== setup_connected_bastion complete: $clone_name ==="
}

# --- reset_internal_bastion -------------------------------------------------
#
# Reset the internal (air-gapped) bastion to a clean state WITHOUT re-cloning.
# Assumes clone-and-check has already created and configured the disN VM.
#
# Handles two installation scenarios:
#   - Connected suites: registry was installed on disN remotely FROM conN.
#     The uninstall already happened from conN in the suite setup block.
#     (Rule 6: uninstall from the same host that installed.)
#   - Airgapped suites: registry was installed on disN locally.
#     The aba CLI and make should be available from the previous run.
#
# In both cases, leftover Quay data directories may persist with immutable
# attrs that prevent re-install.  This function always cleans those up.
#
# Usage: reset_internal_bastion
#   (uses INTERNAL_BASTION from the calling suite)
#
reset_internal_bastion() {
    local _dis_host="${INTERNAL_BASTION:?INTERNAL_BASTION not set}"
    # Extract bare hostname for curl check (strip user@ prefix if present)
    local _dis_bare="${_dis_host#*@}"

    echo "=== reset_internal_bastion: $_dis_host ==="

    local _aba_root="${_ABA_ROOT:-$HOME/aba}"

    # NOTE: We do NOT rsync the aba tree to disN here.  Only aba itself
    # (via 'mirror sync', 'bundle', etc.) should manage files on disN.
    # Rsyncing from the E2E framework bypasses aba's workflow and can mask bugs.

    # 1. Uninstall the registry using aba's own uninstall, from conN.
    #    Rule 6: uninstall from the same host that installed.
    e2e_run "Uninstall registry from conN" \
        "cd ${_aba_root} && aba -d mirror uninstall"

    # 2. Verify the registry is actually down.
    e2e_run "Verify registry is down on $_dis_bare" \
        "! curl -sk --connect-timeout 5 https://${_dis_bare}:8443/v2/"

    # 3. Clean slate on disN: remove aba tree and caches.
    e2e_run_remote "Remove aba tree on internal bastion" \
        "rm -rf ~/aba"
    # Disabled: destroys podman internal state (pause process), causing
    # "invalid internal status" on next run. aba uninstall above is sufficient.
    #e2e_run_remote "Clean podman images on internal bastion" \
    #    "podman system prune --all --force; podman rmi --all --force"
    e2e_run_remote "Clean oc-mirror caches on internal bastion" \
        "rm -rf ~/.cache/agent ~/.oc-mirror"
    # Disabled: destroys podman internal state.
    #e2e_run_remote "Clean containers storage on internal bastion" \
    #    "sudo rm -rf ~/.local/share/containers/storage"

    echo "=== reset_internal_bastion complete ==="
}

# --- _cleanup_con_quay ------------------------------------------------------
#
# Pre-suite cleanup of registry state on conN. Called by runner.sh
# before each suite to prevent stale state from a previous crashed or
# incomplete suite run.
#
# Two-tier approach:
#   Tier 1 (aba way): If aba's mirror/.available marker exists, use
#          'aba -d mirror uninstall' -- the proper uninstall path.
#   Tier 2 (brute-force): If tier 1 didn't clean up and registry remnants
#          remain (containers), force-remove everything except the pool
#          registry container.
#
# Guard: The pool registry container ("pool-registry") is always excluded
#        from brute-force cleanup.
#
_cleanup_con_quay() {
    local _aba_root="${_ABA_ROOT:-$HOME/aba}"

    local _did_uninstall=""

    local _pool_reg_present=""
    [ -d "$POOL_REG_DIR" ] && _pool_reg_present=1

    # Tier 1: use aba's own unregister/uninstall for the configured registry.
    # For externally-managed registries (REG_VENDOR=existing), use 'unregister'
    # which only removes local credentials. For ABA-installed registries, use
    # 'uninstall' which also removes the registry container/data.
    local _regcreds="$HOME/.aba/mirror/mirror"
    for _dir in "$_aba_root"; do
        if [ -f "$_dir/mirror/.available" ]; then
            if [ -f "$_regcreds/state.sh" ] && grep -q 'REG_VENDOR=existing' "$_regcreds/state.sh"; then
                echo "  [cleanup] Found .available + existing registry -- running aba unregister"
                ( cd "$_dir" && aba -y -d mirror unregister ) && _did_uninstall=1 || {
                    echo "  [cleanup] WARNING: aba unregister failed in $_dir (rc=$?)"
                }
            else
                echo "  [cleanup] Found .available in $_dir/mirror -- running aba uninstall"
                ( cd "$_dir" && aba -y -d mirror uninstall ) && _did_uninstall=1 || {
                    echo "  [cleanup] WARNING: aba uninstall failed in $_dir (rc=$?)"
                }
            fi
        fi
    done

    # Tier 2: brute-force container cleanup -- only if no pool registry is present
    if [ -d "$POOL_REG_DIR" ]; then
        [ -z "$_did_uninstall" ] && echo "  [cleanup] Pool registry present -- skipping brute-force container cleanup"
    else
        local _stale_detected=""
        podman ps -a | grep -v -e pool-registry -e CONTAINER | grep -q . && _stale_detected=1

        if [ -n "$_stale_detected" ]; then
            echo "  [cleanup] Stale registry remnants detected -- brute-force cleanup"
            for _cid in $(podman ps -a -q --filter "name!=pool-registry"); do
                podman stop "$_cid" || true
                podman rm -f "$_cid" || true
            done
            podman volume rm -a -f || true
            echo "  [cleanup] Brute-force cleanup complete"
        elif [ -z "$_did_uninstall" ]; then
            echo "  [cleanup] No stale registry state detected -- nothing to clean"
        fi
    fi

    # Always clean cached registry credentials on conN.
    # Pool registry is unaffected (uses ~/.e2e-pool-registry/, not ~/.aba/mirror/).
    # This matches what _cleanup_dis_aba already does on disN (runner.sh).
    if [ -d "$HOME/.aba/mirror" ]; then
        echo "  [cleanup] Removing stale registry credentials (~/.aba/mirror/)"
        rm -rf "$HOME/.aba/mirror"
    fi
}

# --- build_and_test_cluster -------------------------------------------------
#
# Helper to create a cluster, install it, and run post-install checks.
# Used by multiple suites for the standard cluster install workflow.
#
# Usage: build_and_test_cluster CLUSTER_TYPE [OPTIONS...]
#   CLUSTER_TYPE: sno | compact | standard
#   OPTIONS: passed to "aba cluster"
#
build_and_test_cluster() {
    local cluster_type="$1"; shift
    local extra_args="$*"

    e2e_run "Create $cluster_type cluster config" \
        "aba cluster --type $cluster_type $extra_args"

    e2e_run -r 8 2 "Install $cluster_type cluster" \
        "aba --dir $cluster_type install"

    e2e_run "Run post-install checks ($cluster_type)" \
        "aba --dir $cluster_type run"

    e2e_run "Verify cluster operators ($cluster_type)" \
        "aba --dir $cluster_type cmd 'oc get co'"
}

# --- build_and_test_cluster_remote ------------------------------------------
#
# Same as build_and_test_cluster but runs on the INTERNAL_BASTION.
#
build_and_test_cluster_remote() {
    local cluster_type="$1"; shift
    local extra_args="$*"

    e2e_run_remote "Create $cluster_type cluster config" \
        "cd ~/aba && aba cluster --type $cluster_type $extra_args"

    e2e_run_remote -r 8 2 "Install $cluster_type cluster" \
        "cd ~/aba && aba --dir $cluster_type install"

    e2e_run_remote "Run post-install checks ($cluster_type)" \
        "cd ~/aba && aba --dir $cluster_type run"

    e2e_run_remote "Verify cluster operators ($cluster_type)" \
        "cd ~/aba && aba --dir $cluster_type cmd 'oc get co'"
}
