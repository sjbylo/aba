#!/bin/bash
# =============================================================================
# E2E Test Framework -- Remote / SSH Helpers
# =============================================================================
# Provides SSH wrappers, remote file transfer, and VM boot helpers via govc.
# =============================================================================

_E2E_LIB_DIR_RM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- remote_exec ------------------------------------------------------------
#
# Execute a command on a remote host via SSH.
# Sources ~/.bash_profile on the remote side (needed for RHEL8 PATH).
# Uses -t for pseudo-tty and -o LogLevel=ERROR to suppress noise.
#
# Usage: remote_exec HOST "command..."
#
remote_exec() {
    local host="$1"; shift
    local cmd="$*"

    ssh -t -o LogLevel=ERROR -o ConnectTimeout=30 "$host" -- \
        ". \$HOME/.bash_profile 2>/dev/null; $cmd"
}

# --- remote_exec_as ---------------------------------------------------------
#
# Execute a command on a remote host as a specific user.
#
# Usage: remote_exec_as USER HOST "command..."
#
remote_exec_as() {
    local user="$1"
    local host="$2"
    shift 2
    local cmd="$*"

    if [ "$user" = "root" ]; then
        ssh -t -o LogLevel=ERROR -o ConnectTimeout=30 "root@$host" -- \
            ". \$HOME/.bash_profile 2>/dev/null; $cmd"
    else
        local key_flag=""
        [ -f "$HOME/.ssh/${user}_rsa" ] && key_flag="-i $HOME/.ssh/${user}_rsa"
        ssh -t -o LogLevel=ERROR -o ConnectTimeout=30 $key_flag "$user@$host" -- \
            ". \$HOME/.bash_profile 2>/dev/null; $cmd"
    fi
}

# --- remote_pipe_stdin ------------------------------------------------------
#
# Pipe stdin to a remote command via SSH.
#
# Usage: cat file | remote_pipe_stdin HOST "tar xf - -C /tmp"
#
remote_pipe_stdin() {
    local host="$1"; shift
    local cmd="$*"

    ssh -o LogLevel=ERROR -o ConnectTimeout=30 "$host" -- "$cmd"
}

# --- remote_wait_ssh --------------------------------------------------------
#
# Wait for SSH to become available on a host.
#
# Usage: remote_wait_ssh HOST [TIMEOUT_SECONDS]
#
remote_wait_ssh() {
    local host="$1"
    local timeout="${2:-${SSH_WAIT_TIMEOUT:-300}}"
    local start=$(date +%s)
    local elapsed=0

    echo "  Waiting for SSH on $host (timeout: ${timeout}s) ..."

    while true; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
               "$host" -- "echo 'ssh-ready'" 2>/dev/null; then
            echo "  SSH ready on $host (${elapsed}s)"
            return 0
        fi

        elapsed=$(( $(date +%s) - start ))
        if [ $elapsed -ge $timeout ]; then
            echo "  ERROR: SSH timeout after ${timeout}s for $host" >&2
            return 1
        fi

        sleep 3
    done
}

# --- _get_nic_network -------------------------------------------------------
#
# Get the VMware port group name for a NIC on a VM. Works with both
# standard vSwitches and Distributed Virtual Switches.
#
# For dvSwitches: extracts the portgroupKey from the device JSON, then
# resolves it to a name via govc object.collect.
# For standard vSwitches: reads the Summary field from govc device.info.
#
# Usage: _get_nic_network VM_NAME DEVICE_NAME
# Returns: port group name on stdout, or empty string on failure
#
_get_nic_network() {
    local vm="$1"
    local device="$2"

    # Get the portgroupKey from the device's backing info (dvSwitch)
    local pg_key
    pg_key=$(govc device.info -vm "$vm" -json "$device" 2>/dev/null \
        | jq -r '.devices[0].backing.port.portgroupKey // empty' 2>/dev/null)

    if [ -n "$pg_key" ]; then
        # Distributed switch -- resolve portgroupKey to name
        govc object.collect -s "$pg_key" name 2>/dev/null
    else
        # Standard switch -- Summary field has the network name directly
        govc device.info -vm "$vm" "$device" 2>/dev/null \
            | awk '/Summary:/{$1=""; print substr($0,2)}'
    fi
}

# --- clone_vm ---------------------------------------------------------------
#
# Clone a VM from a source VM. If a clone with the same name already
# exists, it is destroyed first (always-fresh strategy).
#
# If the source has snapshots, clones from the named snapshot (default:
# "aba-test") for linked clones. If no snapshots exist (e.g. VMware
# template objects), performs a full clone instead.
#
# After cloning (while still powered off), MAC addresses are set on the
# clone's NICs so DHCP assigns the correct IP addresses. The port group
# name for each NIC is auto-detected from the clone (works with both
# standard and distributed virtual switches).
#
# MAC addresses must be defined in the VM_CLONE_MACS associative array
# (see pool-lifecycle.sh / config.env) in the format:
#   VM_CLONE_MACS[CLONE_NAME]="MAC0 MAC1 [MAC2]"
# where each MAC corresponds to ethernet-0, ethernet-1, ethernet-2, etc.
#
#   ethernet-0 = ens192 (primary, DHCP for IP)
#   ethernet-1 = ens224 (internal/VLAN)
#   ethernet-2 = ens256 (optional, e.g. connected bastions with 3 NICs)
#
# Usage: clone_vm SOURCE_VM CLONE_NAME [FOLDER] [SNAPSHOT]
#
# Example: clone_vm aba-e2e-template-rhel8 dis1
#
clone_vm() {
    local source_vm="$1"
    local clone_name="$2"
    local folder="${3:-${VC_FOLDER:-/Datacenter/vm/abatesting}}"
    local snapshot="${4:-${VM_SNAPSHOT:-aba-test}}"

    echo "  Cloning VM: $source_vm -> $clone_name (folder: $folder, snapshot: $snapshot) ..."

    # Destroy existing clone if present (clones are disposable)
    if vm_exists "$clone_name"; then
        echo "  Destroying previous clone '$clone_name' ..."
        govc vm.power -off "$clone_name" 2>/dev/null || true
        govc vm.destroy "$clone_name" || true
    fi

    local ds_flag=""
    [ -n "${VM_DATASTORE:-}" ] && ds_flag="-ds=$VM_DATASTORE"

    # Use -snapshot for linked clones when the source has snapshots.
    # VMware templates and VMs without snapshots require a full clone.
    local snap_flag=""
    if govc snapshot.tree -vm "$source_vm" 2>/dev/null | grep -q .; then
        snap_flag="-snapshot=$snapshot"
    fi

    govc vm.clone -vm "$source_vm" $snap_flag \
        -folder "$folder" $ds_flag -on=false "$clone_name" || return 1

    # --- Set MAC addresses on the clone's NICs (before power-on) -----------
    # The clone can inherit the source's MACs, causing IP conflict. So we
    # always set each NIC: either a specific MAC from VM_CLONE_MACS[clone_name],
    # or -net.address - for govc to assign a generated MAC (avoids conflict).
    local mac_entry="${VM_CLONE_MACS[$clone_name]:-}"
    local -a macs=()
    if [ -n "$mac_entry" ]; then
        macs=($mac_entry)
    fi

    local i=0
    while true; do
        local device="ethernet-${i}"
        # Only touch devices that exist (govc device.info fails for non-existent NICs)
        if ! govc device.info -vm "$clone_name" "$device" &>/dev/null; then
            break
        fi
        local nic_net
        nic_net=$(_get_nic_network "$clone_name" "$device")
        if [ -z "$nic_net" ]; then
            [ $i -eq 0 ] && echo "  WARNING: Could not detect network for $device, using GOVC_NETWORK"
            nic_net="${GOVC_NETWORK:-VM Network}"
        fi

        if [ $i -lt ${#macs[@]} ] && [ -n "${macs[$i]}" ]; then
            echo "  Setting $device MAC -> ${macs[$i]} (network: $nic_net)"
            govc vm.network.change -vm "$clone_name" -net "$nic_net" \
                -net.address "${macs[$i]}" "$device" || return 1
        else
            echo "  Setting $device MAC -> auto (network: $nic_net)"
            govc vm.network.change -vm "$clone_name" -net "$nic_net" \
                -net.address - "$device" || return 1
        fi
        i=$(( i + 1 ))
    done

    if [ $i -eq 0 ]; then
        echo "  WARNING: No NICs found on clone '$clone_name', skipping MAC setup."
    fi

    echo "  Powering on clone '$clone_name' ..."
    # Tolerate exit 1: VM may already be powered on (e.g. retry or race)
    govc vm.power -on "$clone_name" 2>/dev/null || true

    sleep "${VM_BOOT_DELAY:-8}"

    echo "  Clone '$clone_name' is booting."
}

# --- destroy_vm -------------------------------------------------------------
#
# Power off and destroy a cloned VM. Safe to call on non-existent VMs.
# NOTE: Only use this on clones, never on template VMs!
#
# Usage: destroy_vm VM_NAME
#
destroy_vm() {
    local vm_name="$1"

    if vm_exists "$vm_name"; then
        echo "  Destroying VM '$vm_name' ..."
        govc vm.power -off "$vm_name" 2>/dev/null || true
        govc vm.destroy "$vm_name" || true
    else
        echo "  VM '$vm_name' does not exist, nothing to destroy."
    fi
}

# --- power_off_vm -----------------------------------------------------------
#
# Power off a VMware VM (ignoring errors if already off).
#
power_off_vm() {
    local vm_name="$1"
    govc vm.power -off "$vm_name" 2>/dev/null || true
}

# --- power_on_vm ------------------------------------------------------------
#
# Power on a VMware VM.
#
power_on_vm() {
    local vm_name="$1"
    # Tolerate exit 1: VM may already be powered on
    govc vm.power -on "$vm_name" 2>/dev/null || true
}

# --- vm_exists --------------------------------------------------------------
#
# Check if a VMware VM exists.
#
vm_exists() {
    local vm_name="$1"
    # govc vm.info exits 0 even for non-existent VMs (empty output),
    # so check that output contains at least a "Name:" field.
    govc vm.info "$vm_name" 2>/dev/null | grep -q "Name:"
}

# --- setup_ssh_to_root ------------------------------------------------------
#
# Copy the current user's SSH config and keys to /root/.ssh so that
# root can also SSH to test hosts (needed when DIS_SSH_USER=root).
#
setup_ssh_to_root() {
    local def_user="${1:-steve}"
    local user_ssh_dir
    user_ssh_dir="$(eval echo "~${def_user}")/.ssh"

    mkdir -p /root/.ssh
    if [ -f "${user_ssh_dir}/config" ]; then
        cp "${user_ssh_dir}/config" /root/.ssh/
    fi
    # Copy id_rsa keypair if present
    for f in "${user_ssh_dir}"/id_rsa*; do
        [ -f "$f" ] && cp "$f" /root/.ssh/
    done
}
