# Configuration
TARGET_CIDR="192.168.2.0/24"
PROXY_URL="http://10.0.1.8:3128"

# UNIVERSAL FINDER: Identifies the non-management physical interface
_find_internet_iface() {
    # 1. Get the interface currently used for the 10.x.x.x internal network
    local internal_iface=$(ip -o addr show | grep "10\." | awk '{print $2}' | head -n 1)
    
    # 2. Find all physical interfaces, excluding loopback and the internal one
    # This works on any host because it looks at /sys/class/net
    for iface in $(ls /sys/class/net | grep -vE "lo|virbr|docker|veth"); do
        if [ "$iface" != "$internal_iface" ]; then
            # Filter out VLAN sub-interfaces (dots)
            if [[ "$iface" != *"."* ]]; then
                echo "$iface"
                return 0
            fi
        fi
    done
}

int_up() {
    local if_name=$(_find_internet_iface)
    
    if [ -z "$if_name" ]; then
        echo "Error: Could not automatically identify the internet interface."
        return 1
    fi

    echo "Auto-detected Internet Interface: $if_name"

    # Remove any device-only default route added by int_down() for pasta hairpin.
    # It has no metric so it beats the DHCP route on the internet interface.
    local _stale_dev=$(ip route show default | grep -v via | awk '{print $3}' | head -1)
    [ -n "$_stale_dev" ] && sudo ip route del default dev "$_stale_dev" scope link 2>/dev/null || true

    # Ensure the connection profile matches the device name for reliability
    # Modify the connection associated with this device
    local con_name=$(nmcli -t -f DEVICE,NAME connection show --active | grep "^${if_name}:" | cut -d: -f2)
    [ -z "$con_name" ] && con_name=$(nmcli -t -f NAME,DEVICE connection show | grep ":${if_name}$" | cut -d: -f1 | head -n 1)
    [ -z "$con_name" ] && con_name="$if_name"

    # Force strict requirements
    sudo nmcli connection modify "$con_name" \
        ipv4.method auto \
        ipv4.route-metric 50 \
        ipv4.ignore-auto-dns yes \
        ipv6.method disabled \
        connection.autoconnect yes

    echo "Connecting $con_name..."
    sudo nmcli connection up "$con_name" >/dev/null 2>&1
    
    # Wait for carrier and DHCP
    sleep 1

    # Verify CIDR on the detected interface
    local current_cidr=$(ip -o -f inet addr show "$if_name" | awk '{print $4}' | head -n 1)

    if [[ "$current_cidr" == *"192.168.2"* ]]; then
        echo "Success: $if_name is online ($current_cidr)."
        export no_proxy="localhost,127.0.0.1,.lan,.example.com"
        unset http_proxy https_proxy
    else
        echo "Interface $if_name is up but CIDR is $current_cidr. Setting fallback proxy..."
        export no_proxy="localhost,127.0.0.1,.lan,.example.com"
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
    fi
}

int_down() {
	local if_name=$(_find_internet_iface)
	if [ -n "$if_name" ]; then
		echo "Downing $if_name..."
		if ! sudo nmcli device disconnect "$if_name" 2>/dev/null; then
			echo "Interface $if_name already inactive."
		fi
	fi
	unset http_proxy https_proxy no_proxy

	# Pasta (rootless podman ≥5.x on RHEL 9) needs a default route to handle
	# hairpin connections (host connecting to its own FQDN/IP).  Without one,
	# mirror-registry's Ansible health-check gets "Connection reset by peer".
	# A device-only route suffices; pasta only checks the route exists.
	# Always replace (not conditional) -- DHCP may remove a snapshot-inherited
	# default route after we check, causing a race condition.
	local candidate_iface
	candidate_iface=$(ip -o link show up | \
		awk -F': ' '{print $2}' | cut -d@ -f1 | \
		grep -Ev '^(lo|docker|podman|cni|virbr|br-|veth|tun|tap|zt|wg|flannel|cilium|kube|ovs|vnet|vmnet|dummy|sit|ip6tnl|gre)' | \
		grep -v '\.' | \
		while read -r _iface; do
			if ip -4 addr show dev "$_iface" scope global | grep -q "inet "; then
				echo "$_iface"
				break
			fi
		done)
	if [ -n "$candidate_iface" ]; then
		sudo ip route replace default dev "$candidate_iface" \
			&& echo "Default route: dev $candidate_iface (pasta hairpin)"
	fi

	echo "Environment cleaned."
}
