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
set -x
# Show file:line before each traced command (no [ ] so trace is never parsed as a command)
PS4='+ ${BASH_SOURCE##*/}:${LINENO} '

_INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ABA_ROOT="$(cd "$_INFRA_DIR/../.." && pwd)"

# Source libraries
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

		# --- Identity ---
		hostname | grep "^${vm}\$" || { echo "FAIL: hostname \$(hostname) != ${vm}"; exit 1; }
		echo "  PASS: hostname ${vm}"

		timedatectl | grep "${_tz}" || { echo "FAIL: timezone not ${_tz}"; exit 1; }
		echo "  PASS: timezone ${_tz}"

		# --- Network ---
		ip addr show ens224.10 | grep "${_con_vlan}" || { echo "FAIL: VLAN IP ${_con_vlan} not on ens224.10"; exit 1; }
		echo "  PASS: VLAN IP ${_con_vlan} on ens224.10"

		ip route | grep "^default.*ens256" || { echo "FAIL: default route not via ens256"; exit 1; }
		echo "  PASS: default route via ens256"

		ip link show ens192 | grep "mtu 9000" || { echo "FAIL: ens192 mtu != 9000"; exit 1; }
		echo "  PASS: ens192 mtu 9000"

		ip link show ens224 | grep "mtu 9000" || { echo "FAIL: ens224 mtu != 9000"; exit 1; }
		echo "  PASS: ens224 mtu 9000"

		nmcli -g ipv4.ignore-auto-dns connection show ens256 | grep yes || { echo "FAIL: ens256 ignore-auto-dns"; exit 1; }
		echo "  PASS: ens256 ignore-auto-dns"

		# --- Firewall / NAT ---
		systemctl is-active --quiet firewalld || { echo "FAIL: firewalld not active"; exit 1; }
		echo "  PASS: firewalld active"

		[ "\$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || { echo "FAIL: ip_forward=0"; exit 1; }
		echo "  PASS: ip_forward=1"

		firewall-cmd --query-masquerade > /dev/null || { echo "FAIL: masquerade not enabled"; exit 1; }
		echo "  PASS: masquerade enabled"

		firewall-cmd --list-services | grep dns || { echo "FAIL: dns not in firewall"; exit 1; }
		echo "  PASS: firewall dns service"

		# --- DNS / dnsmasq ---
		systemctl is-active --quiet dnsmasq || { echo "FAIL: dnsmasq not active"; exit 1; }
		echo "  PASS: dnsmasq active"

		dig +short google.com @127.0.0.1 | head -1 | grep . || { echo "FAIL: DNS @127.0.0.1 -> google.com"; exit 1; }
		echo "  PASS: DNS @127.0.0.1 -> google.com"

		dig +short google.com @${_con_vlan} | head -1 | grep . || { echo "FAIL: DNS @${_con_vlan} -> google.com"; exit 1; }
		echo "  PASS: DNS @${_con_vlan} -> google.com (disN path)"

		grep "nameserver 127.0.0.1" /etc/resolv.conf || { echo "FAIL: resolv.conf not 127.0.0.1"; exit 1; }
		echo "  PASS: resolv.conf -> 127.0.0.1"

		test -f /etc/NetworkManager/conf.d/no-dns.conf || { echo "FAIL: NM dns=none missing"; exit 1; }
		echo "  PASS: NM dns=none"

		# --- Time ---
		systemctl is-active --quiet chronyd || { echo "FAIL: chronyd not active"; exit 1; }
		echo "  PASS: chronyd active"

		ping -c 1 -W 3 ${_ntp} > /dev/null || { echo "FAIL: NTP server ${_ntp} unreachable"; exit 1; }
		echo "  PASS: NTP server ${_ntp} reachable"

		# --- SSH ---
		grep "^ClientAliveInterval" /etc/ssh/sshd_config || { echo "FAIL: sshd ClientAliveInterval"; exit 1; }
		echo "  PASS: sshd ClientAliveInterval"

		# --- Users / environment ---
		id testy > /dev/null 2>&1 || { echo "FAIL: testy user missing"; exit 1; }
		echo "  PASS: testy user exists"

		sudo -u testy sudo -n whoami | grep root || { echo "FAIL: testy cannot sudo"; exit 1; }
		echo "  PASS: testy sudo"

		test -f /home/${user}/.ssh/testy_rsa || { echo "FAIL: testy_rsa key missing"; exit 1; }
		echo "  PASS: testy_rsa key"

		sudo -u ${user} ssh -i /home/${user}/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null testy@localhost whoami 2>&1 | grep testy || { echo "FAIL: testy SSH (local) failed"; exit 1; }
		echo "  PASS: testy SSH (local)"

		grep "ABA_TESTING=1" /etc/environment || { echo "FAIL: ABA_TESTING not set"; exit 1; }
		echo "  PASS: ABA_TESTING=1"

		# --- Installed software (check as the owning user, not root) ---
		test -x /home/${user}/bin/aba || { echo "FAIL: aba not installed"; exit 1; }
		echo "  PASS: aba installed"

		test -d /home/${user}/aba || { echo "FAIL: ~/aba not present"; exit 1; }
		echo "  PASS: ~/aba exists"

		# --- Files ---
		test -s /home/${user}/.vmware.conf || { echo "FAIL: vmware.conf missing"; exit 1; }
		echo "  PASS: vmware.conf"

		# --- Podman clean (all users) ---
		! podman images -q 2>/dev/null | grep . || { echo "FAIL: stale podman images (root)"; exit 1; }
		echo "  PASS: no podman images (root)"
		! sudo -u ${user} podman images -q 2>/dev/null | grep . || { echo "FAIL: stale podman images (${user})"; exit 1; }
		echo "  PASS: no podman images (${user})"
		! sudo -u testy podman images -q 2>/dev/null | grep . || { echo "FAIL: stale podman images (testy)"; exit 1; }
		echo "  PASS: no podman images (testy)"

		# --- No running containers ---
		! podman ps -q 2>/dev/null | grep . || { echo "FAIL: running containers (root)"; exit 1; }
		echo "  PASS: no running containers (root)"
		! sudo -u ${user} podman ps -q 2>/dev/null | grep . || { echo "FAIL: running containers (${user})"; exit 1; }
		echo "  PASS: no running containers (${user})"

		# --- No service on registry port ---
		! ss -tlnp | grep ':8443 ' || { echo "FAIL: port 8443 in use"; exit 1; }
		echo "  PASS: port 8443 free"

		echo "  [$vm] All verifications PASSED."
	VERIFY
}

_configure_con_vm() {
	local vm="$1" user="$2"

	_vm_wait_ssh "$vm" "$user"
	_vm_setup_network "$vm" "$user" "$vm"
	_vm_setup_firewall "$vm" "$user"
	_vm_setup_dnsmasq "$vm" "$user" "$vm"
	_vm_dnf_update "$vm" "$user"
	_vm_wait_ssh "$vm" "$user"
	_vm_cleanup_caches "$vm" "$user"
	_vm_cleanup_podman "$vm" "$user"
	_vm_cleanup_home "$vm" "$user"
	_vm_setup_vmware_conf "$vm" "$user"
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

	_vm_dnf_update "$vm" "$user"
	_vm_wait_ssh "$vm" "$user"

	_vm_cleanup_caches "$vm" "$user"
	_vm_cleanup_podman "$vm" "$user"
	_vm_cleanup_home "$vm" "$user"
	_vm_setup_vmware_conf "$vm" "$user"
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

		# --- Identity ---
		hostname | grep "^${vm}\$" || { echo "FAIL: hostname \$(hostname) != ${vm}"; exit 1; }
		echo "  PASS: hostname ${vm}"

		timedatectl | grep "${_tz}" || { echo "FAIL: timezone not ${_tz}"; exit 1; }
		echo "  PASS: timezone ${_tz}"

		# --- Network (disconnected) ---
		ip addr show ens224.10 | grep "${_dis_vlan}" || { echo "FAIL: VLAN IP ${_dis_vlan} not on ens224.10"; exit 1; }
		echo "  PASS: VLAN IP ${_dis_vlan} on ens224.10"

		ip link show ens256 | grep "state DOWN" || { echo "FAIL: ens256 not DOWN"; exit 1; }
		echo "  PASS: ens256 DOWN"

		! ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1 || { echo "FAIL: internet still reachable"; exit 1; }
		echo "  PASS: no internet (disconnected)"

		ip link show ens192 | grep "mtu 9000" || { echo "FAIL: ens192 mtu != 9000"; exit 1; }
		echo "  PASS: ens192 mtu 9000"

		ip link show ens224 | grep "mtu 9000" || { echo "FAIL: ens224 mtu != 9000"; exit 1; }
		echo "  PASS: ens224 mtu 9000"

		# --- VLAN connectivity ---
		_vlan_ok=0
		for _try in \$(seq 1 40); do
			if ping -c 1 -W 3 ${_con_vlan} > /dev/null 2>&1; then _vlan_ok=1; break; fi
			sleep 3
		done
		[ "\$_vlan_ok" -eq 1 ] || { echo "FAIL: cannot ping con VLAN ${_con_vlan} after 120s"; exit 1; }
		echo "  PASS: VLAN ping to ${con_vm} (${_con_vlan})"

		# --- Firewall / NAT ---
		systemctl is-active --quiet firewalld || { echo "FAIL: firewalld not active"; exit 1; }
		echo "  PASS: firewalld active"

		[ "\$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] || { echo "FAIL: ip_forward=0"; exit 1; }
		echo "  PASS: ip_forward=1"

		firewall-cmd --query-masquerade > /dev/null || { echo "FAIL: masquerade not enabled"; exit 1; }
		echo "  PASS: masquerade enabled"

		# --- DNS resolution ---
		grep "nameserver ${_con_vlan}" /etc/resolv.conf || { echo "FAIL: resolv.conf not ${_con_vlan}"; exit 1; }
		echo "  PASS: resolv.conf -> ${_con_vlan}"

		test -f /etc/NetworkManager/conf.d/no-dns.conf || { echo "FAIL: NM dns=none missing"; exit 1; }
		echo "  PASS: NM dns=none"

		getent hosts ${con_vm}.${_base_domain} | grep "${_con_lab_ip}" || { echo "FAIL: cannot resolve ${con_vm}.${_base_domain} -> ${_con_lab_ip}"; exit 1; }
		echo "  PASS: DNS ${con_vm}.${_base_domain} -> ${_con_lab_ip}"

		getent hosts ${vm}.${_base_domain} | grep "${_dis_lab_ip}" || { echo "FAIL: cannot resolve ${vm}.${_base_domain} -> ${_dis_lab_ip}"; exit 1; }
		echo "  PASS: DNS ${vm}.${_base_domain} -> ${_dis_lab_ip}"

		# --- Lab connectivity ---
		ping -c 1 -W 3 ${_ntp} > /dev/null || { echo "FAIL: lab server ${_ntp} unreachable via ens192"; exit 1; }
		echo "  PASS: lab server ${_ntp} reachable"

		# --- Time ---
		systemctl is-active --quiet chronyd || { echo "FAIL: chronyd not active"; exit 1; }
		echo "  PASS: chronyd active"

		# --- SSH ---
		grep "^ClientAliveInterval" /etc/ssh/sshd_config || { echo "FAIL: sshd ClientAliveInterval"; exit 1; }
		echo "  PASS: sshd ClientAliveInterval"

		# --- Users / environment ---
		id testy > /dev/null 2>&1 || { echo "FAIL: testy user missing"; exit 1; }
		echo "  PASS: testy user exists"

		sudo -u testy sudo -n whoami | grep root || { echo "FAIL: testy cannot sudo"; exit 1; }
		echo "  PASS: testy sudo"

		test -f /home/${user}/.ssh/testy_rsa || { echo "FAIL: testy_rsa key missing"; exit 1; }
		echo "  PASS: testy_rsa key"

		sudo -u ${user} ssh -i /home/${user}/.ssh/testy_rsa -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null testy@localhost whoami 2>&1 | grep testy || { echo "FAIL: testy SSH (local) failed"; exit 1; }
		echo "  PASS: testy SSH (local)"

		grep "ABA_TESTING=1" /etc/environment || { echo "FAIL: ABA_TESTING not set"; exit 1; }
		echo "  PASS: ABA_TESTING=1"

		# --- Files ---
		test -s /home/${user}/.vmware.conf || { echo "FAIL: vmware.conf missing"; exit 1; }
		echo "  PASS: vmware.conf"

		! test -f /home/${user}/.pull-secret.json || { echo "FAIL: pull-secret still exists"; exit 1; }
		echo "  PASS: pull-secret removed"

		! grep "^source.*proxy-set" /home/${user}/.bashrc 2>/dev/null || { echo "FAIL: proxy still in .bashrc"; exit 1; }
		echo "  PASS: proxy disabled"

		# --- Podman clean (all users) ---
		! podman images -q 2>/dev/null | grep . || { echo "FAIL: stale podman images (root)"; exit 1; }
		echo "  PASS: no podman images (root)"
		! sudo -u ${user} podman images -q 2>/dev/null | grep . || { echo "FAIL: stale podman images (${user})"; exit 1; }
		echo "  PASS: no podman images (${user})"
		! sudo -u testy podman images -q 2>/dev/null | grep . || { echo "FAIL: stale podman images (testy)"; exit 1; }
		echo "  PASS: no podman images (testy)"

		# --- No running containers ---
		! podman ps -q 2>/dev/null | grep . || { echo "FAIL: running containers (root)"; exit 1; }
		echo "  PASS: no running containers (root)"
		! sudo -u ${user} podman ps -q 2>/dev/null | grep . || { echo "FAIL: running containers (${user})"; exit 1; }
		echo "  PASS: no running containers (${user})"

		# --- No service on registry port ---
		! ss -tlnp | grep ':8443 ' || { echo "FAIL: port 8443 in use"; exit 1; }
		echo "  PASS: port 8443 free"

		echo "  [$vm] All verifications PASSED."
	VERIFY
}

# =============================================================================
# Normal flow: parse arguments
# =============================================================================

_POOLS=1
_RECREATE_GOLDEN=""
_RECREATE_VMS=""
_VERIFY_ONLY=""
_YES=""
_POOLS_FILE="$_INFRA_DIR/pools.conf"

while [ $# -gt 0 ]; do
	case "$1" in
		-p|--pools)           _POOLS="$2"; shift 2 ;;
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
	echo ""
	echo "=== Verifying pools 1..$_POOLS ==="
	declare -a _ver_pids=() _ver_labels=() _ver_logs=()
	_ver_failed=0

	for (( i=1; i<=_POOLS; i++ )); do
		user="$VM_DEFAULT_USER"
		con_vm="con${i}"
		dis_vm="dis${i}"
		ver_log="$_LOG_DIR/verify-pool${i}.log"
		echo "  Pool $i: $con_vm + $dis_vm  (log: $ver_log)"

		(
			set -e
			_verify_con_vm "$con_vm" "$user"
		) > "$ver_log" 2>&1 &
		_ver_pids+=($!)
		_ver_labels+=("verify $con_vm")
		_ver_logs+=("$ver_log")

		(
			set -e
			_verify_dis_vm "$dis_vm" "$user" "$con_vm"
		) >> "$ver_log" 2>&1 &
		_ver_pids+=($!)
		_ver_labels+=("verify $dis_vm")
	done

	_tail_pid=""
	if [ ${#_ver_logs[@]} -gt 0 ] && [ -t 1 ]; then
		tail -f "${_ver_logs[@]}" 2>/dev/null &
		_tail_pid=$!
	fi

	for idx in "${!_ver_pids[@]}"; do
		if wait "${_ver_pids[$idx]}"; then
			echo "  OK:     ${_ver_labels[$idx]}"
		else
			echo "  FAILED: ${_ver_labels[$idx]}" >&2
			_ver_failed=1
		fi
	done

	[ -n "$_tail_pid" ] && kill "$_tail_pid" 2>/dev/null || true

	if [ "$_ver_failed" -ne 0 ]; then
		echo "FATAL: Verification failed on one or more pools" >&2
		exit 1
	fi
	echo "=== All pools verified OK ==="
	exit 0
fi

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
		if govc snapshot.tree -vm "$_GOLDEN_NAME" 2>/dev/null | grep "$snapshot_name"; then
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

	if govc snapshot.tree -vm "$con_vm" 2>/dev/null | grep "$_SNAPSHOT_NAME" \
	   && govc snapshot.tree -vm "$dis_vm" 2>/dev/null | grep "$_SNAPSHOT_NAME"; then
		if [ -z "$_RECREATE_VMS" ]; then
			echo "  $con_vm + $dis_vm: pool-ready snapshot exists -- skipping config"
			continue
		fi
	fi

	echo "  Configuring pool $i ($con_vm + $dis_vm) ..."
	echo "    Logs: $con_log  |  $dis_log"

	(
		set -e
		export VC_FOLDER="$pool_folder"
		_configure_con_vm "$con_vm" "$user"
	) >> "$con_log" 2>&1 &
	_cfg_pids+=($!)
	_cfg_labels+=("configure $con_vm")

	(
		set -e
		export VC_FOLDER="$pool_folder"
		_configure_dis_vm "$dis_vm" "$user" "$con_vm"
	) >> "$dis_log" 2>&1 &
	_cfg_pids+=($!)
	_cfg_labels+=("configure $dis_vm")
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
		if govc snapshot.tree -vm "$vm_name" 2>/dev/null | grep "$_SNAPSHOT_NAME"; then
			if [ -z "$_RECREATE_VMS" ]; then
				echo "  $vm_name: $_SNAPSHOT_NAME already exists -- skipping"
				continue
			fi
		fi
		echo "  Creating snapshot '$_SNAPSHOT_NAME' on $vm_name ..."
		govc snapshot.create -vm "$vm_name" "$_SNAPSHOT_NAME" || { echo "ERROR: snapshot $vm_name failed" >&2; exit 1; }
	done
done

echo "=== Phase 3 complete ==="

echo ""
echo "=== Infrastructure ready: $_POOLS pool(s) ==="
echo ""
