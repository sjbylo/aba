#!/bin/bash
# =============================================================================
# E2E Test Framework -- Configuration Helpers
# =============================================================================
# Functions to programmatically generate aba.conf, mirror.conf, cluster.conf,
# and vmware.conf for test suites.
# =============================================================================

_E2E_LIB_DIR_CH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Pool-Aware Helpers -----------------------------------------------------
#
# Resolve per-pool values from the POOL_* arrays in config.env.
# All functions default to POOL_NUM=1 if not set.
#
# Only ONE cluster type (SNO, compact, or standard) runs per pool at a time,
# so all types share the same static IPs within a pool:
#   - pool_node_ip   = SNO node / rendezvous node (.x2)
#   - pool_api_vip   = API VIP (.x3) -- for SNO, same as node_ip
#   - pool_apps_vip  = APPS VIP (.x4) -- for SNO, same as node_ip
#

# Get the base domain for a pool: pool_domain [POOL_NUM]
pool_domain() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_DOMAIN[$p]:-p${p}.example.com}"
}

# Get the cluster node / SNO / rendezvous IP: pool_node_ip [POOL_NUM]
pool_node_ip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_NODE_IP[$p]:-${POOL_SUBNET:-10.0.2}.$((p * 10 + 2))}"
}

# Get the API VIP: pool_api_vip [POOL_NUM]
pool_api_vip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_API_VIP[$p]:-${POOL_SUBNET:-10.0.2}.$((p * 10 + 3))}"
}

# Get the APPS/Ingress VIP: pool_apps_vip [POOL_NUM]
pool_apps_vip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_APPS_VIP[$p]:-${POOL_SUBNET:-10.0.2}.$((p * 10 + 4))}"
}

# Get the machine network: pool_machine_network [POOL_NUM]
pool_machine_network() {
    echo "${POOL_MACHINE_NETWORK:-10.0.0.0/20}"
}

# Get the connected bastion's lab IP (ens192): pool_con_ip [POOL_NUM]
# This is the .x0 address in the pool's decade: 10.0.2.(N*10)
pool_con_ip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_SUBNET:-10.0.2}.$((p * 10))"
}

# Get the disconnected bastion's lab IP (ens192): pool_dis_ip [POOL_NUM]
# This is the .x1 address in the pool's decade: 10.0.2.(N*10+1)
pool_dis_ip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_SUBNET:-10.0.2}.$((p * 10 + 1))"
}

# Get the registry hostname for a pool: pool_registry_host [POOL_NUM]
pool_registry_host() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "registry.$(pool_domain "$p")"
}

# Get the DNS server IP for a pool (= conN's lab IP, running dnsmasq)
pool_dns_server() {
    pool_con_ip "$@"
}

# Convenience aliases -- all cluster types share the same IPs.
# SNO uses node_ip for everything; compact/standard use node_ip + VIPs.
pool_sno_ip()             { pool_node_ip "$@"; }
pool_compact_api_vip()    { pool_api_vip "$@"; }
pool_compact_apps_vip()   { pool_apps_vip "$@"; }
pool_standard_api_vip()   { pool_api_vip "$@"; }
pool_standard_apps_vip()  { pool_apps_vip "$@"; }

# --- Pool-Unique Cluster Names ------------------------------------------------
# When parallel pools create VMs, names must not collide in vCenter.
# Every pool always appends the pool number: sno1, compact1, sno-vlan2, etc.
#
# Usage: pool_cluster_name <base_type> [POOL_NUM]
#   e.g. pool_cluster_name sno        -> "sno1"        (pool 1)
#        pool_cluster_name sno 2      -> "sno2"        (pool 2)
#        pool_cluster_name sno-vlan 1 -> "sno-vlan1"   (pool 1)
pool_cluster_name() {
    local base="$1"
    local p="${2:-${POOL_NUM:-1}}"
    echo "${base}${p}"
}

# Get starting IP for a cluster type: pool_starting_ip <sno|compact|standard> [POOL_NUM]
pool_starting_ip() {
    local ctype="$1"
    local p="${2:-${POOL_NUM:-1}}"
    # All types share pool_node_ip as the starting/rendezvous IP
    pool_node_ip "$p"
}

# Get the VLAN node IP for cluster-on-VLAN tests: pool_vlan_node_ip [POOL_NUM]
pool_vlan_node_ip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_VLAN_NODE_IP[$p]:-10.10.20.$((200 + p))}"
}

# Get the VLAN machine network: pool_vlan_network
pool_vlan_network() {
    echo "${POOL_VLAN_NETWORK:-10.10.20.0/24}"
}

# Get the VLAN API VIP for compact/standard on VLAN: pool_vlan_api_vip [POOL_NUM]
pool_vlan_api_vip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_VLAN_API_VIP[$p]:-10.10.20.$((210 + p))}"
}

# Get the VLAN APPS VIP for compact/standard on VLAN: pool_vlan_apps_vip [POOL_NUM]
pool_vlan_apps_vip() {
    local p="${1:-${POOL_NUM:-1}}"
    echo "${POOL_VLAN_APPS_VIP[$p]:-10.10.20.$((220 + p))}"
}

# Get the VLAN gateway (= disN's VLAN IP, stripped of /prefix): pool_vlan_gateway [POOL_NUM]
pool_vlan_gateway() {
    local p="${1:-${POOL_NUM:-1}}"
    local dis_vlan="${VM_CLONE_VLAN_IPS[dis${p}]:-10.10.20.$((p * 2))/24}"
    # Strip the /prefix to get just the IP
    echo "${dis_vlan%%/*}"
}

# SSH target for the connected bastion: pool_connected_bastion [POOL_NUM]
# Returns user@conN.domain suitable for ssh/rsync.
pool_connected_bastion() {
    local p="${1:-${POOL_NUM:-1}}"
    local user="${DIS_SSH_USER:-steve}"
    echo "${user}@con${p}.${VM_BASE_DOMAIN:-example.com}"
}

# SSH target for the internal (air-gapped) bastion: pool_internal_bastion [POOL_NUM]
# Returns user@disN.domain suitable for ssh/rsync.
pool_internal_bastion() {
    local p="${1:-${POOL_NUM:-1}}"
    local user="${DIS_SSH_USER:-steve}"
    echo "${user}@dis${p}.${VM_BASE_DOMAIN:-example.com}"
}

# --- gen_aba_conf -----------------------------------------------------------
#
# Generate a test aba.conf in the current directory (must be aba root).
# Uses environment variables from config.env / CLI / pool overrides.
#
# Options:
#   --channel CHANNEL      Override channel (default: $TEST_CHANNEL)
#   --version VERSION      Override version (default: $OCP_VERSION)
#   --platform PLATFORM    Override platform (default: vmw)
#   --op-sets OPSETS       Set operator sets (default: empty)
#   --ops OPS              Set individual operators (default: empty)
#   --ask true|false       Set ask mode (default: false for testing)
#
gen_aba_conf() {
    local channel="${TEST_CHANNEL:-stable}"
    local version="${OCP_VERSION:-p}"
    local platform="vmw"
    local op_sets=""
    local ops=""
    local ask="false"
    local ntp_servers="${NTP_SERVERS:-10.0.1.8,2.rhel.pool.ntp.org}"
    local domain="${DOMAIN:-$(pool_domain)}"
    local machine_network="${MACHINE_NETWORK:-$(pool_machine_network)}"
    local dns_servers="${DNS_SERVERS:-$(pool_dns_server)}"
    local next_hop="${NEXT_HOP:-10.0.1.1}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --channel)  channel="$2"; shift 2 ;;
            --version)  version="$2"; shift 2 ;;
            --platform) platform="$2"; shift 2 ;;
            --op-sets)  op_sets="$2"; shift 2 ;;
            --ops)      ops="$2"; shift 2 ;;
            --ask)      ask="$2"; shift 2 ;;
            *) echo "gen_aba_conf: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    # Resolve version shorthand
    local ocp_version=""
    case "$version" in
        l|latest)   ocp_version="" ;;  # empty = let aba pick latest
        p|previous) ocp_version="" ;;  # handled by aba channel logic
        *)          ocp_version="$version" ;;
    esac

    cat > aba.conf <<-EOF
	# Auto-generated aba.conf for E2E testing
	ocp_channel=$channel
	ocp_version=$ocp_version
	platform=$platform
	op_sets=$op_sets
	ops=$ops
	domain=$domain
	machine_network=$machine_network
	dns_servers=$dns_servers
	next_hop_address=$next_hop
	ntp_servers=$ntp_servers
	pull_secret_file=~/.pull-secret.json
	editor=none
	ask=$ask
	excl_platform=false
	verify_conf=true
	EOF

    # Set version override if using shorthand
    case "$version" in
        l|latest)   export OCP_VERSION=l ;;
        p|previous) export OCP_VERSION=p ;;
    esac

    _e2e_log "  Generated aba.conf: channel=$channel version=$version platform=$platform" 2>/dev/null || true
}

# --- gen_mirror_conf --------------------------------------------------------
#
# Generate/customize mirror/mirror.conf.
#
# Options:
#   --reg-type TYPE    Registry type: quay (default), docker, existing
#   --reg-host HOST    Registry hostname (default: auto from aba)
#   --reg-port PORT    Registry port (default: 8443)
#
gen_mirror_conf() {
    local reg_type="quay"
    local reg_host=""
    local reg_port=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --reg-type) reg_type="$2"; shift 2 ;;
            --reg-host) reg_host="$2"; shift 2 ;;
            --reg-port) reg_port="$2"; shift 2 ;;
            *) echo "gen_mirror_conf: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    # Ensure mirror directory exists and has a conf
    if [ ! -d mirror ]; then
        echo "gen_mirror_conf: no mirror directory found. Run 'aba mirror' first." >&2
        return 1
    fi

    # Apply overrides via sed if mirror.conf exists
    if [ -f mirror/mirror.conf ]; then
        [ -n "$reg_host" ] && sed -i "s/^reg_host=.*/reg_host=$reg_host/" mirror/mirror.conf
        [ -n "$reg_port" ] && sed -i "s/^reg_port=.*/reg_port=$reg_port/" mirror/mirror.conf

        case "$reg_type" in
            existing)
                sed -i 's/^reg_ssh_user=.*/reg_ssh_user=/' mirror/mirror.conf
                ;;
        esac
    fi

    _e2e_log "  Configured mirror.conf: type=$reg_type host=$reg_host port=$reg_port" 2>/dev/null || true
}

# --- gen_cluster_conf -------------------------------------------------------
#
# Generate/customize a cluster's cluster.conf.
#
# Options:
#   --dir DIR             Cluster directory (default: sno)
#   --name NAME           Cluster name
#   --type TYPE           sno | compact | standard
#   --num-masters N       Number of master nodes
#   --num-workers N       Number of worker nodes
#   --starting-ip IP      Starting IP for VMs
#   --ingress-ip IP       Ingress VIP
#   --api-ip IP           API VIP
#
gen_cluster_conf() {
    local dir="sno"
    local name="" type="" masters="" workers=""
    local starting_ip="" ingress_ip="" api_ip=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)          dir="$2"; shift 2 ;;
            --name)         name="$2"; shift 2 ;;
            --type)         type="$2"; shift 2 ;;
            --num-masters)  masters="$2"; shift 2 ;;
            --num-workers)  workers="$2"; shift 2 ;;
            --starting-ip)  starting_ip="$2"; shift 2 ;;
            --ingress-ip)   ingress_ip="$2"; shift 2 ;;
            --api-ip)       api_ip="$2"; shift 2 ;;
            *) echo "gen_cluster_conf: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    if [ -f "$dir/cluster.conf" ]; then
        [ -n "$name" ]        && sed -i "s/^cluster_name=.*/cluster_name=$name/" "$dir/cluster.conf"
        [ -n "$masters" ]     && sed -i "s/^num_masters=.*/num_masters=$masters/" "$dir/cluster.conf"
        [ -n "$workers" ]     && sed -i "s/^num_workers=.*/num_workers=$workers/" "$dir/cluster.conf"
        [ -n "$starting_ip" ] && sed -i "s/^starting_ip=.*/starting_ip=$starting_ip/" "$dir/cluster.conf"
        [ -n "$ingress_ip" ]  && sed -i "s/^ingress_ip=.*/ingress_ip=$ingress_ip/" "$dir/cluster.conf"
        [ -n "$api_ip" ]      && sed -i "s/^api_ip=.*/api_ip=$api_ip/" "$dir/cluster.conf"
    fi

    _e2e_log "  Configured cluster.conf in $dir" 2>/dev/null || true
}

# --- gen_vmware_conf --------------------------------------------------------
#
# Copy the VMware config file to the aba root (for govc).
# Source: $VMWARE_CONF (default: ~/.vmware.conf)
#
gen_vmware_conf() {
    local src="${VMWARE_CONF:-$HOME/.vmware.conf}"
    local dst="${1:-vmware.conf}"

    if [ -f "$src" ]; then
        cp "$src" "$dst"
        _e2e_log "  Copied vmware.conf from $src" 2>/dev/null || true
    else
        echo "gen_vmware_conf: source file not found: $src" >&2
        return 1
    fi
}
