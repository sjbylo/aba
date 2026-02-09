#!/bin/bash
# =============================================================================
# E2E Test Framework -- VM Pool Lifecycle
# =============================================================================
# Decomposes the monolithic init_bastion() from test/include.sh into
# composable _vm_* functions. Provides create_pools/destroy_pools for
# dynamic VM pool management via govc.
#
# A single VM template per RHEL version is used for both connected and
# internal bastions. Templates are minimal RHEL installs that are never
# modified. Each run clones fresh VMs from templates, configures them
# with a profile (configure_connected_bastion or configure_internal_bastion),
# and destroys the clones when done.
#
# Clone naming: reg1/reg2/... (connected), disco1/disco2/... (internal)
# =============================================================================

_E2E_LIB_DIR_PL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source remote helpers if not already loaded
if ! type remote_wait_ssh &>/dev/null 2>&1; then
    source "$_E2E_LIB_DIR_PL/remote.sh"
fi

# --- VM Template Configuration ----------------------------------------------

# VM templates by RHEL version (minimal RHEL installs, never modified)
declare -A VM_TEMPLATES=(
    [rhel8]="bastion-internal-rhel8"
    [rhel9]="bastion-internal-rhel9"
    [rhel10]="bastion-internal-rhel10"
)

# --- Clone MAC Addresses ----------------------------------------------------
# Each clone needs specific MAC addresses so DHCP assigns the correct IPs.
# Format: VM_CLONE_MACS[clone_name]="ens192-MAC ens224-MAC [ens256-MAC]"
#   Position 1 = ethernet-0 / ens192 (primary NIC, gets IP via DHCP)
#   Position 2 = ethernet-1 / ens224 (internal/VLAN NIC)
#   Position 3 = ethernet-2 / ens256 (optional, connected bastions with 3 NICs)
#
# The VMware network (port group) for each NIC is auto-detected from the
# clone, so only MAC addresses are needed here.
#
# Declare only if not already set (config.env is sourced first and takes
# precedence).
if ! declare -p VM_CLONE_MACS &>/dev/null 2>&1; then
    declare -A VM_CLONE_MACS=()
fi

# Default user pre-configured on VM templates
VM_DEFAULT_USER="${VM_DEFAULT_USER:-steve}"

# =============================================================================
# Composable _vm_* helper functions
# =============================================================================
# Each function takes a $host (SSH target) as its first argument.
# They are designed to be composed in configure_*_bastion() functions.
# =============================================================================

# --- _vm_wait_ssh -----------------------------------------------------------
# Wait for a VM to become reachable via SSH after power-on.
#
_vm_wait_ssh() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local timeout="${3:-${SSH_WAIT_TIMEOUT:-300}}"
    local start=$(date +%s)

    echo "  [vm] Waiting for SSH on ${user}@${host} (timeout: ${timeout}s) ..."
    while true; do
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
               "${user}@${host}" -- "date" 2>/dev/null; then
            echo "  [vm] SSH ready on ${user}@${host}"
            return 0
        fi

        local elapsed=$(( $(date +%s) - start ))
        if [ $elapsed -ge $timeout ]; then
            echo "  [vm] ERROR: SSH timeout after ${timeout}s for ${user}@${host}" >&2
            return 1
        fi
        sleep 3
    done
}

# --- _vm_setup_ssh_keys -----------------------------------------------------
# Copy coordinator's SSH keys to the VM. Set up root access.
#
_vm_setup_ssh_keys() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local pub_key
    pub_key=$(cat ~/.ssh/id_rsa.pub)

    echo "  [vm] Setting up SSH keys on $host ..."

    # Copy SSH config to root on the remote host
    if [ "$user" != "root" ]; then
        scp -o StrictHostKeyChecking=no ~/.ssh/config "root@${host}:.ssh/config" 2>/dev/null || true
    fi

    # Add public key to root's authorized_keys
    cat <<-SSHEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		mkdir -p /root/.ssh
		echo "$pub_key" > /root/.ssh/authorized_keys
		chmod 600 /root/.ssh/authorized_keys
	SSHEOF
}

# --- _vm_setup_time ---------------------------------------------------------
# Configure chrony (NTP), timezone, and time sync.
#
_vm_setup_time() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local ntp_server="${NTP_SERVER:-10.0.1.8}"
    local timezone="${TIMEZONE:-Asia/Singapore}"

    echo "  [vm] Configuring time/NTP on $host ..."

    cat <<-TIMEEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		dnf install chrony -y 2>/dev/null || true
		systemctl start chronyd
		sleep 1
		chronyc sources -v
		chronyc add server $ntp_server iburst || true
		timedatectl set-timezone $timezone
		chronyc -a makestep
		sleep 3
		chronyc sources -v
		timedatectl
	TIMEEOF
}

# --- _vm_dnf_update ---------------------------------------------------------
# Run dnf update and reboot. Caller should call _vm_wait_ssh again afterwards.
#
_vm_dnf_update() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Running dnf update + reboot on $host ..."

    cat <<-DNFEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		dnf update -y
		reboot
	DNFEOF

    # Give time for reboot to start
    sleep 20
}

# --- _vm_setup_network ------------------------------------------------------
# Configure network: VLAN interface, MTU 9000, nmcli adjustments.
# This is specifically for internal bastions that need the private VLAN network.
#
_vm_setup_network() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Configuring network (VLAN, MTU) on $host ..."

    cat <<-NETEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		# Tidy up network interface names
		nmcli connection show
		nmcli connection modify "Wired connection 1" connection.id ens224 2>/dev/null || true
		nmcli connection modify ens192 ipv4.never-default yes 2>/dev/null || true
		nmcli connection modify ens224 ipv4.never-default yes 2>/dev/null || true
		nmcli connection modify ens192 ipv6.method disabled 2>/dev/null || true
		nmcli connection modify ens224 ipv6.method disabled 2>/dev/null || true

		# Set MTU 9000 for faster data transfer
		ip link set ens192 mtu 9000 2>/dev/null || true
		ip link set ens224 mtu 9000 2>/dev/null || true

		# Create VLAN interface for private /24 network (used to test VLAN config)
		nmcli connection modify ens224 ipv4.method disabled ipv6.method disabled
		nmcli connection up ens224
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses 10.10.10.1/24 ipv4.never-default yes

		ip a
		ip route
	NETEOF
}

# --- _vm_setup_firewall -----------------------------------------------------
# Set up firewalld with NAT masquerade for the internal network.
#
_vm_setup_firewall() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Configuring firewall + NAT on $host ..."

    cat <<-FWEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		# Remove legacy iptables-services
		systemctl disable --now iptables 2>/dev/null || true
		dnf remove -y iptables-services 2>/dev/null || true

		# Enable firewalld
		systemctl enable --now firewalld

		# Enable IP forwarding
		cat > /etc/sysctl.d/99-ipforward.conf <<-SYSEOF
		net.ipv4.ip_forward = 1
		SYSEOF
		sysctl -p /etc/sysctl.d/99-ipforward.conf

		# NAT masquerade for the internal 10.10.10.0/24 network
		firewall-cmd --permanent --zone=public \
		    --add-rich-rule='rule family="ipv4" source address="10.10.10.0/24" masquerade'
		firewall-cmd --reload

		echo "=== FIREWALL CONFIG ==="
		firewall-cmd --list-all --zone=public
	FWEOF
}

# --- _vm_cleanup_caches -----------------------------------------------------
# Remove cached files: .cache/agent, ~/bin/*, .oc-mirror/.cache, etc.
#
_vm_cleanup_caches() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Cleaning caches on $host ..."

    cat <<-CACHEEOF | ssh "${user}@${host}" -- bash
		set -ex
		rm -vrf ~/.cache/agent/
		rm -vrf ~/bin/*
		rm -f \$HOME/.ssh/quay_installer*
		rm -rf \$HOME/.oc-mirror/.cache
		rm -rf \$HOME/*/.oc-mirror/.cache
		# Ensure test VMs are located together
		[ -s ~/.vmware.conf ] && sed -i "s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g" ~/.vmware.conf || true
	CACHEEOF
}

# --- _vm_cleanup_podman -----------------------------------------------------
# Remove all podman images and container storage.
#
_vm_cleanup_podman() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Cleaning podman on $host ..."

    ssh "${user}@${host}" -- bash -c "
        which podman 2>/dev/null || sudo dnf install podman -y
        podman system prune --all --force
        podman rmi --all 2>/dev/null || true
        sudo rm -rf ~/.local/share/containers/storage
        rm -rf ~/test
    "
}

# --- _vm_cleanup_home -------------------------------------------------------
# Wipe the home directory to ensure clean state.
#
_vm_cleanup_home() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Cleaning home directory on $host ..."
    ssh "${user}@${host}" -- "rm -rfv ~/*"
}

# --- _vm_setup_vmware_conf -------------------------------------------------
# Copy vmware.conf to the VM so govc works there.
#
_vm_setup_vmware_conf() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local vf="${VMWARE_CONF:-$HOME/.vmware.conf}"

    echo "  [vm] Copying vmware.conf to $host ..."
    if [ -f "$vf" ]; then
        scp "$vf" "${user}@${host}:" 2>/dev/null || true
    fi
}

# --- _vm_remove_rpms --------------------------------------------------------
# Remove RPMs that aba should install automatically (testing auto-install).
#
_vm_remove_rpms() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Removing RPMs (git, make, jq, etc.) on $host ..."
    ssh "${user}@${host}" -- \
        "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y 2>/dev/null || true"
}

# --- _vm_remove_pull_secret -------------------------------------------------
# Remove .pull-secret.json (not needed in fully air-gapped environment).
#
_vm_remove_pull_secret() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Removing pull-secret on $host ..."
    ssh "${user}@${host}" -- "rm -fv ~/.pull-secret.json"
}

# --- _vm_remove_proxy -------------------------------------------------------
# Disable proxy configuration in .bashrc (for fully disconnected testing).
#
_vm_remove_proxy() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Disabling proxy on $host ..."
    ssh "${user}@${host}" -- \
        "sed -i 's|^source ~/.proxy-set.sh|# aba-test # source ~/.proxy-set.sh|g' ~/.bashrc 2>/dev/null || true"
}

# --- _vm_create_test_user ---------------------------------------------------
# Create the "testy" user with SSH key access and sudo privileges.
#
_vm_create_test_user() {
    local host="$1"
    local def_user="${2:-$VM_DEFAULT_USER}"
    local test_user_name="testy"
    local key_file="$HOME/.ssh/testy_rsa"

    echo "  [vm] Creating test user '$test_user_name' on $host ..."

    # Generate SSH key for testy if not exists
    if [ ! -f "$key_file" ]; then
        rm -f "${key_file}" "${key_file}.pub"
        ssh-keygen -t rsa -f "$key_file" -N ''
    fi

    local pub_key
    pub_key=$(cat "${key_file}.pub")

    cat <<-USEREOF | ssh "${def_user}@${host}" -- sudo bash
		set -ex
		userdel $test_user_name -r -f 2>/dev/null || true
		useradd $test_user_name -p not-used
		mkdir -p ~${test_user_name}/.ssh
		chmod 700 ~${test_user_name}/.ssh
		echo "$pub_key" > ~${test_user_name}/.ssh/authorized_keys
		chmod 600 ~${test_user_name}/.ssh/authorized_keys
		chown -R ${test_user_name}.${test_user_name} ~${test_user_name}
		echo '${test_user_name} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${test_user_name}
	USEREOF

    # Verify SSH access
    echo "  [vm] Verifying SSH to $test_user_name@$host ..."
    ssh -i "$key_file" "${test_user_name}@${host}" -- whoami | grep -q "$test_user_name"
}

# --- _vm_install_aba --------------------------------------------------------
# Rsync the aba tree to the VM and run ./install.
#
_vm_install_aba() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local aba_root="${3:-$(cd "$_E2E_LIB_DIR_PL/../../.." && pwd)}"

    echo "  [vm] Installing aba on ${user}@${host} ..."

    rsync -az --no-perms --exclude='.git' --exclude='cli/*.tar.gz' \
        "$aba_root/" "${user}@${host}:~/aba/"

    ssh "${user}@${host}" -- "cd ~/aba && ./install"
}

# =============================================================================
# Composition functions: configure_connected_bastion / configure_internal_bastion
# =============================================================================

# --- configure_connected_bastion --------------------------------------------
# Configure a VM as an internet-connected registry host (bastion).
# Lighter setup: SSH keys, time, caches, vmware.conf, install aba.
#
configure_connected_bastion() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "=== Configuring connected bastion: $host ==="

    _vm_wait_ssh "$host" "$user"
    _vm_setup_ssh_keys "$host" "$user"
    _vm_setup_time "$host" "$user"
    _vm_cleanup_caches "$host" "$user"
    _vm_cleanup_home "$host" "$user"
    _vm_setup_vmware_conf "$host" "$user"
    _vm_create_test_user "$host" "$user"
    _vm_install_aba "$host" "$user"

    echo "=== Connected bastion ready: $host ==="
}

# --- configure_internal_bastion ---------------------------------------------
# Configure a VM as an air-gapped internal bastion. Full setup including
# network hardening, firewall/NAT, RPM removal, proxy removal, etc.
# This is the modular equivalent of the old init_bastion() in test/include.sh.
#
configure_internal_bastion() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local test_user="${3:-${TEST_USER:-$VM_DEFAULT_USER}}"

    echo "=== Configuring internal bastion: $host ==="

    _vm_wait_ssh "$host" "$user"
    _vm_setup_ssh_keys "$host" "$user"
    _vm_setup_time "$host" "$user"

    # Update and reboot
    _vm_dnf_update "$host" "$user"
    _vm_wait_ssh "$host" "$user"

    # Network hardening
    _vm_setup_network "$host" "$user"
    _vm_setup_firewall "$host" "$user"

    # Clean up
    _vm_cleanup_caches "$host" "$user"
    _vm_cleanup_podman "$host" "$user"
    _vm_cleanup_home "$host" "$user"

    # Install govc config
    _vm_setup_vmware_conf "$host" "$user"

    # Remove RPMs so aba can test auto-install
    _vm_remove_rpms "$host" "$user"

    # Air-gap: remove pull-secret and proxy
    _vm_remove_pull_secret "$host" "$user"
    _vm_remove_proxy "$host" "$user"

    # Create test user
    _vm_create_test_user "$host" "$user"

    echo "=== Internal bastion ready: $host ==="
}

# =============================================================================
# Pool-level functions
# =============================================================================

# --- create_pools -----------------------------------------------------------
# Create N VM pools by cloning from template VMs and configuring them.
#
# Usage: create_pools N [--rhel rhel8|rhel9|rhel10] [--connected-only]
#
# Each pool gets:
#   - A connected bastion clone (regN) from the template
#   - Optionally a paired internal bastion clone (discoN) from the template
#
# Templates are never modified. Previous clones are destroyed and re-cloned
# fresh every time.
#
create_pools() {
    local count="$1"; shift
    local rhel_ver="${INTERNAL_BASTION_RHEL_VER:-rhel9}"
    local connected_only=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --rhel) rhel_ver="$2"; shift 2 ;;
            --connected-only) connected_only=1; shift ;;
            *) echo "create_pools: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    local vm_template="${VM_TEMPLATES[$rhel_ver]:-bastion-internal-$rhel_ver}"

    echo "=== Creating $count pool(s) by cloning template $vm_template ==="

    local i
    for (( i=1; i<=count; i++ )); do
        echo ""
        echo "--- Pool $i ---"

        # Clone connected bastion: template -> regN
        local conn_vm="reg${i}"
        echo "  Cloning connected bastion: $vm_template -> $conn_vm"
        clone_vm "$vm_template" "$conn_vm"
        configure_connected_bastion "$conn_vm"

        # Clone internal bastion: template -> discoN (if not --connected-only)
        if [ -z "$connected_only" ]; then
            local int_vm="disco${i}"
            echo "  Cloning internal bastion: $vm_template -> $int_vm"
            clone_vm "$vm_template" "$int_vm"
            configure_internal_bastion "$int_vm"
        fi
    done

    echo ""
    echo "=== $count pool(s) created ==="
}

# --- destroy_pools ----------------------------------------------------------
# Destroy cloned pool VMs (power off + delete). Safe because these are
# disposable clones, not templates.
#
# Usage: destroy_pools [--all] [pool1 pool2 ...]
#
destroy_pools() {
    local all_pools=""
    local pools=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --all) all_pools=1; shift ;;
            *) pools+=("$1"); shift ;;
        esac
    done

    if [ -n "$all_pools" ]; then
        echo "=== Destroying all pool clone VMs ==="
        # Destroy regN and discoN clones (try 1..10)
        local i
        for (( i=1; i<=10; i++ )); do
            destroy_vm "reg${i}" 2>/dev/null
            destroy_vm "disco${i}" 2>/dev/null
        done
    else
        for pool in "${pools[@]}"; do
            echo "  Destroying clone: $pool"
            destroy_vm "$pool"
        done
    fi

    echo "=== Pool clones destroyed ==="
}

# --- list_pools -------------------------------------------------------------
# Show current pool status (which clone VMs exist and their power state).
#
list_pools() {
    echo "=== Pool Status (Clones) ==="
    echo ""
    printf "  %-25s %-10s\n" "CLONE NAME" "POWER"
    echo "  $(printf '%0.s-' {1..40})"

    # Check regN and discoN clones
    local i
    for (( i=1; i<=10; i++ )); do
        for prefix in reg disco; do
            local vm="${prefix}${i}"
            if vm_exists "$vm" 2>/dev/null; then
                local power
                power=$(govc vm.info -json "$vm" 2>/dev/null | grep -o '"powerState":"[^"]*"' | head -1 | cut -d'"' -f4)
                printf "  %-25s %-10s\n" "$vm" "${power:-unknown}"
            fi
        done
    done

    echo ""
}

# --- pool_ready -------------------------------------------------------------
# Check if a pool's connected bastion is SSH-reachable and has aba installed.
#
# Usage: pool_ready HOST
#
pool_ready() {
    local host="$1"

    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" -- "test -d ~/aba" 2>/dev/null; then
        return 1
    fi
    return 0
}
