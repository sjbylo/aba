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

    # Remove RPMs so aba can test auto-install
    e2e_run "Remove RPMs for clean install test" \
        "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y 2>/dev/null || true"

    # Clean podman images
    e2e_run -q "Clean podman images" \
        "podman system prune --all --force 2>/dev/null; podman rmi --all 2>/dev/null; sudo rm -rf ~/.local/share/containers/storage; true"

    # Remove oc-mirror caches
    e2e_run -q "Remove oc-mirror caches" \
        "rm -rf \$(find ~/ -type d -name .oc-mirror 2>/dev/null); true"

    # Reset aba
    e2e_run -i "Reset aba" \
        "cd $aba_root && make -C mirror reset yes=1 2>/dev/null; true"

    echo "=== setup_aba_from_scratch complete ==="
}

# --- setup_bastion ----------------------------------------------------------
#
# Initialize an internal (air-gapped) bastion VM by cloning from template.
# Clones the template, powers on, and applies configure_internal_bastion.
#
# Usage: setup_bastion CLONE_NAME [TEMPLATE] [TEST_USER]
#
# Example: setup_bastion disco1 bastion-internal-rhel9 steve
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

# --- cleanup_all ------------------------------------------------------------
#
# Full cleanup: reset aba state, clean caches, remove cluster directories.
#
cleanup_all() {
    local aba_root
    aba_root="$(cd "$_E2E_LIB_DIR_SU/../../.." && pwd)"
    cd "$aba_root" || return 1

    echo "=== cleanup_all ==="

    # Reset aba
    make -C mirror reset yes=1 2>/dev/null || true

    # Remove cluster directories
    rm -rf sno sno2 compact standard 2>/dev/null || true

    # Clean podman
    podman system prune --all --force 2>/dev/null || true
    podman rmi --all 2>/dev/null || true
    sudo rm -rf ~/.local/share/containers/storage 2>/dev/null || true

    # Remove caches
    rm -rf $(find ~/ -type d -name .oc-mirror 2>/dev/null) 2>/dev/null || true

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
