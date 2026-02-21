#!/bin/bash
# =============================================================================
# E2E Test Framework -- Shared Setup Functions
# =============================================================================
# Extracts the ~50-line setup boilerplate duplicated across all 5 original
# test scripts into reusable functions. Each suite calls these instead of
# copying the same preamble.
# =============================================================================

_E2E_LIB_DIR_SU="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source other libs if not already loaded
if ! type remote_exec &>/dev/null 2>&1; then
    source "$_E2E_LIB_DIR_SU/remote.sh"
fi
if ! type configure_internal_bastion &>/dev/null 2>&1; then
    source "$_E2E_LIB_DIR_SU/pool-lifecycle.sh"
fi

# --- setup_aba_from_scratch -------------------------------------------------
#
# Full clean-slate setup of aba for testing. This replaces the duplicated
# preamble that appeared at the top of every test[1-5]-*.sh:
#   - Remove RPMs (so aba tests auto-install)
#   - Reset aba state
#   - Clean podman images and caches
#
# NOTE: Does NOT generate aba.conf or vmware.conf -- use the aba CLI for that.
#
setup_aba_from_scratch() {
    local aba_root
    aba_root="$(cd "$_E2E_LIB_DIR_SU/../../.." && pwd)"
    cd "$aba_root" || { echo "Cannot cd to aba root: $aba_root" >&2; return 1; }

    echo "=== setup_aba_from_scratch ==="

    # Uninstall any existing registry. Aba checks .installed internally.
    # Rule 6: uninstall from the same host that installed.
    e2e_run "Uninstall registry (local or remote)" \
        "cd $aba_root && aba -d mirror uninstall"

    # Reset aba BEFORE removing RPMs -- 'aba reset' needs 'make' which is
    # removed in the RPM removal step below (Rule 7).
    e2e_run "Reset aba" \
        "cd $aba_root && if [ -d mirror ]; then aba reset -f; else echo 'No mirror dir -- nothing to reset'; fi"

    # Remove RPMs so aba can test auto-install (removes make, git, etc.)
    e2e_run "Remove RPMs for clean install test" \
        "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y --disableplugin=subscription-manager"

    # podman prune/rmi with --force are idempotent (return 0 even when empty).
    e2e_run "Clean podman images" \
        "podman system prune --all --force; podman rmi --all --force; sudo rm -rfv ~/.local/share/containers/storage"

    # Remove oc-mirror caches
    e2e_run "Remove oc-mirror caches" \
        "sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rfv"

    echo "=== setup_aba_from_scratch complete ==="
}

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
#     The uninstall already happened from conN in setup_aba_from_scratch.
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

    local _aba_root
    _aba_root="$(cd "$_E2E_LIB_DIR_SU/../../.." && pwd)"

    # NOTE: We do NOT rsync the aba tree to disN here.  Only aba itself
    # (via 'mirror sync', 'bundle', etc.) should manage files on disN.
    # Rsyncing from the E2E framework bypasses aba's workflow and can mask bugs.

    # 1. Uninstall the registry using aba's own uninstall, from conN.
    #    Rule 6: uninstall from the same host that installed.
    e2e_run "Uninstall registry from conN" \
        "cd ${_aba_root} && aba -d mirror uninstall"

    # 2. Verify the registry is actually down.
    e2e_run "Verify registry is down on $_dis_bare" \
        "! curl -sk --connect-timeout 5 https://${_dis_bare}:8443/health/instance"

    # 3. Clean slate on disN: remove aba tree, caches, container storage.
    e2e_run_remote "Remove aba tree on internal bastion" \
        "rm -rfv ~/aba"
    e2e_run_remote "Clean podman images on internal bastion" \
        "podman system prune --all --force; podman rmi --all --force"
    e2e_run_remote "Clean oc-mirror caches on internal bastion" \
        "rm -rfv ~/.cache/agent ~/.oc-mirror"
    e2e_run_remote "Clean containers storage on internal bastion" \
        "sudo rm -rfv ~/.local/share/containers/storage"

    echo "=== reset_internal_bastion complete ==="
}

# --- cleanup_all ------------------------------------------------------------
#
# Full cleanup: reset aba state, clean caches, remove cluster directories.
#
cleanup_all() {
    local aba_root
    aba_root="$(cd "$_E2E_LIB_DIR_SU/../../.." && pwd)"
    cd "$aba_root" || return 1

    echo "=== cleanup_all ==="

    # Reset aba.  Conditional: mirror dir may not exist on first run.
    e2e_run "Reset aba mirror state" \
        "if [ -d mirror ]; then aba reset -f; else echo 'No mirror dir -- nothing to reset'; fi"

    # Remove cluster directories (pool-specific names)
    local _sno _compact _standard
    _sno="$(pool_cluster_name sno)"
    _compact="$(pool_cluster_name compact)"
    _standard="$(pool_cluster_name standard)"
    e2e_run "Remove cluster directories" \
        "rm -rfv $_sno $_compact $_standard"

    # podman prune/rmi with --force are idempotent (return 0 even when empty).
    e2e_run "Clean podman images" \
        "podman system prune --all --force; podman rmi --all --force; sudo rm -rfv ~/.local/share/containers/storage"

    # Remove caches
    e2e_run "Remove oc-mirror caches" \
        "sudo find ~/ -type d -name .oc-mirror | xargs sudo rm -rfv"

    echo "=== cleanup_all complete ==="
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
