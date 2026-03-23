#!/bin/bash
# =============================================================================
# E2E Test Framework v2 -- Infrastructure Setup
# =============================================================================
# Replaces clone-and-check suite and create_pools orchestration.
# Called by run.sh before test dispatch. Also usable standalone.
#
# Responsibilities:
#   1. Ensure golden VM (template -> golden -> snapshot)
#   2. Clone conN/disN from golden (reuse if exist + SSH works)
#   3. Configure all VMs (network, DNS, firewall, users, etc.)
#   4. Create pool-ready snapshots
#   5. Install ABA on each conN (git clone + ./install)
#
# Reuse-first: only destroys/recreates when explicitly told to.
#
# Usage:
#   setup-infra.sh -p N [-G] [-R]
#   setup-infra.sh --pools N [--recreate-golden] [--recreate-vms]
#
# All commands are visible (set -x for infra operations).
# =============================================================================

set -u
# Trace is enabled below (after --verify early-exit) for infra operations.
# Show file:line before each traced command (no [ ] so trace is never parsed as a command)
PS4='+ ${BASH_SOURCE##*/}:${LINENO} '

_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_INFRA_DIR/../.." && pwd)"

# Source libraries
source "$_INFRA_DIR/lib/constants.sh"
source "$_INFRA_DIR/lib/config-helpers.sh"
source "$_INFRA_DIR/lib/vm-helpers.sh"
source "$_INFRA_DIR/lib/remote.sh"

# Source config.env
if [ -f "$_INFRA_DIR/config.env" ]; then
	source "$_INFRA_DIR/config.env"
fi

# Source VMware credentials
_vmconf="$(eval echo "${VMWARE_CONF:-~/.vmware.conf}")"
if [ -f "$_vmconf" ]; then
	set -a; source "$_vmconf"; set +a
else
	echo "ERROR: VMware config not found: $_vmconf" >&2
	exit 1
fi

# --- Require govc (fail fast; use ABA ensure_govc when available) ------------
_ensure_govc() {
	if command -v govc &>/dev/null; then
		return 0
	fi
	if [ -f "$_ABA_ROOT/scripts/include_all.sh" ]; then
		# shellcheck source=../../scripts/include_all.sh
		source "$_ABA_ROOT/scripts/include_all.sh"
		if ensure_govc; then
			return 0
		fi
		echo "ERROR: govc installation failed." >&2
		exit 1
	fi
	echo "ERROR: govc not found. Install govc (e.g. from ABA: ensure_govc) or add it to PATH." >&2
	exit 1
}
_ensure_govc

# =============================================================================
# Reusable VM configuration functions
# =============================================================================

_verify_con_vm() {
	local vm="$1" user="$2"

	local pool_num="${vm#con}"
	local _con_vlan="${VM_CLONE_VLAN_IPS[$vm]%%/*}"
	local _domain
	_domain="$(pool_domain "$pool_num")"
	local _ntp="${NTP_SERVER:-10.0.1.8}"
	local _tz="${TIMEZONE:-Asia/Singapore}"

	echo "  [$vm] Verifying ..."
	cat <<-VERIFY | _essh "${user}@${vm}" -- sudo bash
		set -e
		_fail() { printf "  \033[1;31mFAIL: %s\033[0m\n" "\$*"; exit 1; }

		# --- Identity ---
		hostname | grep -q "^${vm}\$" || _fail "hostname \$(hostname) != ${vm}"
		echo "  PASS: hostname ${vm}"

		timedatectl | grep -q "${_tz}" || _fail "timezone not ${_tz}"
		echo "  PASS: timezone ${_tz}"

		# --- Network ---
		ip addr show ens224.10 | grep -q "${_con_vlan}" || _fail "VLAN IP ${_con_vlan} not on ens224.10"
		echo "  PASS: VLAN IP ${_con_vlan} on ens224.10"

		ip route | grep -q "^default.*ens256" || _fail "default route not via ens256"
		echo "  PASS: default route via ens256"

		for _iface in ens192 ens224 ens224.10; do
			_mtu=\$(ip link show \$_iface 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print \$2}')
			[ "\$_mtu" = "1500" ] || _fail "\$_iface MTU is \$_mtu (expected 1500)"
		done
		echo "  PASS: MTU 1500 on all interfaces"

		nmcli -g ipv4.ignore-auto-dns connection show ens256 2>/dev/null | grep -q yes || _fail "ens256 ignore-auto-dns"
		echo "  PASS: ens256 ignore-auto-dns"

		# --- Firewall / NAT ---
		systemctl is-active --quiet firewalld || _fail "firewalld not active"
		echo "  PASS: firewalld active"

		[ "\$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || _fail "ip_forward=0"
		echo "  PASS: ip_forward=1"

		firewall-cmd --query-masquerade > /dev/null || _fail "masquerade not enabled"
		echo "  PASS: masquerade enabled"

		firewall-cmd --list-services | grep -q dns || _fail "dns not in firewall"
		echo "  PASS: firewall dns service"

		# No stale test ports (only pool registry 8443/tcp and ssh 22/tcp expected)
		_stale=\$(firewall-cmd --list-ports | tr ' ' '\n' | grep -vE '^(8443/tcp|22/tcp)?\$' || true)
		[ -z "\$_stale" ] || _fail "stale firewall ports: \$_stale"
		echo "  PASS: no stale firewall ports"

		# --- DNS / dnsmasq ---
		systemctl is-active --quiet dnsmasq || _fail "dnsmasq not active"
		echo "  PASS: dnsmasq active"

		dig +short google.com @127.0.0.1 | head -1 | grep -q . || _fail "DNS @127.0.0.1 -> google.com"
		echo "  PASS: DNS @127.0.0.1 -> google.com"

		dig +short google.com @${_con_vlan} | head -1 | grep -q . || _fail "DNS @${_con_vlan} -> google.com"
		echo "  PASS: DNS @${_con_vlan} -> google.com (disN path)"

		grep -q "nameserver 127.0.0.1" /etc/resolv.conf || _fail "resolv.conf not 127.0.0.1"
		echo "  PASS: resolv.conf -> 127.0.0.1"

		test -f /etc/NetworkManager/conf.d/no-dns.conf || _fail "NM dns=none missing"
		echo "  PASS: NM dns=none"

		# --- Time ---
		systemctl is-active --quiet chronyd || _fail "chronyd not active"
		echo "  PASS: chronyd active"

		for _try in 1 2 3 4 5; do
			ping -c 1 -W 3 ${_ntp} > /dev/null && break
			[ "\$_try" -eq 5 ] && _fail "NTP server ${_ntp} unreachable"
			sleep 5
		done
		echo "  PASS: NTP server ${_ntp} reachable"

		# --- SSH ---
		grep -q "^ClientAliveInterval" /etc/ssh/sshd_config || _fail "sshd ClientAliveInterval"
		echo "  PASS: sshd ClientAliveInterval"

		test -f /home/${user}/.ssh/authorized_keys || _fail "steve authorized_keys missing"
		echo "  PASS: steve authorized_keys exists"

		# --- Users / environment ---
		id testy > /dev/null 2>&1 || _fail "testy user missing"
		echo "  PASS: testy user exists"

		sudo -u testy sudo -n whoami 2>/dev/null | grep -q root || _fail "testy cannot sudo"
		echo "  PASS: testy sudo"

		test -f /home/${user}/.ssh/testy_rsa || _fail "testy_rsa key missing"
		echo "  PASS: testy_rsa key"

		sudo -u ${user} ssh -i /home/${user}/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null testy@localhost whoami < /dev/null 2>&1 | grep -q testy || _fail "testy SSH (local) failed"
		echo "  PASS: testy SSH (local)"

		grep -q "ABA_TESTING=1" /etc/environment || _fail "ABA_TESTING not set"
		echo "  PASS: ABA_TESTING=1"

		# --- Installed software (check as the owning user, not root) ---
		test -x /home/${user}/bin/aba || _fail "aba not installed"
		echo "  PASS: aba installed"

		test -d /home/${user}/aba || _fail "~/aba not present"
		echo "  PASS: ~/aba exists"

		command -v rsync > /dev/null || _fail "rsync not installed"
		echo "  PASS: rsync installed"

		# --- Files ---
		test -s /home/${user}/.vmware.conf || _fail "vmware.conf missing"
		echo "  PASS: vmware.conf"
		test -s /root/.vmware.conf || _fail "root vmware.conf missing"
		echo "  PASS: root vmware.conf"
		if test -s /home/${user}/.kvm.conf; then
			echo "  PASS: kvm.conf"
			test -s /root/.kvm.conf || echo "  WARN: root kvm.conf missing"
		else
			echo "  SKIP: kvm.conf (not deployed)"
		fi

		# --- Podman clean ---
		# Pool registry runs as ${user} with images, containers, and port 8443
		if [ -d $POOL_REG_DIR ]; then
			echo "  SKIP: podman/port checks for ${user} (pool registry present)"
		else
			! sudo -u ${user} podman ps -q 2>/dev/null | grep -q . || _fail "running containers (${user})"
			echo "  PASS: no running containers (${user})"
			! ss -tlnp | grep -q ':8443 ' || _fail "port 8443 in use"
			echo "  PASS: port 8443 free"
		fi
		! podman ps -q 2>/dev/null | grep -q . || _fail "running containers (root)"
		echo "  PASS: no running containers (root)"

		echo "  [$vm] All checks PASSED"
	VERIFY
}

_configure_con_vm() {
	local vm="$1" user="$2"

	_vm_wait_ssh "$vm" "$user"
	_vm_setup_ssh_keys "$vm" "$user"
	_vm_setup_network "$vm" "$user" "$vm"
	_vm_setup_firewall "$vm" "$user"
	_vm_install_packages "$vm" "$user"
	_vm_setup_dnsmasq "$vm" "$user" "$vm"
	_vm_dnf_update "$vm" "$user"
	_vm_wait_ssh "$vm" "$user"
	_vm_cleanup_caches "$vm" "$user"
	_vm_cleanup_podman "$vm" "$user"
	_vm_cleanup_home "$vm" "$user"
	_vm_setup_vmware_conf "$vm" "$user"
	_vm_setup_kvm_conf "$vm" "$user"
	_vm_create_test_user "$vm" "$user"
	_vm_set_aba_testing "$vm" "$user"
	_vm_install_aba "$vm" "$user"

	_verify_con_vm "$vm" "$user"

	echo "  $vm configured."
}

_configure_dis_vm() {
	local vm="$1" user="$2" con_vm="$3"

	_vm_wait_ssh "$vm" "$user"
	_vm_setup_network "$vm" "$user" "$vm"
	_vm_setup_firewall "$vm" "$user"

	echo "  [$vm] Waiting for internet via $con_vm NAT ..."
	local waited=0
	while ! _essh "${user}@${vm}" -- "ping -c1 -W3 8.8.8.8" &>/dev/null; do
		sleep 5
		waited=$(( waited + 5 ))
		if [ $waited -ge 300 ]; then
			echo "  [$vm] ERROR: No internet after ${waited}s (is $con_vm NAT/dnsmasq up?)" >&2
			return 1
		fi
	done
	[ "$waited" -gt 0 ] && echo "  [$vm] Internet reachable (waited ${waited}s)"

	_vm_install_packages "$vm" "$user"
	_vm_dnf_update "$vm" "$user"
	_vm_wait_ssh "$vm" "$user"

	_vm_cleanup_caches "$vm" "$user"
	_vm_cleanup_podman "$vm" "$user"
	_vm_cleanup_home "$vm" "$user"
	_vm_setup_vmware_conf "$vm" "$user"
	_vm_setup_kvm_conf "$vm" "$user"
	_vm_remove_pull_secret "$vm" "$user"
	_vm_disable_proxy_autoload "$vm" "$user"
	_vm_create_test_user "$vm" "$user"
	_vm_set_aba_testing "$vm" "$user"
	_vm_disconnect_internet "$vm" "$user"

	echo "  [$vm] Verifying NTP sync (server: ${NTP_SERVER:-10.0.1.8}) ..."
	for ((_ntp=0; _ntp<20; _ntp++)); do
		if _essh "${user}@${vm}" -- "chronyc sources 2>/dev/null" | grep "^\^\*.*${NTP_SERVER:-10.0.1.8}"; then
			echo "  [$vm] NTP synced to ${NTP_SERVER:-10.0.1.8}."
			break
		fi
		sleep 5
	done

	_verify_dis_vm "$vm" "$user" "$con_vm"

	echo "  $vm configured."
}

_verify_dis_vm() {
	local vm="$1" user="$2" con_vm="$3"

	local pool_num="${vm#dis}"
	local _dis_vlan="${VM_CLONE_VLAN_IPS[$vm]%%/*}"
	local _con_vlan="${VM_CLONE_VLAN_IPS[$con_vm]%%/*}"
	local _domain
	_domain="$(pool_domain "$pool_num")"
	local _con_lab_ip
	_con_lab_ip="$(pool_con_ip "$pool_num")"
	local _ntp="${NTP_SERVER:-10.0.1.8}"
	local _base_domain="${VM_BASE_DOMAIN:-example.com}"
	local _tz="${TIMEZONE:-Asia/Singapore}"
	local _dis_lab_ip
	_dis_lab_ip="$(pool_dis_ip "$pool_num")"

	echo "  [$vm] Verifying ..."
	cat <<-VERIFY | _essh "${user}@${vm}" -- sudo bash
		set -e
		_fail() { printf "  \033[1;31mFAIL: %s\033[0m\n" "\$*"; exit 1; }

		# --- Identity ---
		hostname | grep -q "^${vm}\$" || _fail "hostname \$(hostname) != ${vm}"
		echo "  PASS: hostname ${vm}"

		timedatectl | grep -q "${_tz}" || _fail "timezone not ${_tz}"
		echo "  PASS: timezone ${_tz}"

		# --- Network (disconnected) ---
		ip addr show ens224.10 | grep -q "${_dis_vlan}" || _fail "VLAN IP ${_dis_vlan} not on ens224.10"
		echo "  PASS: VLAN IP ${_dis_vlan} on ens224.10"

		! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || _fail "internet still reachable (should be air-gapped)"
		echo "  PASS: no internet (disconnected)"

		for _iface in ens192 ens224 ens224.10; do
			_mtu=\$(ip link show \$_iface 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print \$2}')
			[ "\$_mtu" = "1500" ] || _fail "\$_iface MTU is \$_mtu (expected 1500)"
		done
		echo "  PASS: MTU 1500 on all interfaces"

		! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || _fail "internet still reachable"
		echo "  PASS: no internet (disconnected)"

		# --- VLAN connectivity ---
		_vlan_ok=0
		for _try in \$(seq 1 40); do
			if ping -c 1 -W 3 ${_con_vlan} > /dev/null 2>&1; then _vlan_ok=1; break; fi
			sleep 3
		done
		[ "\$_vlan_ok" -eq 1 ] || _fail "cannot ping con VLAN ${_con_vlan} after 120s"
		echo "  PASS: VLAN ping to ${con_vm} (${_con_vlan})"

		# --- Firewall / NAT ---
		systemctl is-active --quiet firewalld || _fail "firewalld not active"
		echo "  PASS: firewalld active"

		[ "\$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || _fail "ip_forward=0"
		echo "  PASS: ip_forward=1"

		firewall-cmd --query-masquerade > /dev/null || _fail "masquerade not enabled"
		echo "  PASS: masquerade enabled"

		# No test ports should be present on disN at baseline (keep 22/tcp if present)
		_stale=\$(firewall-cmd --list-ports | tr ' ' '\n' | grep -vE '^(22/tcp)?\$' || true)
		[ -z "\$_stale" ] || _fail "stale firewall ports: \$_stale"
		echo "  PASS: no stale firewall ports"

		# --- DNS resolution ---
		grep -q "nameserver ${_con_vlan}" /etc/resolv.conf || _fail "resolv.conf not ${_con_vlan}"
		echo "  PASS: resolv.conf -> ${_con_vlan}"

		test -f /etc/NetworkManager/conf.d/no-dns.conf || _fail "NM dns=none missing"
		echo "  PASS: NM dns=none"

		for _try in 1 2 3 4 5; do
			getent hosts ${con_vm}.${_base_domain} | grep -q "${_con_lab_ip}" && break
			[ "\$_try" -eq 5 ] && _fail "cannot resolve ${con_vm}.${_base_domain} -> ${_con_lab_ip}"
			sleep 5
		done
		echo "  PASS: DNS ${con_vm}.${_base_domain} -> ${_con_lab_ip}"

		for _try in 1 2 3 4 5; do
			getent hosts ${vm}.${_base_domain} | grep -q "${_dis_lab_ip}" && break
			[ "\$_try" -eq 5 ] && _fail "cannot resolve ${vm}.${_base_domain} -> ${_dis_lab_ip}"
			sleep 5
		done
		echo "  PASS: DNS ${vm}.${_base_domain} -> ${_dis_lab_ip}"

		# --- Lab connectivity ---
		for _try in 1 2 3 4 5; do
			ping -c 1 -W 3 ${_ntp} > /dev/null && break
			[ "\$_try" -eq 5 ] && _fail "lab server ${_ntp} unreachable via ens192"
			sleep 5
		done
		echo "  PASS: lab server ${_ntp} reachable"

		# --- Time ---
		systemctl is-active --quiet chronyd || _fail "chronyd not active"
		echo "  PASS: chronyd active"

		# --- SSH ---
		grep -q "^ClientAliveInterval" /etc/ssh/sshd_config || _fail "sshd ClientAliveInterval"
		echo "  PASS: sshd ClientAliveInterval"

		# --- Users / environment ---
		id testy > /dev/null 2>&1 || _fail "testy user missing"
		echo "  PASS: testy user exists"

		sudo -u testy sudo -n whoami 2>/dev/null | grep -q root || _fail "testy cannot sudo"
		echo "  PASS: testy sudo"

		test -f /home/${user}/.ssh/testy_rsa || _fail "testy_rsa key missing"
		echo "  PASS: testy_rsa key"

		sudo -u ${user} ssh -i /home/${user}/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null testy@localhost whoami < /dev/null 2>&1 | grep -q testy || _fail "testy SSH (local) failed"
		echo "  PASS: testy SSH (local)"

		grep -q "ABA_TESTING=1" /etc/environment || _fail "ABA_TESTING not set"
		echo "  PASS: ABA_TESTING=1"

		# --- Files ---
		test -s /home/${user}/.vmware.conf || _fail "vmware.conf missing"
		echo "  PASS: vmware.conf"
		test -s /root/.vmware.conf || _fail "root vmware.conf missing"
		echo "  PASS: root vmware.conf"
		if test -s /home/${user}/.kvm.conf; then
			echo "  PASS: kvm.conf"
			test -s /root/.kvm.conf || echo "  WARN: root kvm.conf missing"
		else
			echo "  SKIP: kvm.conf (not deployed)"
		fi

		! test -f /home/${user}/.pull-secret.json || _fail "pull-secret still exists"
		echo "  PASS: pull-secret removed"

		! grep -q "^source.*proxy-set" /home/${user}/.bashrc 2>/dev/null || _fail "proxy still in .bashrc"
		echo "  PASS: proxy disabled"

		command -v rsync > /dev/null || _fail "rsync not installed"
		echo "  PASS: rsync installed"

		# --- No running containers ---
		! podman ps -q 2>/dev/null | grep -q . || _fail "running containers (root)"
		echo "  PASS: no running containers (root)"
		! sudo -u ${user} podman ps -q 2>/dev/null | grep -q . || _fail "running containers (${user})"
		echo "  PASS: no running containers (${user})"

		# --- No service on registry port ---
		! ss -tlnp | grep -q ':8443 ' || _fail "port 8443 in use"
		echo "  PASS: port 8443 free"

		echo "  [$vm] All checks PASSED"
	VERIFY
}

# =============================================================================
# Normal flow: parse arguments
# =============================================================================

_POOLS=1
_POOL_SINGLE=""
_RECREATE_GOLDEN=""
_RECREATE_VMS=""
_VERIFY_ONLY=""
_YES=""
_POOLS_FILE="$_INFRA_DIR/pools.conf"

while [ $# -gt 0 ]; do
	case "$1" in
		-p|--pools)           _POOLS="$2"; shift 2 ;;
		--pool)               _POOL_SINGLE="$2"; shift 2 ;;
		-G|--recreate-golden) _RECREATE_GOLDEN=1; shift ;;
		-R|--recreate-vms)    _RECREATE_VMS=1; shift ;;
		--verify)             _VERIFY_ONLY=1; shift ;;
		-y|--yes)             _YES=1; shift ;;
		--pools-file)         _POOLS_FILE="$2"; shift 2 ;;
		*) echo "setup-infra.sh: unknown flag: $1" >&2; exit 1 ;;
	esac
done

_confirm() {
	local msg="$1"
	if [ -n "$_YES" ]; then
		echo "$msg Y (auto)"
		return 0
	fi
	read -r -p "$msg " answer
	case "${answer:-Y}" in
		[Yy]*) return 0 ;;
		*) return 1 ;;
	esac
}

# --- Parse per-pool overrides from pools.conf --------------------------------

declare -A _pool_datastores=()
declare -A _pool_folders=()

if [ -f "$_POOLS_FILE" ]; then
	while IFS= read -r _line; do
		[[ "$_line" =~ ^[[:space:]]*# ]] && continue
		[[ -z "${_line// }" ]] && continue
		local_pnum="" ; local_pds="" ; local_pfolder=""
		for _token in $_line; do
			case "$_token" in
				POOL_NUM=*)     local_pnum="${_token#POOL_NUM=}" ;;
				VM_DATASTORE=*) local_pds="${_token#VM_DATASTORE=}" ;;
				VC_FOLDER=*)    local_pfolder="${_token#VC_FOLDER=}" ;;
			esac
		done
		if [ -n "$local_pnum" ]; then
			[ -n "$local_pds" ] && _pool_datastores[$local_pnum]="$local_pds"
			[ -n "$local_pfolder" ] && _pool_folders[$local_pnum]="$local_pfolder"
		fi
	done < "$_POOLS_FILE"
fi

# --- Derived variables -------------------------------------------------------

_RHEL_VER="${INT_BASTION_RHEL_VER:-rhel8}"
_VM_TEMPLATE="${VM_TEMPLATES[$_RHEL_VER]:-aba-e2e-template-$_RHEL_VER}"
_GOLDEN_NAME="aba-e2e-golden-${_RHEL_VER}"
_BASE_FOLDER="${VC_FOLDER:-/Datacenter/vm/aba-e2e}"
# Golden VM always goes under aba-e2e/golden (even when VC_FOLDER is e.g. abatesting for pools)
_VC_PARENT="${_BASE_FOLDER%/*}"
_GOLDEN_FOLDER="${_VC_PARENT}/aba-e2e/golden"
_SNAPSHOT_NAME="pool-ready"
_LOG_DIR="$_INFRA_DIR/logs"

mkdir -p "$_LOG_DIR"

# =============================================================================
# --verify: run post-config checks on all pools, skip infra setup
# =============================================================================

if [ -n "$_VERIFY_ONLY" ]; then
	# --pool N verifies a single pool; --pools N verifies 1..N
	_ver_start=1
	_ver_end=$_POOLS
	if [ -n "$_POOL_SINGLE" ]; then
		_ver_start=$_POOL_SINGLE
		_ver_end=$_POOL_SINGLE
	fi

	echo ""
	echo "=== Verifying pool(s) ${_ver_start}..${_ver_end} ==="
	declare -a _ver_pids=() _ver_labels=() _ver_logs=()
	_ver_failed=0

	for (( i=_ver_start; i<=_ver_end; i++ )); do
		user="$VM_DEFAULT_USER"
		con_vm="con${i}"
		dis_vm="dis${i}"

		con_log="$_LOG_DIR/verify-${con_vm}.log"
		dis_log="$_LOG_DIR/verify-${dis_vm}.log"

		(
			set -e
			_verify_con_vm "$con_vm" "$user"
		) > "$con_log" 2>&1 &
		_ver_pids+=($!)
		_ver_labels+=("$con_vm")
		_ver_logs+=("$con_log")

		(
			set -e
			_verify_dis_vm "$dis_vm" "$user" "$con_vm"
		) > "$dis_log" 2>&1 &
		_ver_pids+=($!)
		_ver_labels+=("$dis_vm")
		_ver_logs+=("$dis_log")
	done

	# Print each VM's results as soon as it completes; track per-VM status
	declare -a _ver_results=()
	for idx in "${!_ver_pids[@]}"; do
		if wait "${_ver_pids[$idx]}"; then
			_ver_results+=("OK")
			echo ""
			echo "  --- ${_ver_labels[$idx]}: OK ---"
		else
			_ver_results+=("FAILED")
			_ver_failed=1
			echo ""
			printf "  --- ${_ver_labels[$idx]}: \033[1;31mFAILED\033[0m ---\n"
		fi
		cat "${_ver_logs[$idx]}"
	done

	# Summary table with failure reasons
	echo ""
	echo "=== Summary ==="
	for idx in "${!_ver_pids[@]}"; do
		if [ "${_ver_results[$idx]}" = "OK" ]; then
			printf "  %-12s OK\n" "${_ver_labels[$idx]}"
		else
			_reasons=$(sed 's/\x1b\[[0-9;]*m//g' "${_ver_logs[$idx]}" | grep -oP 'FAIL: \K.*' | paste -sd ', ' -)
			printf "  %-12s \033[1;31mFAILED\033[0m  %s\n" "${_ver_labels[$idx]}" "$_reasons"
		fi
	done
	echo ""

	if [ "$_ver_failed" -ne 0 ]; then
		printf "\033[1;31mFATAL: Verification failed on one or more pools\033[0m\n" >&2
		exit 1
	fi
	echo "=== All pools verified OK ==="
	exit 0
fi

# Enable trace for the full infra setup flow (not verify)
set -x

echo ""
echo "=== E2E Infrastructure Setup ==="
echo "  Pools: $_POOLS"
echo "  RHEL: $_RHEL_VER"
echo "  Golden: $_GOLDEN_NAME"
echo "  Template: $_VM_TEMPLATE"
echo "  Base folder: $_BASE_FOLDER"
echo "  Golden folder: $_GOLDEN_FOLDER"
echo ""

# =============================================================================
# Phase 0: Golden VM
# =============================================================================

_prepare_golden() {
	local snapshot_name="golden-ready"

	echo "=== Phase 0: Preparing golden VM ($_GOLDEN_NAME) ==="

	if [ -n "$_RECREATE_GOLDEN" ]; then
		echo "  -G/--recreate-golden: destroying existing golden VM ..."
		if vm_exists "$_GOLDEN_NAME"; then
			govc vm.power -off "$_GOLDEN_NAME" 2>/dev/null || true
			govc vm.destroy "$_GOLDEN_NAME"
		fi
	fi

	if vm_exists "$_GOLDEN_NAME"; then
		if govc snapshot.tree -vm "$_GOLDEN_NAME" 2>&1 | grep -q "$snapshot_name"; then
			echo "  Golden VM exists with '$snapshot_name' snapshot -- reusing."
			echo "  (Use -G/--recreate-golden to force rebuild)"
			echo "=== Phase 0 complete ==="
			return 0
		fi
		echo ""
		echo "  Golden VM '$_GOLDEN_NAME' exists but has no '$snapshot_name' snapshot."
		echo "  A previous golden build likely did not complete successfully."
		echo ""
		if _confirm "  Destroy and rebuild from template? (Y/n)"; then
			echo "  Destroying golden VM ..."
			govc vm.power -off "$_GOLDEN_NAME" 2>/dev/null || true
			govc vm.destroy "$_GOLDEN_NAME"
		else
			echo "  Aborted." >&2
			return 1
		fi
	fi

	echo "  Cloning from template: $_VM_TEMPLATE ..."

	govc folder.create "${_VC_PARENT}/aba-e2e" 2>/dev/null || true
	govc folder.create "$_GOLDEN_FOLDER" 2>/dev/null || true
	clone_vm "$_VM_TEMPLATE" "$_GOLDEN_NAME" "$_GOLDEN_FOLDER" || return 1

	local ip
	ip=$(govc vm.ip -wait 5m "$_GOLDEN_NAME") || return 1
	echo "  Golden VM IP: $ip"

	local user="$VM_DEFAULT_USER"
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_ssh_keys "$ip" "$user"      || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_setup_default_route "$ip" "$user" || return 1
	_vm_fix_proxy_noproxy "$ip" "$user"   || return 1
	_vm_disable_proxy_autoload "$ip" "$user"        || return 1
	_vm_setup_firewall "$ip" "$user"      || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_install_packages "$ip" "$user"    || return 1
	_vm_setup_time "$ip" "$user"          || return 1
	_vm_dnf_update "$ip" "$user"          || return 1
	_vm_wait_ssh "$ip" "$user"            || return 1
	_vm_cleanup_caches "$ip" "$user"      || return 1
	_vm_cleanup_podman "$ip" "$user"      || return 1
	_vm_cleanup_home "$ip" "$user"        || return 1
	_vm_create_test_user_and_key_on_host "$ip" "$user" || return 1
	_vm_set_aba_testing "$ip" "$user"     || return 1
	_vm_verify_golden "$ip" "$user"       || return 1

	_essh "${user}@${ip}" -- "sudo poweroff" || true
	sleep 10
	# Tolerate exit 1: VM may already be powered off (no redirect to avoid /dev/null permission issues)
	govc vm.power -off "$_GOLDEN_NAME" || true
	govc snapshot.create -vm "$_GOLDEN_NAME" "golden-ready" || return 1

	echo "  Golden VM created and snapshotted."
	echo "=== Phase 0 complete ==="
}

# Golden phase: output to terminal only (no separate log file)
_prepare_golden 2>&1
_r=$?
[ "$_r" -eq 0 ] || { echo "FATAL: Golden VM preparation failed" >&2; exit 1; }

# =============================================================================
# Phase 1: Clone conN and disN
# =============================================================================

echo ""
echo "=== Phase 1: Ensure conN/disN VMs (pools 1..$_POOLS) ==="

if ! govc snapshot.tree -vm "$_GOLDEN_NAME" | grep "golden-ready"; then
	echo "FATAL: golden VM '$_GOLDEN_NAME' has no 'golden-ready' snapshot -- cannot clone pool VMs" >&2
	exit 1
fi

_vm_needs_clone() {
	local vm_name="$1"
	if [ -n "$_RECREATE_VMS" ]; then
		echo "recreate"
		return
	fi
	if ! vm_exists "$vm_name" > /dev/null; then
		echo "missing"
		return
	fi
	local user="$VM_DEFAULT_USER"
	local host="${vm_name}.${VM_BASE_DOMAIN:-example.com}"
	if _essh -o BatchMode=yes -o ConnectTimeout=10 "${user}@${host}" -- "date" > /dev/null; then
		echo "ok"
		return
	fi
	if govc snapshot.tree -vm "$vm_name" | grep "$_SNAPSHOT_NAME" > /dev/null; then
		echo "revert"
		return
	fi
	echo "broken"
}

_clone_failed=0

# Stagger clones: all conN first, then all disN, to reduce concurrent vCenter I/O.
for prefix in con dis; do
	declare -a _clone_pids=()
	declare -a _clone_labels=()

	echo "  --- Cloning ${prefix}1..${prefix}${_POOLS} ---"

	for (( i=1; i<=_POOLS; i++ )); do
		pool_folder="${_pool_folders[$i]:-${_BASE_FOLDER}/pool${i}}"
		pool_ds="${_pool_datastores[$i]:-$VM_DATASTORE}"
		pool_log="$_LOG_DIR/create-pool${i}.log"
		> "$pool_log"

		govc folder.create "$pool_folder" 2>/dev/null || true

		vm_name="${prefix}${i}"
		status=$(_vm_needs_clone "$vm_name")

		case "$status" in
			ok)
				echo "  $vm_name: exists + SSH OK -- reusing"
				;;
		revert)
			echo "  $vm_name: exists but SSH failed -- reverting to $_SNAPSHOT_NAME"
			govc snapshot.revert -vm "$vm_name" "$_SNAPSHOT_NAME" || { echo "ERROR: revert $vm_name failed" >&2; _clone_failed=1; continue; }
			govc vm.power -on "$vm_name" 2>/dev/null || true
			# After revert, re-add the bastion's SSH key to the user account.
			# The pool-ready snapshot only has root's authorized_keys; the user
			# key was added later.  Wait for SSH then fix user keys.
			_revert_host="${vm_name}.${VM_BASE_DOMAIN:-example.com}"
			_revert_user="$VM_DEFAULT_USER"
			echo "  $vm_name: waiting for SSH after revert ..."
			if _vm_wait_ssh "$_revert_host" "$_revert_user" 2>/dev/null \
				|| _vm_wait_ssh "$_revert_host" "root" 2>/dev/null; then
				_vm_setup_ssh_keys "$_revert_host" "$_revert_user" 2>/dev/null \
					|| echo "  $vm_name: WARNING: could not set up SSH keys after revert"
				# Remove stale firewall ports that may have been baked into the snapshot
				_vm_setup_firewall "$_revert_host" "$_revert_user" 2>/dev/null \
					|| echo "  $vm_name: WARNING: firewall reset failed after revert"
			else
				echo "  $vm_name: WARNING: SSH still down after revert"
			fi
			;;
	broken)
			echo "  $vm_name: broken (SSH down, no '$_SNAPSHOT_NAME' snapshot)"
			if _confirm "  Replace $vm_name? (Y/n)"; then
				govc vm.power -off "$vm_name" 2>/dev/null || true
				govc vm.destroy "$vm_name" || true
				VM_DATASTORE="$pool_ds" clone_vm "$_GOLDEN_NAME" "$vm_name" "$pool_folder" "golden-ready" >> "$pool_log" 2>&1 &
				_clone_pids+=($!)
				_clone_labels+=("clone $vm_name (was broken)")
			else
				echo "  Skipping $vm_name."
				_clone_failed=1
			fi
			;;
			missing|recreate)
				echo "  $vm_name: $status -- cloning from $_GOLDEN_NAME ..."
				if vm_exists "$vm_name"; then
					govc vm.power -off "$vm_name" 2>/dev/null || true
					govc vm.destroy "$vm_name" || true
				fi
				VM_DATASTORE="$pool_ds" clone_vm "$_GOLDEN_NAME" "$vm_name" "$pool_folder" "golden-ready" >> "$pool_log" 2>&1 &
				_clone_pids+=($!)
				_clone_labels+=("clone $vm_name")
				;;
		esac
	done

	for idx in "${!_clone_pids[@]}"; do
		if wait "${_clone_pids[$idx]}"; then
			echo "  OK: ${_clone_labels[$idx]}"
		else
			echo "  FAILED: ${_clone_labels[$idx]} (exit=$?)" >&2
			_clone_failed=1
		fi
	done

	unset _clone_pids _clone_labels
done

if [ "$_clone_failed" -ne 0 ]; then
	echo "FATAL: Some VM clones failed" >&2
	exit 1
fi

echo "=== Phase 1 complete ==="

# =============================================================================
# Phase 2: Configure VMs (parallel per pool)
# =============================================================================

echo ""
echo "=== Phase 2: Configure VMs ==="

declare -a _cfg_pids=()
declare -a _cfg_labels=()
declare -a _cfg_logs=()
_cfg_failed=0

for (( i=1; i<=_POOLS; i++ )); do
	pool_folder="${_pool_folders[$i]:-${_BASE_FOLDER}/pool${i}}"
	con_log="$_LOG_DIR/create-pool${i}-con.log"
	dis_log="$_LOG_DIR/create-pool${i}-dis.log"
	user="$VM_DEFAULT_USER"
	con_vm="con${i}"
	dis_vm="dis${i}"

	if govc snapshot.tree -vm "$con_vm" 2>&1 | grep -q "$_SNAPSHOT_NAME" \
	   && govc snapshot.tree -vm "$dis_vm" 2>&1 | grep -q "$_SNAPSHOT_NAME"; then
		if [ -z "$_RECREATE_VMS" ]; then
			echo "  $con_vm + $dis_vm: pool-ready snapshot exists -- skipping config"
			continue
		fi
	fi

	echo "  Configuring pool $i ($con_vm + $dis_vm) ..."
	echo "    Logs: $con_log  |  $dis_log"

	# con then dis sequentially within each pool (dis needs con's dnsmasq),
	# but pools run in parallel with each other.
	(
		set -e
		export VC_FOLDER="$pool_folder"
		_configure_con_vm "$con_vm" "$user" >> "$con_log" 2>&1
		_configure_dis_vm "$dis_vm" "$user" "$con_vm" >> "$dis_log" 2>&1
	) &
	_cfg_pids+=($!)
	_cfg_labels+=("configure pool $i ($con_vm + $dis_vm)")
	_cfg_logs+=("$con_log" "$dis_log")
done

# While background config jobs run, tail their logs so the user sees progress
_tail_pid=""
if [ ${#_cfg_pids[@]} -gt 0 ] && [ ${#_cfg_logs[@]} -gt 0 ] && [ -t 1 ]; then
	tail -f "${_cfg_logs[@]}" 2>/dev/null &
	_tail_pid=$!
fi

for idx in "${!_cfg_pids[@]}"; do
	if wait "${_cfg_pids[$idx]}"; then
		echo "  OK: ${_cfg_labels[$idx]}"
	else
		echo "  FAILED: ${_cfg_labels[$idx]} (exit=$?)" >&2
		_cfg_failed=1
	fi
done

[ -n "$_tail_pid" ] && kill "$_tail_pid" 2>/dev/null || true

if [ "$_cfg_failed" -ne 0 ]; then
	echo "FATAL: VM configuration failed" >&2
	exit 1
fi

echo "=== Phase 2 complete ==="

# =============================================================================
# Phase 3: Create pool-ready snapshots
# =============================================================================

echo ""
echo "=== Phase 3: Create pool-ready snapshots ==="

for (( i=1; i<=_POOLS; i++ )); do
	for prefix in con dis; do
		vm_name="${prefix}${i}"
		if govc snapshot.tree -vm "$vm_name" 2>&1 | grep -q "$_SNAPSHOT_NAME"; then
			if [ -z "$_RECREATE_VMS" ]; then
				echo "  $vm_name: $_SNAPSHOT_NAME already exists -- skipping"
				continue
			fi
		fi
		echo "  Shutting down $vm_name before snapshot ..."
		govc vm.power -s -force "$vm_name" || true
		sleep 15
		echo "  Creating snapshot '$_SNAPSHOT_NAME' on $vm_name ..."
		govc snapshot.create -vm "$vm_name" "$_SNAPSHOT_NAME" || { echo "ERROR: snapshot $vm_name failed" >&2; exit 1; }
		echo "  Powering on $vm_name ..."
		govc vm.power -on "$vm_name" || true
	done
done

echo "=== Phase 3 complete ==="

echo ""
echo "=== Infrastructure ready: $_POOLS pool(s) ==="
echo ""
