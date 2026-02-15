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

    # Uninstall any existing registry using aba's own uninstall command.
    # -i: first run may have no registry to uninstall (exit 0 from aba).
    e2e_run -i "Uninstall local registry (if any)" \
        "cd $aba_root && aba -d mirror uninstall"

    # Remove RPMs so aba can test auto-install
    e2e_run "Remove RPMs for clean install test" \
        "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y"

    # Clean podman images
    e2e_run "Clean podman images" \
        "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage"

    # Remove oc-mirror caches
    e2e_run "Remove oc-mirror caches" \
        "find ~/ -type d -name .oc-mirror 2>&1 | xargs rm -rf"

    # Reset aba.  -i: mirror dir may not exist on first run.
    e2e_run -i "Reset aba" \
        "cd $aba_root && make -C mirror reset yes=1"

    echo "=== setup_aba_from_scratch complete ==="
}

# --- setup_bastion ----------------------------------------------------------
#
# Initialize an internal (air-gapped) bastion VM by cloning from template.
# Clones the template, powers on, and applies configure_internal_bastion.
#
# Usage: setup_bastion CLONE_NAME [TEMPLATE] [TEST_USER]
#
# Example: setup_bastion dis1 bastion-internal-rhel9 steve
#
setup_bastion() {
    local clone_name="$1"
    local template="${2:-${VM_TEMPLATES[${INTERNAL_BASTION_RHEL_VER:-rhel9}]:-bastion-internal-rhel9}}"
    local test_user="${3:-${TEST_USER:-$VM_DEFAULT_USER}}"

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
    local template="${2:-${VM_TEMPLATES[${INTERNAL_BASTION_RHEL_VER:-rhel9}]:-bastion-internal-rhel9}}"

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
# Assumes clone-check has already created and configured the disN VM.
#
# Resets aba state, removes cluster dirs, cleans podman and oc-mirror caches.
# This is the lightweight alternative to setup_bastion for reusing VMs.
#
# Usage: reset_internal_bastion
#   (uses INTERNAL_BASTION from the calling suite)
#
reset_internal_bastion() {
    local _dis_host="${INTERNAL_BASTION:?INTERNAL_BASTION not set}"
    # Extract bare hostname for curl check (strip user@ prefix if present)
    local _dis_bare="${_dis_host#*@}"

    echo "=== reset_internal_bastion: $_dis_host ==="

    # Sync aba to the internal bastion so 'aba -d mirror uninstall' can run.
    # This is lightweight (excludes heavy data dirs).  Must happen BEFORE
    # uninstall because a previous test run may have wiped ~/aba on disN.
    local _aba_root
    _aba_root="$(cd "$_E2E_LIB_DIR_SU/../../.." && pwd)"
    e2e_run "Sync aba to $_dis_bare for cleanup" \
        "rsync -az --delete \
            --exclude='mirror/save/' \
            --exclude='mirror/.oc-mirror/' \
            --exclude='cli/' \
            --exclude='.git/' \
            '${_aba_root}/' '${_dis_host}:~/aba/'"

    # Uninstall any existing registry using aba's own uninstall command.
    # -i: first run may have no registry to uninstall (exit 0 from aba).
    e2e_run_remote -i "Uninstall registry on internal bastion" \
        "cd ~/aba && aba -d mirror uninstall"

    # VERIFY the registry is actually down -- hard failure if it's still up!
    e2e_run "Verify registry is down on $_dis_bare" \
        "! curl -sk --connect-timeout 5 https://${_dis_bare}:8443/health/instance"

    # Reset aba state.
    e2e_run_remote "Reset aba on internal bastion" \
        "cd ~/aba && aba reset -f"
    e2e_run_remote "Clean cluster dirs on internal bastion" \
        "cd ~/aba && rm -rf sno sno2 compact standard"
    e2e_run_remote "Clean podman on internal bastion" \
        "podman system prune --all --force; podman rmi --all; true"
    e2e_run_remote "Clean oc-mirror caches on internal bastion" \
        "rm -rf ~/.cache/agent ~/.oc-mirror"
    e2e_run_remote "Clean containers storage on internal bastion" \
        "sudo rm -rf ~/.local/share/containers/storage"

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

    # Reset aba.  -i: mirror dir may not exist on first run.
    e2e_run -i "Reset aba mirror state" \
        "make -C mirror reset yes=1"

    # Remove cluster directories
    e2e_run "Remove cluster directories" \
        "rm -rf sno sno2 compact standard"

    # Clean podman
    e2e_run "Clean podman images" \
        "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage"

    # Remove caches
    e2e_run "Remove oc-mirror caches" \
        "find ~/ -type d -name .oc-mirror 2>&1 | xargs rm -rf"

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
