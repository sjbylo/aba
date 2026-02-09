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

# --- remote_copy ------------------------------------------------------------
#
# Copy files to/from a remote host.
#
# Usage: remote_copy [--to|--from] HOST LOCAL_PATH REMOTE_PATH
#   or:  remote_copy HOST SRC DST  (uses rsync)
#
remote_copy() {
    local direction="to"

    if [ "$1" = "--to" ] || [ "$1" = "--from" ]; then
        direction="${1#--}"
        shift
    fi

    local host="$1"
    local path1="$2"
    local path2="$3"

    if [ "$direction" = "to" ]; then
        rsync -az --no-perms "$path1" "$host:$path2"
    else
        rsync -az --no-perms "$host:$path1" "$path2"
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
# Before cloning, the source VM is reverted to its snapshot (default:
# "aba-test") to ensure the clone is always from a known-clean state.
# The source VMs (e.g. bastion-internal-rhel9) are regular VMs with a
# clean snapshot -- not VMware "template" objects.
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
# Example: clone_vm bastion-internal-rhel9 disco1
#
clone_vm() {
    local source_vm="$1"
    local clone_name="$2"
    local folder="${3:-${VC_FOLDER:-/Datacenter/vm/abatesting}}"
    local snapshot="${4:-${VM_SNAPSHOT:-aba-test}}"

    echo "  Cloning VM: $source_vm -> $clone_name (folder: $folder) ..."

    # Destroy existing clone if present (clones are disposable)
    if vm_exists "$clone_name"; then
        echo "  Destroying previous clone '$clone_name' ..."
        govc vm.power -off "$clone_name" 2>/dev/null || true
        govc vm.destroy "$clone_name" || true
    fi

    # Revert source VM to clean snapshot before cloning
    echo "  Reverting '$source_vm' to snapshot '$snapshot' ..."
    govc vm.power -off "$source_vm" 2>/dev/null || true
    govc snapshot.revert -vm "$source_vm" "$snapshot" || return 1

    # Clone from source (powered off initially)
    govc vm.clone -vm "$source_vm" -folder "$folder" -on=false "$clone_name" || return 1

    # --- Set MAC addresses on the clone's NICs (before power-on) -----------
    # The clone inherits the source's MACs which won't match DHCP
    # reservations. Look up the correct MACs from VM_CLONE_MACS[clone_name].
    # The port group for each NIC is auto-detected from the clone.
    local mac_entry="${VM_CLONE_MACS[$clone_name]:-}"
    if [ -n "$mac_entry" ]; then
        local -a macs=($mac_entry)
        local i
        for (( i=0; i<${#macs[@]}; i++ )); do
            local device="ethernet-${i}"
            local mac="${macs[$i]}"

            # Auto-detect the NIC's port group (works with dvSwitch)
            local nic_net
            nic_net=$(_get_nic_network "$clone_name" "$device")
            if [ -z "$nic_net" ]; then
                echo "  WARNING: Could not detect network for $device, using GOVC_NETWORK"
                nic_net="${GOVC_NETWORK:-VM Network}"
            fi

            echo "  Setting $device MAC -> $mac (network: $nic_net)"
            govc vm.network.change -vm "$clone_name" -net "$nic_net" \
                -net.address "$mac" "$device" || return 1
        done
    else
        echo "  WARNING: No MAC addresses defined for '$clone_name' in VM_CLONE_MACS."
        echo "           DHCP may not assign the expected IP. Define them in config.env."
    fi

    # Power on the clone
    echo "  Powering on clone '$clone_name' ..."
    govc vm.power -on "$clone_name" || return 1

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
    govc vm.power -on "$vm_name" || return 1
}

# --- vm_exists --------------------------------------------------------------
#
# Check if a VMware VM exists.
#
vm_exists() {
    local vm_name="$1"
    govc vm.info "$vm_name" &>/dev/null
}

# --- setup_ssh_to_root ------------------------------------------------------
#
# Copy the current user's SSH config and keys to /root/.ssh so that
# root can also SSH to test hosts (needed when TEST_USER=root).
#
setup_ssh_to_root() {
    local def_user="${1:-steve}"
    mkdir -p /root/.ssh
    eval cp ~${def_user}/.ssh/config /root/.ssh/ 2>/dev/null || true
    eval cp ~${def_user}/.ssh/id_rsa* /root/.ssh/ 2>/dev/null || true
}
