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

# --- init_bastion_vm --------------------------------------------------------
#
# Revert a VMware VM to a named snapshot and power it on.
# Requires govc to be installed and configured (vmware.conf sourced).
#
# Usage: init_bastion_vm VM_NAME [SNAPSHOT_NAME]
#
init_bastion_vm() {
    local vm_name="$1"
    local snapshot="${2:-${VM_SNAPSHOT:-aba-test}}"

    echo "  Reverting VM '$vm_name' to snapshot '$snapshot' ..."
    govc snapshot.revert -vm "$vm_name" "$snapshot" || return 1

    sleep "${VM_BOOT_DELAY:-8}"

    echo "  Powering on VM '$vm_name' ..."
    govc vm.power -on "$vm_name" || return 1

    sleep 5
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
