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
# Clone naming: con1/con2/... (connected), dis1/dis2/... (disconnected)
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

# --- Clone VLAN IPs (static) -----------------------------------------------
# The 10.10.20.0/24 VLAN has no DHCP. Each clone's ens224.10 IP is defined
# in config.env (VM_CLONE_VLAN_IPS). Used by _vm_setup_network.
if ! declare -p VM_CLONE_VLAN_IPS &>/dev/null 2>&1; then
    declare -A VM_CLONE_VLAN_IPS=()
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

    # Add public key to root's authorized_keys (via sudo from $user)
    cat <<-SSHEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		mkdir -p /root/.ssh
		chmod 700 /root/.ssh
		echo "$pub_key" > /root/.ssh/authorized_keys
		chmod 600 /root/.ssh/authorized_keys
	SSHEOF

    # Now that root has key access, copy SSH config
    if [ "$user" != "root" ] && [ -f ~/.ssh/config ]; then
        scp -o StrictHostKeyChecking=no ~/.ssh/config "root@${host}:.ssh/config"
    fi
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
		dnf install chrony -y

		# Replace chrony.conf to use ONLY the specified NTP server
		# (removes any internet NTP sources from the default config)
		cat > /etc/chrony.conf <<-CHRONYEOF
		server $ntp_server iburst
		driftfile /var/lib/chrony/drift
		makestep 1.0 3
		rtcsync
		logdir /var/log/chrony
		CHRONYEOF

		systemctl restart chronyd
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
# Configure network: VLAN interface, MTU, nmcli adjustments, hostname.
# Auto-detects role from clone name: con* = connected, dis* = disconnected.
#
# Connected bastion (con#):
#   ens192  = lab (DHCP, MTU 9000, never-default -- NOT the default route)
#   ens224  = base for VLAN (disabled, MTU 9000)
#   ens224.10 = VLAN to dis# (static IP, never-default)
#   ens256  = internet (DHCP, IS the default route)
#   hostname = con#
#
# Disconnected bastion (dis#):
#   ens192  = lab (DHCP, MTU 9000, IS the default route)
#   ens224  = base for VLAN (disabled, MTU 9000)
#   ens224.10 = VLAN to con# (static IP, never-default)
#   ens256  = disabled (disconnected host has no internet)
#   hostname = dis#
#
# Reference configs:  registry2 (connected), registry (disconnected)
#
# Usage: _vm_setup_network HOST USER CLONE_NAME
#
_vm_setup_network() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local clone_name="${3:-}"
    local vlan_ip="${VM_CLONE_VLAN_IPS[$clone_name]:-10.10.10.1/24}"

    # Auto-detect role from clone name
    local role="disconnected"
    case "$clone_name" in con*) role="connected" ;; esac

    echo "  [vm] Configuring network ($role) on $host (VLAN IP: $vlan_ip) ..."

    if [ "$role" = "connected" ]; then
        _vm_setup_network_connected "$host" "$user" "$clone_name" "$vlan_ip"
    else
        _vm_setup_network_disconnected "$host" "$user" "$clone_name" "$vlan_ip"
    fi
}

# --- _vm_setup_network_connected -------------------------------------------
# Configure a connected bastion (gateway). Default route via ens256 (internet).
# Matches registry2 reference config.
#
_vm_setup_network_connected() {
    local host="$1" user="$2" clone_name="$3" vlan_ip="$4"

    cat <<-NETEOF | ssh "${user}@${host}" -- sudo bash
		set -ex

		# --- Rename default nmcli connections to match interface names ---
		nmcli connection show
		nmcli -g NAME connection show | grep -q "^Wired connection 1$" && \
		    nmcli connection modify "Wired connection 1" connection.id ens224
		nmcli -g NAME connection show | grep -q "^Wired connection 2$" && \
		    nmcli connection modify "Wired connection 2" connection.id ens256

		# --- ens192: lab network (NOT default route) ---
		nmcli connection modify ens192 \
		    ipv4.never-default yes \
		    ipv6.method disabled \
		    802-3-ethernet.mtu 9000
		nmcli connection up ens192

		# --- ens256: internet (IS the default route) ---
		# ignore-auto-dns: the DHCP-provided DNS on this NIC (gateway IP)
		# does not know about example.com zones; use only the lab DNS (ens192).
		nmcli connection modify ens256 \
		    ipv4.never-default no \
		    ipv4.ignore-auto-dns yes \
		    ipv6.method disabled
		nmcli connection up ens256

		# --- ens224: base for VLAN (no IP, just carrier) ---
		nmcli connection modify ens224 \
		    ipv4.method disabled \
		    ipv4.never-default yes \
		    ipv6.method disabled \
		    802-3-ethernet.mtu 9000
		nmcli connection up ens224

		# --- ens224.10: VLAN to disconnected bastion ---
		nmcli -g NAME connection show | grep -q "^ens224\.10$" && \
		    nmcli connection delete ens224.10
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses $vlan_ip ipv4.never-default yes

		# --- Hostname ---
		hostnamectl set-hostname $clone_name

		echo "=== Network configured (connected) ==="
		ip -br addr
		ip route
	NETEOF
}

# --- _vm_setup_network_disconnected ----------------------------------------
# Configure a disconnected bastion. Default route via con#'s VLAN IP so all
# internet traffic is routed through the connected bastion's masquerade.
# ens256 is disabled (disconnected host has no direct internet).
#
# Routing:
#   default -> con#'s VLAN IP via ens224.10 (internet through masquerade)
#   lab     -> ens192 (never-default, lab traffic only)
#   VLAN    -> ens224.10 (direct link to con#)
#
_vm_setup_network_disconnected() {
    local host="$1" user="$2" clone_name="$3" vlan_ip="$4"

    # Derive the connected bastion's VLAN IP as the default gateway.
    # dis1 -> con1, dis2 -> con2, etc.
    local pool_num="${clone_name#dis}"
    local con_name="con${pool_num}"
    local gateway_ip="${VM_CLONE_VLAN_IPS[$con_name]%%/*}"

    echo "  [vm] Default gateway for $clone_name: $gateway_ip ($con_name via VLAN)"

    cat <<-NETEOF | ssh "${user}@${host}" -- sudo bash
		set -ex

		# --- Rename default nmcli connections to match interface names ---
		nmcli connection show
		nmcli -g NAME connection show | grep -q "^Wired connection 1$" && \
		    nmcli connection modify "Wired connection 1" connection.id ens224
		nmcli -g NAME connection show | grep -q "^Wired connection 2$" && \
		    nmcli connection modify "Wired connection 2" connection.id ens256

		# --- ens256: DISABLE (disconnected host has no direct internet) ---
		nmcli connection modify ens256 \
		    autoconnect no \
		    ipv4.method disabled \
		    ipv6.method disabled
		nmcli connection down ens256 || echo "ens256 already down"
		ip link set ens256 down

		# --- ens192: lab network (NOT the default route) ---
		nmcli connection modify ens192 \
		    ipv4.never-default yes \
		    ipv6.method disabled \
		    802-3-ethernet.mtu 9000
		nmcli connection up ens192

		# --- ens224: base for VLAN (no IP, just carrier) ---
		nmcli connection modify ens224 \
		    ipv4.method disabled \
		    ipv4.never-default yes \
		    ipv6.method disabled \
		    802-3-ethernet.mtu 9000
		nmcli connection up ens224

		# --- ens224.10: VLAN to connected bastion ---
		# Gateway = con#'s VLAN IP -> all internet traffic goes via masquerade
		nmcli -g NAME connection show | grep -q "^ens224\.10$" && \
		    nmcli connection delete ens224.10
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses $vlan_ip \
		    ipv4.gateway $gateway_ip

		# --- Hostname ---
		hostnamectl set-hostname $clone_name

		echo "=== Network configured (disconnected) ==="
		echo "Default gateway: $gateway_ip (via VLAN to $con_name)"
		ip -br addr
		ip route
	NETEOF
}

# --- _vm_setup_firewall -----------------------------------------------------
# Set up firewalld with NAT masquerade on a connected bastion.
# Matches registry2 reference: zone-wide masquerade, ip_forward=1.
# This allows the disconnected bastion to reach the internet via the VLAN.
#
# Usage: _vm_setup_firewall HOST [USER]
#
_vm_setup_firewall() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Configuring firewall + NAT masquerade on $host ..."

    cat <<-FWEOF | ssh "${user}@${host}" -- sudo bash
		set -ex
		# Remove legacy iptables-services (may not be installed)
		rpm -q iptables-services && {
		    systemctl disable --now iptables
		    dnf remove -y iptables-services
		} || echo "iptables-services not installed -- skipping"

		# Enable firewalld
		systemctl enable --now firewalld

		# Enable IP forwarding (persistent)
		cat > /etc/sysctl.d/99-ipforward.conf <<-SYSEOF
		net.ipv4.ip_forward = 1
		SYSEOF
		sysctl -p /etc/sysctl.d/99-ipforward.conf

		# Zone-wide masquerade (matches registry2 reference config)
		firewall-cmd --permanent --zone=public --add-masquerade
		firewall-cmd --reload

		echo "=== FIREWALL CONFIG ==="
		firewall-cmd --list-all --zone=public
		echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
	FWEOF
}

# --- _vm_setup_dnsmasq ------------------------------------------------------
# Install and configure dnsmasq on a connected bastion to serve cluster DNS
# for its pool. This makes the E2E framework fully self-contained -- no need
# to pre-create DNS records on the lab DNS server.
#
# dnsmasq serves:
#   - api.<cluster>.pN.example.com  -> node IP or API VIP
#   - *.apps.<cluster>.pN.example.com -> node IP or APPS VIP
#   - Everything else -> forwarded to DNS_UPSTREAM (lab DNS)
#
# Usage: _vm_setup_dnsmasq HOST USER CLONE_NAME
#
_vm_setup_dnsmasq() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local clone_name="${3:-$host}"

    # Derive pool number from clone name: con1 -> 1, con2 -> 2, etc.
    local pool_num="${clone_name#con}"
    local upstream="${DNS_UPSTREAM:-10.0.1.8}"

    # Resolve pool-specific values (functions from config-helpers.sh)
    local domain
    domain="${POOL_DOMAIN[$pool_num]:-p${pool_num}.example.com}"
    local node_ip
    node_ip="${POOL_NODE_IP[$pool_num]:-${POOL_SUBNET:-10.0.2}.$((pool_num * 10 + 2))}"
    local api_vip
    api_vip="${POOL_API_VIP[$pool_num]:-${POOL_SUBNET:-10.0.2}.$((pool_num * 10 + 3))}"
    local apps_vip
    apps_vip="${POOL_APPS_VIP[$pool_num]:-${POOL_SUBNET:-10.0.2}.$((pool_num * 10 + 4))}"

    echo "  [vm] Setting up dnsmasq on $host for pool $pool_num ($domain) ..."
    echo "  [vm]   node=$node_ip  api_vip=$api_vip  apps_vip=$apps_vip  upstream=$upstream"

    # Build the dnsmasq config
    local dnsmasq_conf
    read -r -d '' dnsmasq_conf <<-DNSEOF || true
# =============================================================================
# E2E Test DNS -- Pool ${pool_num} (${domain})
# Auto-generated by _vm_setup_dnsmasq. Do not edit.
# =============================================================================

# Listen on all interfaces, don't read /etc/resolv.conf
no-resolv
bind-interfaces

# Forward non-cluster queries to upstream lab DNS
server=${upstream}

# --- SNO: api + apps -> node IP ---
address=/api.$(pool_cluster_name sno ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name sno ${pool_num}).${domain}/${node_ip}

# --- Compact: api -> API VIP, apps -> APPS VIP ---
address=/api.$(pool_cluster_name compact ${pool_num}).${domain}/${api_vip}
address=/.apps.$(pool_cluster_name compact ${pool_num}).${domain}/${apps_vip}

# --- Standard: api -> API VIP, apps -> APPS VIP ---
address=/api.$(pool_cluster_name standard ${pool_num}).${domain}/${api_vip}
address=/.apps.$(pool_cluster_name standard ${pool_num}).${domain}/${apps_vip}
DNSEOF

    cat <<-SETUPEOF | ssh "${user}@${host}" -- sudo bash
		set -ex

		# Install dnsmasq and dig (bind-utils)
		dnf install -y dnsmasq bind-utils

		# Write config
		cat > /etc/dnsmasq.d/e2e-pool.conf << 'CONFEOF'
${dnsmasq_conf}
CONFEOF

		# Disable systemd-resolved if it's running (conflicts with port 53)
		if systemctl is-active --quiet systemd-resolved; then
		    systemctl disable --now systemd-resolved
		fi

		# Ensure /etc/resolv.conf points to localhost so the bastion itself
		# uses its own dnsmasq (and through it, the upstream).
		# Tell NetworkManager not to manage resolv.conf, otherwise it
		# regenerates it from DHCP and overwrites our 127.0.0.1 entry.
		cat > /etc/NetworkManager/conf.d/no-dns.conf << 'NMEOF'
[main]
dns=none
NMEOF
		systemctl reload NetworkManager

		cat > /etc/resolv.conf << 'RESOLVEOF'
# Managed by E2E dnsmasq setup -- NetworkManager dns=none
search example.com
nameserver 127.0.0.1
RESOLVEOF

		# Enable and start dnsmasq
		systemctl enable --now dnsmasq
		systemctl restart dnsmasq

		# Open DNS port in firewall
		firewall-cmd --permanent --add-service=dns
		firewall-cmd --reload

		echo "=== dnsmasq configured for pool ${pool_num} ==="
		echo "Upstream: ${upstream}"
		echo "Domain: ${domain}"
		dnsmasq --test
		systemctl status dnsmasq --no-pager
	SETUPEOF

    # Verify DNS resolution from the bastion itself
    local sno_name
    sno_name="$(pool_cluster_name sno ${pool_num})"
    echo "  [vm] Verifying DNS on $host (cluster name: $sno_name) ..."
    ssh "${user}@${host}" -- bash -c "
        echo '--- Testing cluster DNS ---'
        dig +short api.${sno_name}.${domain} @127.0.0.1
        dig +short test.apps.${sno_name}.${domain} @127.0.0.1
        echo '--- Testing upstream forwarding ---'
        dig +short google.com @127.0.0.1 | head -1
    "
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
		rm -rfv \$HOME/.oc-mirror/.cache
		rm -rfv \$HOME/*/.oc-mirror/.cache
		# Ensure test VMs are located together
		if [ -s ~/.vmware.conf ]; then
		    sed -i "s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/abatesting}#g" ~/.vmware.conf
		fi
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
        set -e
        command -v podman || sudo dnf install podman -y
        podman system prune --all --force
        podman rmi --all --force
        sudo rm -rfv ~/.local/share/containers/storage
        rm -rfv ~/test
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
        scp "$vf" "${user}@${host}:"
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
        "sudo dnf remove git hostname make jq python3-jinja2 python3-pyyaml -y"
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
        "if [ -f ~/.bashrc ]; then sed -i 's|^source ~/.proxy-set.sh|# aba-test # source ~/.proxy-set.sh|g' ~/.bashrc; fi"
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
		id $test_user_name && userdel $test_user_name -r -f || true
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

# --- _vm_set_aba_testing ----------------------------------------------------
# Add 'export ABA_TESTING=1' to ~/.bashrc for root, the default user (steve),
# and the test user (testy). This disables usage tracking during E2E runs.
#
_vm_set_aba_testing() {
    local host="$1"
    local def_user="${2:-$VM_DEFAULT_USER}"

    echo "  [vm] Setting ABA_TESTING=1 on $host (root, $def_user, testy) ..."

    cat <<-'TESTEOF' | ssh "${def_user}@${host}" -- sudo bash
		set -e
		for home_dir in /root "/home/$SUDO_USER" /home/testy; do
		    [ -d "$home_dir" ] || continue
		    rc="$home_dir/.bashrc"
		    # Ensure .bashrc exists
		    touch "$rc"
		    # Remove any existing ABA_TESTING lines to avoid duplicates
		    sed -i '/^export ABA_TESTING=/d' "$rc"
		    # Append the export
		    echo 'export ABA_TESTING=1' >> "$rc"
		    # Fix ownership (testy's home must be owned by testy, etc.)
		    user_name=$(basename "$home_dir")
		    [ "$home_dir" = "/root" ] && user_name=root
		    chown "$user_name":"$user_name" "$rc"
		done
	TESTEOF
}

# --- _vm_install_aba --------------------------------------------------------
# Rsync the aba tree to the VM and run ./install.
#
_vm_install_aba() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local aba_root="${3:-$(cd "$_E2E_LIB_DIR_PL/../../.." && pwd)}"

    echo "  [vm] Installing aba on ${user}@${host} ..."

    # Ensure rsync is available on the remote host
    ssh "${user}@${host}" -- "command -v rsync || sudo dnf install -y rsync"

    rsync -az --no-perms --exclude='.git' --exclude='cli/*.tar.gz' \
        "$aba_root/" "${user}@${host}:~/aba/"

    ssh "${user}@${host}" -- "cd ~/aba && ./install"
}

# =============================================================================
# Composition functions: configure_connected_bastion / configure_internal_bastion
# =============================================================================

# --- configure_connected_bastion --------------------------------------------
# Configure a VM as an internet-connected registry host (bastion).
# The connected bastion bridges the internet (ens256) to the private VLAN
# (ens224.10) so the disconnected bastion can reach it via NAT masquerade.
#
# NICs:
#   ens192     = private lab (DHCP, MTU 9000)
#   ens224.10  = VLAN to disconnected bastion (static IP from VM_CLONE_VLAN_IPS)
#   ens256     = internet (DHCP, default route)
#
# Usage: configure_connected_bastion HOST [USER] [CLONE_NAME]
#
configure_connected_bastion() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local clone_name="${3:-$host}"

    echo "=== Configuring connected bastion: $host (clone: $clone_name) ==="

    _vm_wait_ssh "$host" "$user"
    _vm_setup_ssh_keys "$host" "$user"

    # Network + firewall first (NTP needs internet via ens256)
    _vm_setup_network "$host" "$user" "$clone_name"
    _vm_setup_firewall "$host" "$user"

    # DNS: run dnsmasq for this pool's cluster records
    _vm_setup_dnsmasq "$host" "$user" "$clone_name"

    _vm_setup_time "$host" "$user"

    # Clean up
    _vm_cleanup_caches "$host" "$user"
    _vm_cleanup_podman "$host" "$user"
    _vm_cleanup_home "$host" "$user"

    # Config
    _vm_setup_vmware_conf "$host" "$user"
    _vm_create_test_user "$host" "$user"
    _vm_set_aba_testing "$host" "$user"
    _vm_install_aba "$host" "$user"

    echo "=== Connected bastion ready: $host ==="
}

# --- configure_internal_bastion ---------------------------------------------
# Configure a VM as an air-gapped internal bastion. Full setup including
# network hardening, firewall/NAT, RPM removal, proxy removal, etc.
# This is the modular equivalent of the old init_bastion() in test/include.sh.
#
# Usage: configure_internal_bastion HOST [USER] [TEST_USER] [CLONE_NAME]
#   CLONE_NAME is used to look up the VLAN IP from VM_CLONE_VLAN_IPS.
#   If omitted, defaults to HOST (works when hostname = clone name).
#
configure_internal_bastion() {
    local host="$1"
    local user="${2:-$VM_DEFAULT_USER}"
    local test_user="${3:-${TEST_USER:-$VM_DEFAULT_USER}}"
    local clone_name="${4:-$host}"

    echo "=== Configuring internal bastion: $host (clone: $clone_name) ==="

    _vm_wait_ssh "$host" "$user"
    _vm_setup_ssh_keys "$host" "$user"

    # Network + firewall first (NTP needs route through con# masquerade)
    _vm_setup_network "$host" "$user" "$clone_name"
    _vm_setup_firewall "$host" "$user"

    _vm_setup_time "$host" "$user"

    # Update and reboot
    _vm_dnf_update "$host" "$user"
    _vm_wait_ssh "$host" "$user"

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
    _vm_set_aba_testing "$host" "$user"

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
#   - A connected bastion clone (conN) from the template
#   - Optionally a paired disconnected bastion clone (disN) from the template
#
# Templates are never modified. Previous clones are destroyed and re-cloned
# fresh every time.
#
create_pools() {
    local count="$1"; shift
    local rhel_ver="${INT_BASTION_RHEL_VER:-rhel9}"
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

        # Clone connected bastion: template -> conN
        local conn_vm="con${i}"
        echo "  Cloning connected bastion: $vm_template -> $conn_vm"
        clone_vm "$vm_template" "$conn_vm"
        configure_connected_bastion "$conn_vm" "$VM_DEFAULT_USER" "$conn_vm"

        # Clone disconnected bastion: template -> disN (if not --connected-only)
        if [ -z "$connected_only" ]; then
            local int_vm="dis${i}"
            echo "  Cloning disconnected bastion: $vm_template -> $int_vm"
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
        # Destroy conN and disN clones (try 1..10)
        local i
        for (( i=1; i<=10; i++ )); do
            destroy_vm "con${i}"
            destroy_vm "dis${i}"
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

    # Check conN and disN clones
    local i
    for (( i=1; i<=10; i++ )); do
        for prefix in con dis; do
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
