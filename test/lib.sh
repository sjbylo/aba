# Configuration
TARGET_CIDR="192.168.2.0/24"
PROXY_URL="http://10.0.1.8:3128"
STATE_FILE="/tmp/last_default_iface"

# Internal helper to find the default interface
_find_default_iface() {
    local iface=$(ip route show default | awk '/default/ {print $5}')
    # If found, save it for later (in case we down it)
    [ -n "$iface" ] && echo "$iface" > "$STATE_FILE"
    
    # If not found, try to read the last known one
    if [ -z "$iface" ] && [ -f "$STATE_FILE" ]; then
        iface=$(cat "$STATE_FILE")
    fi
    echo "$iface"
}

int_up() {
    local if_name=$(_find_default_iface)
    
    if [ -z "$if_name" ]; then
        echo "Error: No interface history found. Cannot bring 'up' what I don't know."
        return 1
    fi

    echo "Attempting to connect $if_name..."
    sudo nmcli device connect "$if_name" >/dev/null 2>&1
    
    # Wait for DHCP/Handshake
    sleep 2 

    local current_cidr=$(ip route show dev "$if_name" scope link | awk '{print $1}')

    if [ "$current_cidr" = "$TARGET_CIDR" ]; then
        echo "Success: On target network ($current_cidr)."
        unset http_proxy https_proxy no_proxy
    else
        echo "CIDR mismatch/No link ($current_cidr). Falling back to proxy..."
        export no_proxy=.lan,.example.com
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
    fi
}

int_down() {
    local if_name=$(_find_default_iface)
    [ -z "$if_name" ] && { echo "No active default interface found."; return 1; }

    local current_cidr=$(ip route show dev "$if_name" scope link | awk '{print $1}')

    if [ "$current_cidr" = "$TARGET_CIDR" ]; then
        echo "Target network $TARGET_CIDR detected. Downing $if_name..."
        sudo nmcli device disconnect "$if_name"
    else
        echo "Not on target network ($current_cidr). Skipping hardware down."
    fi

    unset http_proxy https_proxy no_proxy
    echo "Proxy variables cleared."
}
