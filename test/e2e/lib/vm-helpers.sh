#!/usr/bin/env bash
# =============================================================================
# E2E Test Framework v2 -- VM Helper Functions
# =============================================================================
# Pure _vm_* composable helpers extracted from v1's pool-lifecycle.sh.
# No orchestration logic -- just individual VM configuration steps.
#
# Used by: setup-infra.sh, runner.sh (for snapshot revert)
#
# IMPORTANT -- heredoc + stdin hazard:
#   Every _vm_* helper pipes a heredoc into 'ssh ... bash', so the remote
#   bash reads its script from stdin.  Commands like dnf/yum (Python-based)
#   can read from the same stdin even with -y, consuming lines that bash
#   has not yet executed.  To avoid this:
#     - Keep dnf/yum calls as the LAST command in a heredoc, or
#     - Redirect their stdin: dnf install -y ... < /dev/null
#   Never add new commands after a dnf/yum call in a heredoc block.
# =============================================================================

_E2E_LIB_DIR_VM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source remote helpers if not already loaded
if ! type remote_wait_ssh &>/dev/null 2>&1; then
	source "$_E2E_LIB_DIR_VM/remote.sh"
fi
if ! type pool_domain &>/dev/null 2>&1; then
	source "$_E2E_LIB_DIR_VM/config-helpers.sh"
fi

# --- VM Template Configuration ----------------------------------------------

declare -A VM_TEMPLATES=(
	[rhel8]="aba-e2e-template-rhel8"
	[rhel9]="aba-e2e-template-rhel9"
	[rhel10]="aba-e2e-template-rhel10"
)

# MAC addresses per clone (set via config.env, declared here if not already)
if ! declare -p VM_CLONE_MACS &>/dev/null 2>&1; then
	declare -A VM_CLONE_MACS=()
fi

# VLAN IPs per clone (set via config.env)
if ! declare -p VM_CLONE_VLAN_IPS &>/dev/null 2>&1; then
	declare -A VM_CLONE_VLAN_IPS=()
fi

VM_DEFAULT_USER="${VM_DEFAULT_USER:-steve}"

# --- SSH wrappers -----------------------------------------------------------

_essh() {
	ssh -o ConnectTimeout=10 -o BatchMode=yes \
		-o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
}
_escp() {
	scp -o ConnectTimeout=10 -o BatchMode=yes \
		-o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@"
}

# --- _vm_wait_ssh -----------------------------------------------------------

_vm_wait_ssh() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local timeout="${3:-${SSH_WAIT_TIMEOUT:-300}}"
	local start=$(date +%s)

	echo "  [vm] Waiting for SSH on ${user}@${host} (timeout: ${timeout}s) ..."
	local consecutive=0
	while true; do
		if _essh -o BatchMode=yes "${user}@${host}" -- "date" 2>/dev/null; then
			consecutive=$(( consecutive + 1 ))
			if [ $consecutive -ge 2 ]; then
				echo "  [vm] SSH ready on ${user}@${host}"
				return 0
			fi
			sleep 2
			continue
		fi
		consecutive=0

		local elapsed=$(( $(date +%s) - start ))
		if [ $elapsed -ge $timeout ]; then
			echo "  [vm] ERROR: SSH timeout after ${timeout}s for ${user}@${host}" >&2
			return 1
		fi
		sleep 3
	done
}

# --- _vm_setup_ssh_keys -----------------------------------------------------

_vm_setup_ssh_keys() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local pub_key
	pub_key=$(cat ~/.ssh/id_rsa.pub)

	echo "  [vm] Setting up SSH keys on $host ..."

	cat <<-SSHEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		mkdir -p /root/.ssh
		chmod 700 /root/.ssh
		echo '${pub_key}' > /root/.ssh/authorized_keys
		chmod 600 /root/.ssh/authorized_keys
		ls -la /root/.ssh/

		[ -f /home/${user}/.ssh/config ] && cp /home/${user}/.ssh/config /root/.ssh/config

		sed -i '/^ClientAliveInterval/d; /^ClientAliveCountMax/d' /etc/ssh/sshd_config
		echo "ClientAliveInterval 60"  >> /etc/ssh/sshd_config
		echo "ClientAliveCountMax 5"   >> /etc/ssh/sshd_config
		systemctl restart sshd
		echo "SSH setup complete."
	SSHEOF
}

# --- _vm_setup_time ---------------------------------------------------------

_vm_setup_time() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local ntp_server="${NTP_SERVER:-10.0.1.8}"
	local timezone="${TIMEZONE:-Asia/Singapore}"

	echo "  [vm] Configuring time/NTP on $host ..."

	cat <<-TIMEEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		dnf install chrony -y

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

_vm_dnf_update() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Running dnf clean + update on $host ..."

	cat <<-'DNFEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		dnf clean all
		dnf update -y 2>&1 | tee /tmp/dnf-update.log
		echo "dnf-update exit=${PIPESTATUS[0]}"
		dnf clean all
	DNFEOF

	echo "  [vm] Rebooting $host ..."
	_essh "${user}@${host}" -- "sudo reboot" || true
	sleep 20
}

# --- _vm_setup_default_route ------------------------------------------------

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

_vm_setup_network_connected() {
	local host="$1" user="$2" clone_name="$3" vlan_ip="$4"

	cat <<-NETEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		nmcli connection show
		nmcli -g NAME connection show | grep "^Wired connection 1$" && \
		    nmcli connection modify "Wired connection 1" connection.id ens224
		nmcli -g NAME connection show | grep "^Wired connection 2$" && \
		    nmcli connection modify "Wired connection 2" connection.id ens256

		nmcli connection modify ens192 \
		    ipv4.never-default yes \
		    ipv6.method disabled
		nmcli connection up ens192

		nmcli connection modify ens256 \
		    ipv4.never-default no \
		    ipv4.ignore-auto-dns yes \
		    ipv6.method disabled
		nmcli connection up ens256

		nmcli connection modify ens224 \
		    ipv4.method disabled \
		    ipv4.never-default yes \
		    ipv6.method disabled
		nmcli connection up ens224

		nmcli -g NAME connection show | grep "^ens224\.10$" && \
		    nmcli connection delete ens224.10
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses $vlan_ip ipv4.never-default yes

		hostnamectl set-hostname $clone_name

		echo "=== Network configured (connected) ==="
		ip -br addr
		ip route
	NETEOF
}

_vm_setup_network_disconnected() {
	local host="$1" user="$2" clone_name="$3" vlan_ip="$4"

	local pool_num="${clone_name#dis}"
	local con_name="con${pool_num}"
	local gateway_ip="${VM_CLONE_VLAN_IPS[$con_name]%%/*}"

	echo "  [vm] Default gateway for $clone_name: $gateway_ip ($con_name via VLAN)"

	cat <<-NETEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		nmcli connection show
		nmcli -g NAME connection show | grep "^Wired connection 1$" && \
		    nmcli connection modify "Wired connection 1" connection.id ens224
		nmcli -g NAME connection show | grep "^Wired connection 2$" && \
		    nmcli connection modify "Wired connection 2" connection.id ens256

		nmcli connection modify ens256 \
		    autoconnect no \
		    ipv4.method disabled \
		    ipv6.method disabled
		nmcli connection down ens256 || echo "ens256 already down"
		ip link set ens256 down

		nmcli connection modify ens192 \
		    ipv4.never-default yes \
		    ipv6.method disabled
		nmcli connection up ens192

		nmcli connection modify ens224 \
		    ipv4.method disabled \
		    ipv4.never-default yes \
		    ipv6.method disabled
		nmcli connection up ens224

		nmcli -g NAME connection show | grep "^ens224\.10$" && \
		    nmcli connection delete ens224.10
		nmcli connection add type vlan con-name ens224.10 ifname ens224.10 dev ens224 \
		    id 10 ipv4.method manual ipv4.addresses $vlan_ip \
		    ipv4.gateway $gateway_ip

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

_vm_setup_dnsmasq() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local clone_name="${3:-$host}"

	local pool_num="${clone_name#con}"
	local upstream="${DNS_UPSTREAM:-10.0.1.8}"

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
DNSEOF

	cat <<-SETUPEOF | _essh "${user}@${host}" -- sudo bash
		set -ex
		dnf install -y dnsmasq bind-utils

		# Remove any listen-address restriction from the default config
		# so dnsmasq listens on ALL interfaces (lab, VLAN, loopback).
		# RHEL 9 default or prior installs may have listen-address=127.0.0.1.
		sed -i '/^listen-address/d' /etc/dnsmasq.conf

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

		cat > /etc/resolv.conf << 'RESOLVEOF'
search example.com
nameserver 127.0.0.1
RESOLVEOF

		systemctl enable dnsmasq
		systemctl restart dnsmasq

		firewall-cmd --permanent --add-service=dns
		firewall-cmd --reload

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
		echo '--- Testing upstream forwarding ---'
		dig +short google.com @127.0.0.1 | head -1
	DNSEOF
}

# --- _vm_cleanup_caches -----------------------------------------------------

_vm_cleanup_caches() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Cleaning caches on $host ..."

	cat <<-CACHEEOF | _essh "${user}@${host}" -- bash
		set -ex
		rm -vrf ~/.cache/agent/
		rm -vrf ~/bin/*
		rm -f ~/.ssh/quay_installer*
		rm -rf ~/.oc-mirror/.cache
		rm -rf ~/*/.oc-mirror/.cache
		if [ -s ~/.vmware.conf ]; then
		    sed -i "s#^VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g" ~/.vmware.conf
		    [ -n "${VM_DATASTORE:-}" ] && sed -i "s#^GOVC_DATASTORE=.*#GOVC_DATASTORE=${VM_DATASTORE}#g" ~/.vmware.conf
		fi
	CACHEEOF
}

# --- _vm_cleanup_podman -----------------------------------------------------

_vm_cleanup_podman() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Cleaning podman on $host ..."

	cat <<-'PODEOF' | _essh "${user}@${host}" -- bash
		set -ex
		command -v podman || sudo dnf install podman -y &> /tmp/dnf-podman.log
		echo "dnf-podman exit=$?"
		podman system prune --all --force
		podman rmi --all --force 2>/dev/null || true
		sudo rm -rf ~/.local/share/containers/storage
		rm -rf ~/test
	PODEOF
}

# --- _vm_cleanup_home -------------------------------------------------------
# Quay/mirror-registry uses systemd user services; stop/disable them first, then
# stop containers, then rm. Use sudo for the rm so root-owned Quay files under
# ~/my-quay-mirror-test1, ~/quay-install, ~/quay-storage are removed.

_vm_cleanup_home() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Cleaning home directory on $host ..."
	cat <<-'HOMEEOF' | _essh "${user}@${host}" -- bash
		set -ex
		# Stop/disable systemd user services (Quay/mirror-registry install creates these)
		systemctl --user stop --all 2>/dev/null || true
		systemctl --user disable --all 2>/dev/null || true
		# Stop all podman/docker containers so no process holds files under ~
		podman stop -a 2>/dev/null || true
		podman rm -af 2>/dev/null || true
		command -v docker >/dev/null 2>&1 && docker stop $(docker ps -q) 2>/dev/null || true
		command -v docker >/dev/null 2>&1 && docker rm -f $(docker ps -aq) 2>/dev/null || true
		sudo rm -rf ~/*
		echo "=== Home directory after cleanup ==="
		ls -la ~/
	HOMEEOF
}

# --- _vm_setup_vmware_conf -------------------------------------------------

_vm_setup_vmware_conf() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local vf="${VMWARE_CONF:-$HOME/.vmware.conf}"

	echo "  [vm] Copying vmware.conf to $host ..."
	if [ -f "$vf" ]; then
		_escp "$vf" "${user}@${host}:"
	fi
}

# --- _vm_remove_pull_secret -------------------------------------------------

_vm_remove_pull_secret() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Removing pull-secret on $host ..."
	_essh "${user}@${host}" -- "rm -fv ~/.pull-secret.json"
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
# Comment out proxy auto-sourcing in .bashrc so clones start proxy-free.
# The ~/.proxy-set.sh and ~/.proxy-unset.sh files are preserved for test use.
#
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
		if nmcli -g NAME connection show | grep "^ens224\.10$"; then
		    nmcli connection modify ens224.10 ipv4.gateway ''
		    nmcli connection up ens224.10
		fi

		# ens256 may already be down on disconnected VMs
		if nmcli -g NAME connection show --active | grep "^ens256$"; then
		    nmcli connection down ens256
		fi
		ip link set ens256 down

		echo '=== Routes after disconnect ==='
		ip route
		echo '=== Verify ens256 is DOWN ==='
		ip link show ens256 | grep 'state DOWN' && echo 'GOOD: ens256 is DOWN' || echo 'WARNING: ens256 not in DOWN state'
		echo '=== Verify no internet ==='
		! ping -c 1 -W 3 8.8.8.8 && echo 'GOOD: no internet access' || { echo 'ERROR: internet still reachable'; exit 1; }
	DISCEOF
}

# --- _vm_create_test_user_and_key_on_host ------------------------------------
# Used on the GOLDEN VM only.  Generates a fresh testy_rsa key pair in the
# default user's ~/.ssh/ on the host, creates the testy user with that public
# key, and verifies SSH locally on the host.  The key pair is baked into the
# golden snapshot so all clones inherit it.  Nothing is copied to bastion.
#
_vm_create_test_user_and_key_on_host() {
	local host="$1"
	local def_user="${2:-$VM_DEFAULT_USER}"
	local test_user_name="testy"

	echo "  [vm] Creating testy key and user on $host ..."

	# Generate a fresh key pair in the default user's ~/.ssh/ on the host.
	# ~/.ssh/ is hidden so it survives _vm_cleanup_home (sudo rm -rf ~/*).
	_essh "${def_user}@${host}" -- "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t rsa -f ~/.ssh/testy_rsa -N '' -C testy -y 2>/dev/null; ssh-keygen -t rsa -f ~/.ssh/testy_rsa -N '' -C testy"

	local pub_key
	pub_key=$(_essh "${def_user}@${host}" -- "cat ~/.ssh/testy_rsa.pub")

	cat <<-USEREOF | _essh "${def_user}@${host}" -- sudo bash
		set -ex
		id $test_user_name && userdel $test_user_name -r -f || true
		useradd $test_user_name -p not-used
		mkdir -p ~${test_user_name}/.ssh
		chmod 700 ~${test_user_name}/.ssh
		echo "$pub_key" > ~${test_user_name}/.ssh/authorized_keys
		chmod 600 ~${test_user_name}/.ssh/authorized_keys
		chown -R ${test_user_name}.${test_user_name} ~${test_user_name}
		restorecon -R /home/${test_user_name} 2>/dev/null || true
		echo '${test_user_name} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${test_user_name}

		if grep "^AllowUsers" /etc/ssh/sshd_config; then
		    if ! grep "^AllowUsers" /etc/ssh/sshd_config | grep -w ${test_user_name}; then
		        sed -i "/^AllowUsers/s/\$/ ${test_user_name}/" /etc/ssh/sshd_config
		        systemctl restart sshd
		    fi
		fi
	USEREOF

	_vm_wait_ssh "$host" "$def_user"

	echo "  [vm] Verifying testy SSH locally on $host ..."
	local who
	who=$(_essh "${def_user}@${host}" -- "ssh -i ~/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${test_user_name}@localhost whoami")
	if [ "$who" != "$test_user_name" ]; then
		echo "  [vm] ERROR: local SSH as $test_user_name failed (got: '$who')" >&2
		return 1
	fi
	echo "  [vm] testy key created and SSH to $test_user_name@localhost verified on $host"
}

# --- _vm_create_test_user ---------------------------------------------------
# (Re-)create the testy user using the key pair already present in the default
# user's ~/.ssh/testy_rsa on the host (placed there during golden VM setup).
# Does NOT read from or write to bastion.

_vm_create_test_user() {
	local host="$1"
	local def_user="${2:-$VM_DEFAULT_USER}"
	local test_user_name="testy"

	echo "  [vm] Creating test user '$test_user_name' on $host ..."

	local pub_key
	pub_key=$(_essh "${def_user}@${host}" -- "cat ~/.ssh/testy_rsa.pub")

	cat <<-USEREOF | _essh "${def_user}@${host}" -- sudo bash
		set -ex
		id $test_user_name && userdel $test_user_name -r -f || true
		useradd $test_user_name -p not-used
		mkdir -p ~${test_user_name}/.ssh
		chmod 700 ~${test_user_name}/.ssh
		echo "$pub_key" > ~${test_user_name}/.ssh/authorized_keys
		chmod 600 ~${test_user_name}/.ssh/authorized_keys
		chown -R ${test_user_name}.${test_user_name} ~${test_user_name}
		restorecon -R /home/${test_user_name} 2>/dev/null || true
		echo '${test_user_name} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${test_user_name}

		if grep "^AllowUsers" /etc/ssh/sshd_config; then
		    if ! grep "^AllowUsers" /etc/ssh/sshd_config | grep -w ${test_user_name}; then
		        sed -i "/^AllowUsers/s/\$/ ${test_user_name}/" /etc/ssh/sshd_config
		        systemctl restart sshd
		    fi
		fi
	USEREOF

	_vm_wait_ssh "$host" "$def_user"

	echo "  [vm] Verifying testy SSH locally on $host ..."
	local who
	who=$(_essh "${def_user}@${host}" -- "ssh -i ~/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${test_user_name}@localhost whoami")
	if [ "$who" != "$test_user_name" ]; then
		echo "  [vm] ERROR: local SSH as $test_user_name failed (got: '$who')" >&2
		return 1
	fi
	echo "  [vm] SSH to $test_user_name@localhost verified on $host"
}

# --- _vm_set_aba_testing ----------------------------------------------------

_vm_set_aba_testing() {
	local host="$1"
	local def_user="${2:-$VM_DEFAULT_USER}"

	echo "  [vm] Setting ABA_TESTING=1 on $host (root, $def_user, testy) ..."

	cat <<-'TESTEOF' | _essh "${def_user}@${host}" -- sudo bash
		set -e
		sed -i '/^ABA_TESTING=/d' /etc/environment
		echo 'ABA_TESTING=1' >> /etc/environment

		for home_dir in /root "/home/$SUDO_USER" /home/testy; do
		    [ -d "$home_dir" ] || continue
		    rc="$home_dir/.bashrc"
		    touch "$rc"
		    sed -i '/^export ABA_TESTING=/d' "$rc"
		    echo 'export ABA_TESTING=1' >> "$rc"
		    user_name=$(basename "$home_dir")
		    [ "$home_dir" = "/root" ] && user_name=root
		    chown "$user_name":"$user_name" "$rc"
		done
	TESTEOF
}

# --- _vm_install_aba --------------------------------------------------------

_vm_install_aba() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local branch
	branch="$(git -C "$_E2E_LIB_DIR_VM/../../.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo dev)"
	local repo_url
	repo_url="$(git -C "$_E2E_LIB_DIR_VM/../../.." remote get-url origin 2>/dev/null || echo https://github.com/sjbylo/aba.git)"

	echo "  [vm] Installing aba on ${user}@${host} (branch: $branch) ..."

	_essh "${user}@${host}" -- "
		rm -rf ~/aba
		git clone --depth 1 --branch $branch $repo_url ~/aba
		cd ~/aba && ./install
	"
}

# --- _vm_verify_golden ------------------------------------------------------

_vm_verify_golden() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"

	echo "  [golden] Verifying golden VM state on $host ..."

	_vm_wait_ssh "$host" "$user"

	cat <<-'VERIFYEOF' | _essh "${user}@${host}" -- sudo bash
		set -ex
		grep "^ClientAliveInterval" /etc/ssh/sshd_config
		firewall-cmd --query-masquerade
		[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]
		systemctl is-active chronyd
		ping -c 3 -W 5 -i0.2 10.0.1.8
		dnf check-update || { rc=$?; [ "$rc" -eq 100 ] && exit 1; exit "$rc"; }
		! podman images -q | grep . || { echo "ERROR: podman images remain"; exit 1; }
		[ -z "$(ls ~$SUDO_USER 2>/dev/null)" ] || { echo "ERROR: stale files in ~$SUDO_USER"; exit 1; }
		id testy
		grep "ABA_TESTING=1" /etc/environment

		echo "All golden VM checks passed."
	VERIFYEOF

	if [ $? -ne 0 ]; then
		echo "  [golden] ERROR: verification FAILED" >&2
		return 1
	fi
}

# --- Composition functions --------------------------------------------------

configure_connected_bastion() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local clone_name="${3:-$host}"

	echo "=== Configuring connected bastion: $host (clone: $clone_name) ==="

	_vm_wait_ssh "$host" "$user"
	_vm_setup_ssh_keys "$host" "$user"
	_vm_setup_network "$host" "$user" "$clone_name"
	_vm_setup_firewall "$host" "$user"
	_vm_setup_dnsmasq "$host" "$user" "$clone_name"
	_vm_setup_time "$host" "$user"
	_vm_cleanup_caches "$host" "$user"
	_vm_cleanup_podman "$host" "$user"
	_vm_cleanup_home "$host" "$user"
	_vm_setup_vmware_conf "$host" "$user"
	_vm_create_test_user "$host" "$user"
	_vm_set_aba_testing "$host" "$user"
	_vm_install_aba "$host" "$user"

	echo "=== Connected bastion ready: $host ==="
}

configure_internal_bastion() {
	local host="$1"
	local user="${2:-$VM_DEFAULT_USER}"
	local test_user="${3:-${TEST_USER:-$VM_DEFAULT_USER}}"
	local clone_name="${4:-$host}"

	echo "=== Configuring internal bastion: $host (clone: $clone_name) ==="

	_vm_wait_ssh "$host" "$user"
	_vm_setup_ssh_keys "$host" "$user"
	_vm_setup_network "$host" "$user" "$clone_name"
	_vm_setup_firewall "$host" "$user"
	_vm_setup_time "$host" "$user"
	_vm_dnf_update "$host" "$user"
	_vm_wait_ssh "$host" "$user"
	_vm_cleanup_caches "$host" "$user"
	_vm_cleanup_podman "$host" "$user"
	_vm_cleanup_home "$host" "$user"
	_vm_setup_vmware_conf "$host" "$user"
	_vm_remove_pull_secret "$host" "$user"
	_vm_disable_proxy_autoload "$host" "$user"
	_vm_create_test_user "$host" "$user"
	_vm_set_aba_testing "$host" "$user"
	_vm_disconnect_internet "$host" "$user"

	echo "=== Internal bastion ready: $host ==="
}
