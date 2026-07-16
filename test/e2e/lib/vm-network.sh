#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework -- VM Network Operations
# =============================================================================
# Connected/disconnected network setup, firewall, dnsmasq, MTU, proxy,
# disconnect. Split from vm-ops.sh.
# =============================================================================

_E2E_LIB_DIR_VMNET="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source remote helpers if not already loaded
if ! type _wait_for_ssh &>/dev/null; then
	source "$_E2E_LIB_DIR_VMNET/remote.sh"
fi
if ! type pool_domain &>/dev/null; then
	source "$_E2E_LIB_DIR_VMNET/config-helpers.sh"
fi

# VLAN IPs per clone (set via config.env)
if ! declare -p VM_CLONE_VLAN_IPS &>/dev/null; then
	declare -A VM_CLONE_VLAN_IPS=()
fi

# --- _vm_setup_default_route ------------------------------------------------
# Remove the bogus default route on ens192 so all internet traffic goes
# via ens256. Used on the golden VM before cloning.

_vm_setup_default_route() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Setting default route via ens256 on $host ..."

	cat <<-'ROUTEEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		nmcli connection modify ens192 ipv4.never-default yes
		nmcli connection up ens192
		echo "=== Routes ==="
		ip route
	ROUTEEOF
}

# --- _vm_setup_network ------------------------------------------------------
# Configure network: VLAN interface, nmcli adjustments, hostname.
# Auto-detects role from clone name: con* = connected, dis* = disconnected.
#
# Connected bastion (con#):
#   ens192  = lab (DHCP, never-default -- NOT the default route)
#   ens224  = base for VLAN (disabled)
#   ens224.10 = VLAN to dis# (static IP, never-default)
#   ens256  = internet (DHCP, IS the default route)
#
# Disconnected bastion (dis#):
#   ens192  = lab (DHCP, never-default)
#   ens224  = base for VLAN (disabled)
#   ens224.10 = VLAN to con# (static IP, IS the default route via masquerade)
#   ens256  = disabled (no internet)

_vm_setup_network() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local clone_name="${3:-}"
	local vlan_ip="${VM_CLONE_VLAN_IPS[$clone_name]:-10.10.10.1/24}"

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

_vm_setup_network_connected() {
	local host="$1" user="$2" clone_name="$3" vlan_ip="$4"

	cat <<-NETEOF | _essh "${user}@${host}" -- sudo bash
		set -ex

		# --- Rename "Wired connection N" to match device name ---
		nmcli connection show
		nmcli -t -f NAME,DEVICE connection show | while IFS=: read -r _name _dev; do
		    case "\$_name" in
		        "Wired connection"*) [ -n "\$_dev" ] && nmcli connection modify "\$_name" connection.id "\$_dev" ;;
		    esac
		done

		# --- Force MTU 1500 on all NICs (DHCP may hand out 9000) ---
		for _c in ens192 ens224 ens256; do
		    nmcli connection modify "\$_c" 802-3-ethernet.mtu 1500 2>/dev/null || true
		done

		# --- ens192: lab network (NOT default route) ---
		nmcli connection modify ens192 \
		    ipv4.never-default yes \
		    ipv6.method disabled
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
		    ipv6.method disabled
		nmcli connection up ens224

		# --- ens224.10: VLAN to disconnected bastion ---
		nmcli -g NAME connection show | grep "^ens224\.10$" && \
		    nmcli connection delete ens224.10
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses $vlan_ip ipv4.never-default yes \
		    802-3-ethernet.mtu 1500

		# --- Route to KVM VLAN 123 subnet (for suite-kvm-network) ---
		# Persist via NM so the route survives reboots/snapshot reverts
		nmcli connection modify ens192 +ipv4.routes "10.10.123.0/24 ${KVM_HOST_LAB_IP:-10.0.1.10}"
		nmcli connection up ens192

		hostnamectl set-hostname $clone_name

		echo "=== Network configured (connected) ==="
		ip -br addr
		ip route
	NETEOF
}

# --- _vm_setup_network_disconnected ----------------------------------------

_vm_setup_network_disconnected() {
	local host="$1" user="$2" clone_name="$3" vlan_ip="$4"

	# Derive the connected bastion's VLAN IP as the default gateway.
	# dis1 -> con1, dis2 -> con2, etc.
	local pool_num="${clone_name#dis}"
	local con_name="con${pool_num}"
	local gateway_ip="${VM_CLONE_VLAN_IPS[$con_name]%%/*}"

	echo "  [vm] Default gateway for $clone_name: $gateway_ip ($con_name via VLAN)"

	cat <<-NETEOF | _essh "${user}@${host}" -- sudo bash
		set -ex

		# --- Rename "Wired connection N" to match device name ---
		nmcli connection show
		nmcli -t -f NAME,DEVICE connection show | while IFS=: read -r _name _dev; do
		    case "\$_name" in
		        "Wired connection"*) [ -n "\$_dev" ] && nmcli connection modify "\$_name" connection.id "\$_dev" ;;
		    esac
		done

		# --- Force MTU 1500 on all NICs (DHCP may hand out 9000) ---
		for _c in ens192 ens224 ens256; do
		    nmcli connection modify "\$_c" 802-3-ethernet.mtu 1500 2>/dev/null || true
		done

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
		    ipv6.method disabled
		nmcli connection up ens192

		# --- ens224: base for VLAN (no IP, just carrier) ---
		nmcli connection modify ens224 \
		    ipv4.method disabled \
		    ipv4.never-default yes \
		    ipv6.method disabled
		nmcli connection up ens224

		# --- ens224.10: VLAN to connected bastion ---
		# Gateway = con#'s VLAN IP -> all internet traffic goes via masquerade
		nmcli -g NAME connection show | grep "^ens224\.10$" && \
		    nmcli connection delete ens224.10
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses $vlan_ip \
		    ipv4.gateway $gateway_ip \
		    802-3-ethernet.mtu 1500

		# --- DNS: point at connected bastion's dnsmasq ---
		cat > /etc/NetworkManager/conf.d/no-dns.conf << 'NMEOF'
[main]
dns=none
NMEOF
		systemctl reload NetworkManager

		cat > /etc/resolv.conf << RESOLVEOF
search example.com
nameserver $gateway_ip
RESOLVEOF

		hostnamectl set-hostname $clone_name

		echo "=== Network configured (disconnected) ==="
		echo "Default gateway: $gateway_ip (via VLAN to $con_name)"
		echo "DNS: $gateway_ip (dnsmasq on $con_name)"
		ip -br addr
		ip route
		cat /etc/resolv.conf
	NETEOF
}

# --- _vm_setup_firewall -----------------------------------------------------

_vm_setup_firewall() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Configuring firewall + NAT masquerade on $host ..."

	cat <<-'FWEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		rpm -q iptables-services && {
		    systemctl disable --now iptables
		    dnf remove -y iptables-services
		} || echo "iptables-services not installed -- skipping"

		systemctl enable --now firewalld

		echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf

		firewall-cmd --permanent --zone=public --add-masquerade

		for _port in 8443/tcp 5000/tcp 80/tcp; do
		    firewall-cmd --query-port="$_port" --permanent \
		        && firewall-cmd --remove-port="$_port" --permanent \
		        && echo "Removed stale port $_port"
		done

		firewall-cmd --reload
		sleep 5

		echo 1 > /proc/sys/net/ipv4/ip_forward

		echo "=== FIREWALL CONFIG ==="
		firewall-cmd --list-all --zone=public
		echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"
		[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || { echo "ERROR: ip_forward is 0"; exit 1; }
	FWEOF
}

# --- _vm_setup_dnsmasq ------------------------------------------------------
# Configure dnsmasq on a connected bastion to serve cluster DNS for its pool.
# dnsmasq serves:
#   - api.<cluster>.pN.example.com  -> node IP or API VIP
#   - *.apps.<cluster>.pN.example.com -> node IP or APPS VIP
#   - registry.pN.example.com -> conN IP
#   - Everything else -> forwarded to DNS_UPSTREAM (lab DNS)

_vm_setup_dnsmasq() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local clone_name="${3:-$host}"

	local pool_num="${clone_name#con}"
	local upstream="${DNS_UPSTREAM:-10.0.1.8}"
	local con_ip="${POOL_SUBNET:-10.0.2}.$((pool_num * 10))"

	local domain
	domain="${POOL_DOMAIN[$pool_num]:-p${pool_num}.example.com}"
	local node_ip
	node_ip="${POOL_NODE_IP[$pool_num]:-${POOL_SUBNET:-10.0.2}.$((pool_num * 10 + 2))}"
	local api_vip
	api_vip="${POOL_API_VIP[$pool_num]:-${POOL_SUBNET:-10.0.2}.$((pool_num * 10 + 3))}"
	local apps_vip
	apps_vip="${POOL_APPS_VIP[$pool_num]:-${POOL_SUBNET:-10.0.2}.$((pool_num * 10 + 4))}"

	local vlan_node_ip vlan_api_vip vlan_apps_vip
	vlan_node_ip="${POOL_VLAN_NODE_IP[$pool_num]:-10.10.20.$((200 + pool_num))}"
	vlan_api_vip="${POOL_VLAN_API_VIP[$pool_num]:-10.10.20.$((210 + pool_num))}"
	vlan_apps_vip="${POOL_VLAN_APPS_VIP[$pool_num]:-10.10.20.$((220 + pool_num))}"

	local kvm_vlan_node_ip kvm_vlan_api_vip kvm_vlan_apps_vip
	kvm_vlan_node_ip="${KVM_VLAN_NODE_IP[$pool_num]:-10.10.123.$((200 + pool_num))}"
	kvm_vlan_api_vip="${KVM_VLAN_API_VIP[$pool_num]:-10.10.123.$((210 + pool_num))}"
	kvm_vlan_apps_vip="${KVM_VLAN_APPS_VIP[$pool_num]:-10.10.123.$((220 + pool_num))}"

	echo "  [vm] Setting up dnsmasq on $host for pool $pool_num ($domain) ..."
	echo "  [vm]   node=$node_ip  api_vip=$api_vip  apps_vip=$apps_vip  upstream=$upstream"
	echo "  [vm]   vlan_node=$vlan_node_ip  vlan_api=$vlan_api_vip  vlan_apps=$vlan_apps_vip"

	local dnsmasq_conf
	read -r -d '' dnsmasq_conf <<-DNSEOF || true
no-resolv
bind-dynamic
server=${upstream}
address=/api.$(pool_cluster_name sno ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name sno ${pool_num}).${domain}/${node_ip}
address=/api.$(pool_cluster_name sno-mirror ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name sno-mirror ${pool_num}).${domain}/${node_ip}
address=/api.$(pool_cluster_name sno-proxyonly ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name sno-proxyonly ${pool_num}).${domain}/${node_ip}
address=/api.$(pool_cluster_name sno-noproxy ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name sno-noproxy ${pool_num}).${domain}/${node_ip}
address=/api.$(pool_cluster_name compact ${pool_num}).${domain}/${api_vip}
address=/.apps.$(pool_cluster_name compact ${pool_num}).${domain}/${apps_vip}
address=/api.$(pool_cluster_name standard ${pool_num}).${domain}/${api_vip}
address=/.apps.$(pool_cluster_name standard ${pool_num}).${domain}/${apps_vip}
address=/api.$(pool_cluster_name sno-vlan ${pool_num}).${domain}/${vlan_node_ip}
address=/.apps.$(pool_cluster_name sno-vlan ${pool_num}).${domain}/${vlan_node_ip}
address=/api.$(pool_cluster_name compact-vlan ${pool_num}).${domain}/${vlan_api_vip}
address=/.apps.$(pool_cluster_name compact-vlan ${pool_num}).${domain}/${vlan_apps_vip}
address=/api.$(pool_cluster_name standard-vlan ${pool_num}).${domain}/${vlan_api_vip}
address=/.apps.$(pool_cluster_name standard-vlan ${pool_num}).${domain}/${vlan_apps_vip}
address=/api.$(pool_cluster_name kvm-sno-vlan ${pool_num}).${domain}/${kvm_vlan_node_ip}
address=/.apps.$(pool_cluster_name kvm-sno-vlan ${pool_num}).${domain}/${kvm_vlan_node_ip}
address=/api.$(pool_cluster_name kvm-compact-vlan ${pool_num}).${domain}/${kvm_vlan_api_vip}
address=/.apps.$(pool_cluster_name kvm-compact-vlan ${pool_num}).${domain}/${kvm_vlan_apps_vip}
address=/api.$(pool_cluster_name primed-sno ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name primed-sno ${pool_num}).${domain}/${node_ip}
address=/api.$(pool_cluster_name primed-compact ${pool_num}).${domain}/${api_vip}
address=/.apps.$(pool_cluster_name primed-compact ${pool_num}).${domain}/${apps_vip}
address=/api.$(pool_cluster_name vmw-preflight-pos ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name vmw-preflight-pos ${pool_num}).${domain}/${node_ip}
address=/api.$(pool_cluster_name vmw-preflight-neg ${pool_num}).${domain}/${node_ip}
address=/.apps.$(pool_cluster_name vmw-preflight-neg ${pool_num}).${domain}/${node_ip}
address=/registry.${domain}/${POOL_SUBNET:-10.0.2}.$((pool_num * 10))
DNSEOF

	cat <<-SETUPEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		# Remove options that conflict with bind-dynamic from the default config.
		# RHEL 9 ships with bind-interfaces and interface=lo; RHEL 10 ships with
		# local-service=host (implies bind-interfaces in dnsmasq 2.90+).
		sed -i '/^listen-address/d; /^bind-interfaces/d; /^interface=/d; /^local-service/d' /etc/dnsmasq.conf

		cat > /etc/dnsmasq.d/e2e-pool.conf << 'CONFEOF'
${dnsmasq_conf}
CONFEOF

		if systemctl is-active --quiet systemd-resolved; then
		    systemctl disable --now systemd-resolved
		fi

		cat > /etc/NetworkManager/conf.d/no-dns.conf << 'NMEOF'
[main]
dns=none
NMEOF
		systemctl reload NetworkManager

		# Tell NM that ens192's DNS is conN's own IP (not DHCP-provided upstream).
		# ABA's get_dns_servers() queries nmcli first, so this must be correct.
		nmcli connection modify ens192 \
		    ipv4.ignore-auto-dns yes \
		    ipv4.dns "${con_ip}"
		nmcli connection up ens192

		cat > /etc/resolv.conf << RESOLVEOF
search example.com
nameserver ${con_ip}
RESOLVEOF

		systemctl enable dnsmasq
		systemctl restart dnsmasq

		firewall-cmd --permanent --add-service=dns
		firewall-cmd --reload

		# Restart dnsmasq when the VLAN interface comes up so the UDP
		# socket binds to the correct address (bind-dynamic race fix).
		cat > /etc/NetworkManager/dispatcher.d/99-dnsmasq-rebind <<-'DISPEOF'
			#!/bin/bash
			[ "\$2" = "up" ] && [[ "\$1" == ens224* ]] && systemctl restart dnsmasq
		DISPEOF
		chmod 755 /etc/NetworkManager/dispatcher.d/99-dnsmasq-rebind

		echo "=== dnsmasq configured for pool ${pool_num} ==="
		dnsmasq --test
		systemctl status dnsmasq --no-pager
	SETUPEOF

	local sno_name
	sno_name="$(pool_cluster_name sno ${pool_num})"
	echo "  [vm] Verifying DNS on $host (cluster name: $sno_name) ..."
	cat <<-DNSEOF | _essh "${user}@${host}" -- bash
		echo '--- Testing cluster DNS ---'
		dig +short api.${sno_name}.${domain} @127.0.0.1
		dig +short test.apps.${sno_name}.${domain} @127.0.0.1
		echo '--- Testing registry DNS ---'
		dig +short registry.${domain} @127.0.0.1
		echo '--- Testing upstream forwarding ---'
		dig +short google.com @127.0.0.1 | head -1
	DNSEOF
}

# --- _vm_fix_mtu --------------------------------------------------------------
# Force MTU 1500 on all Ethernet NICs.  The ESXi DHCP server hands out
# interface_mtu=9000 (jumbo frames from the vSwitch), which breaks ABA's
# networking expectations.  Setting it in the golden image means every clone
# inherits the correct value.

_vm_fix_mtu() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Fixing MTU to 1500 on all NICs on $host ..."

	cat <<-'MTUEOF' | _essh "${user}@${host}" -- sudo bash
		nmcli -g NAME connection show | while IFS= read -r conn; do
			[ -z "$conn" ] && continue
			type=$(nmcli -g connection.type connection show "$conn" 2>/dev/null) || continue
			case "$type" in
				802-3-ethernet|vlan)
					cur=$(nmcli -g 802-3-ethernet.mtu connection show "$conn" 2>/dev/null) || true
					if [ "$cur" != "1500" ]; then
						nmcli connection modify "$conn" 802-3-ethernet.mtu 1500 2>/dev/null || true
						echo "    $conn: MTU set to 1500 (was: ${cur:-auto})"
					fi
					;;
			esac
		done
		# Apply MTU immediately without bouncing connections (would kill SSH)
		nmcli -g DEVICE device status | while IFS= read -r dev; do
			[ "$dev" = "lo" ] && continue
			[ -z "$dev" ] && continue
			ip link set "$dev" mtu 1500 2>/dev/null || true
		done
	MTUEOF
}

# --- _vm_fix_proxy_noproxy ---------------------------------------------------

_vm_fix_proxy_noproxy() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Fixing no_proxy in ~/.proxy-set.sh on $host ..."

	cat <<-'PROXYEOF' | _essh "${user}@${host}" -- bash
		if [ -f ~/.proxy-set.sh ]; then
		    sed -i "s|^export no_proxy=.*|export no_proxy=localhost,127.0.0.1,.lan,.example.com,10.0.0.0/8,192.168.0.0/16|" ~/.proxy-set.sh
		    sed -i "s|^export NO_PROXY=.*|export NO_PROXY=localhost,127.0.0.1,.lan,.example.com,10.0.0.0/8,192.168.0.0/16|" ~/.proxy-set.sh
		fi
	PROXYEOF
}

# --- _vm_disable_proxy_autoload ----------------------------------------------

_vm_disable_proxy_autoload() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Disabling proxy auto-load on $host ..."
	_essh "${user}@${host}" -- \
		"if [ -f ~/.bashrc ]; then sed -i 's|^source ~/.proxy-set.sh|# aba-test # source ~/.proxy-set.sh|g' ~/.bashrc; fi"
}

# --- _vm_disconnect_internet ------------------------------------------------

_vm_disconnect_internet() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Disconnecting internet on $host ..."

	cat <<-'DISCEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		nmcli connection modify ens224.10 ipv4.gateway ''
		nmcli connection up ens224.10

		nmcli connection down ens256 || true
		ip link set ens256 down || true

		echo '=== Routes after disconnect ==='
		ip route
		echo '=== Verify ens256 is DOWN ==='
		ip link show ens256 | grep 'state DOWN' && echo 'GOOD: ens256 is DOWN' || echo 'WARNING: ens256 not in DOWN state'
		echo '=== Verify no internet ==='
		! ping -c 1 -W 3 8.8.8.8 && echo 'GOOD: no internet access' || { echo 'ERROR: internet still reachable'; exit 1; }
	DISCEOF
}
