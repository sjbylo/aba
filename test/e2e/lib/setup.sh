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
if ! type gen_aba_conf &>/dev/null 2>&1; then
    source "$_E2E_LIB_DIR_SU/config-helpers.sh"
fi
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
#   - Generate aba.conf with test parameters
#   - Copy vmware.conf
#   - Clean podman images and caches
#
# Options: same as gen_aba_conf (--channel, --version, --platform, --op-sets, --ops)
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
    e2e_run "Clean podman images" \
        "podman system prune --all --force 2>/dev/null; podman rmi --all 2>/dev/null; sudo rm -rf ~/.local/share/containers/storage; true"

    # Remove oc-mirror caches
    e2e_run "Remove oc-mirror caches" \
        "rm -rf \$(find ~/ -type d -name .oc-mirror 2>/dev/null); true"

    # Reset aba
    e2e_run -i "Reset aba" \
        "cd $aba_root && make -C mirror reset yes=1 2>/dev/null; true"

    # Generate aba.conf with test parameters
    gen_aba_conf "$@"

    # Copy vmware.conf
    gen_vmware_conf

    echo "=== setup_aba_from_scratch complete ==="
}

# --- setup_bastion ----------------------------------------------------------
#
# Initialize an internal (air-gapped) bastion VM. This wraps the full
# pool-lifecycle configure_internal_bastion flow:
#   1. Power off all bastion VMs
#   2. Revert to snapshot
#   3. Power on
#   4. Apply internal bastion configuration profile
#
# Usage: setup_bastion HOSTNAME [VM_NAME] [SNAPSHOT] [TEST_USER]
#
# Example: setup_bastion disco1 bastion-internal-rhel9 aba-test steve
#
setup_bastion() {
    local hostname="$1"
    local vm_name="${2:-${VM_TEMPLATES[${INTERNAL_BASTION_RHEL_VER:-rhel9}]:-bastion-internal-rhel9}}"
    local snapshot="${3:-${VM_SNAPSHOT:-aba-test}}"
    local test_user="${4:-${TEST_USER:-$VM_DEFAULT_USER}}"

    echo "=== setup_bastion: $hostname (VM: $vm_name, snap: $snapshot) ==="

    # Install govc if needed
    e2e_run "Install govc" "aba --dir cli ~/bin/govc"

    # Power off all internal bastion VMs to avoid conflicts
    for vm in $ALL_INTERNAL_VMS; do
        power_off_vm "$vm"
    done

    # Revert to snapshot and power on
    init_bastion_vm "$vm_name" "$snapshot"

    # Apply the internal bastion configuration profile
    configure_internal_bastion "$hostname" "$VM_DEFAULT_USER" "$test_user"

    echo "=== setup_bastion complete: $hostname ==="
}

# --- setup_connected_bastion ------------------------------------------------
#
# Initialize a connected (internet-facing) bastion VM.
#
# Usage: setup_connected_bastion HOSTNAME [VM_NAME] [SNAPSHOT]
#
setup_connected_bastion() {
    local hostname="$1"
    local vm_name="${2:-$hostname}"
    local snapshot="${3:-${VM_SNAPSHOT:-aba-test}}"

    echo "=== setup_connected_bastion: $hostname ==="

    # Revert to snapshot and power on
    init_bastion_vm "$vm_name" "$snapshot"

    # Apply connected bastion configuration profile
    configure_connected_bastion "$hostname"

    echo "=== setup_connected_bastion complete: $hostname ==="
}

# --- setup_mirror_conf ------------------------------------------------------
#
# Create and customize mirror/mirror.conf after aba has created the mirror dir.
#
# Options: same as gen_mirror_conf (--reg-type, --reg-host, --reg-port)
#
setup_mirror_conf() {
    gen_mirror_conf "$@"
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
