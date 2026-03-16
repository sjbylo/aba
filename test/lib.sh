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
    [ -n "$if_name" ] && {
        # Only disconnect if NetworkManager considers the device active
        local state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | grep "^${if_name}:" | cut -d: -f2)
        if [[ "$state" == "connected" || "$state" == "connecting"* ]]; then
            echo "Downing $if_name..."
            sudo nmcli device disconnect "$if_name"
        else
            echo "Interface $if_name already inactive (state=$state), skipping disconnect."
        fi
    }
    unset http_proxy https_proxy no_proxy
    echo "Environment cleaned."
}
