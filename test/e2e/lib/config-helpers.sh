#!/bin/bash
# =============================================================================
# E2E Test Framework -- Configuration Helpers
# =============================================================================
# Functions to programmatically generate aba.conf, mirror.conf, cluster.conf,
# and vmware.conf for test suites.
# =============================================================================

_E2E_LIB_DIR_CH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- gen_aba_conf -----------------------------------------------------------
#
# Generate a test aba.conf in the current directory (must be aba root).
# Uses environment variables from config.env / CLI / pool overrides.
#
# Options:
#   --channel CHANNEL      Override channel (default: $TEST_CHANNEL)
#   --version VERSION      Override version (default: $VER_OVERRIDE)
#   --platform PLATFORM    Override platform (default: vmw)
#   --op-sets OPSETS       Set operator sets (default: empty)
#   --ops OPS              Set individual operators (default: empty)
#   --ask true|false       Set ask mode (default: false for testing)
#
gen_aba_conf() {
    local channel="${TEST_CHANNEL:-stable}"
    local version="${VER_OVERRIDE:-l}"
    local platform="vmw"
    local op_sets=""
    local ops=""
    local ask="false"
    local ntp_servers="${NTP_SERVERS:-10.0.1.8,2.rhel.pool.ntp.org}"
    local domain="${DOMAIN:-example.com}"
    local machine_network="${MACHINE_NETWORK:-10.0.0.0/20}"
    local dns_servers="${DNS_SERVERS:-10.0.1.8}"
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
        l|latest)   export VER_OVERRIDE=l ;;
        p|previous) export VER_OVERRIDE=p ;;
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
