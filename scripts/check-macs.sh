#!/bin/bash
# Check if mac addresses are already in use and warn if they are

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

if [ ! "$CLUSTER_NAME" ]; then
        scripts/cluster-config-check.sh
        eval "$(scripts/cluster-config.sh || exit 1)"
fi

CP_MAC_ADDR_ARRAY=($CP_MAC_ADDRS)
WKR_MAC_ADDR_ARRAY=($WKR_MAC_ADDRS)

# Prefer 'ip neigh' over 'arp'. If missing, skip this script.
command -v ip >/dev/null 2>&1 || exit 0

# Helper: get current neighbor table lines that include an lladdr (MAC)
get_neighbors() {
        # -o = one-line; filter to entries that actually contain a MAC
        ip -o neigh 2>/dev/null | grep -E ' lladdr ' || true
}

# States that we consider "active enough" to imply a *current* conflict after re-probe.
# (You can tweak this list if you want stricter/looser behavior.)
is_active_state() {
        case "$1" in
                REACHABLE|DELAY|PROBE|PERMANENT) return 0 ;;
                *) return 1 ;;
        esac
}

# Checking mac addresses that could already be in use (in neighbor cache) ...
all_neighbors="$(get_neighbors)"

IN_ARP_CACHE=
list_of_matching_entries=()   # array of MACs seen in neighbor cache

for mac in $CP_MAC_ADDRS $WKR_MAC_ADDRS
do
        # checking mac address: $mac ...
        if echo "$all_neighbors" | grep -qi " lladdr $mac\b"; then
                # State-aware warning: show states we saw for this MAC (STALE/REACHABLE/etc.)
                states="$(echo "$all_neighbors" | grep -i " lladdr $mac\b" | awk '{print $NF}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
                aba_warning "Mac address $mac might already be in use (found in system neighbor cache) [states: ${states:-unknown}]."
                IN_ARP_CACHE=1
                list_of_matching_entries+=("$mac")
        fi
done

# Checking ip and mac addresses *currently* in use by clearing the cache ...
mac_list_filtered=()  # array of neighbor lines that match any of the MACs

if ((${#list_of_matching_entries[@]} > 0)); then
        # Build a filtered list of neighbor entries that match any of the MACs
        for mac in "${list_of_matching_entries[@]}"
        do
                # Collect all neighbor lines matching this MAC (if any)
                while IFS= read -r line; do
                        [ -z "$line" ] && continue
                        mac_list_filtered+=("$line")
                done < <(echo "$all_neighbors" | grep -i " lladdr $mac\b" || true)
        done

        # Extract unique IPs from the filtered neighbor entries (first field)
        ips=()
        if ((${#mac_list_filtered[@]} > 0)); then
                mapfile -t ips < <(printf '%s\n' "${mac_list_filtered[@]}" | awk '{print $1}' | sort -u)
        fi

        if ((${#ips[@]} > 0)); then
                # Delete neighbor entries for these IPs, then re-learn via ping
                for ipaddr in "${ips[@]}"; do
                        [ -z "$ipaddr" ] && continue
                        $SUDO ip neigh flush to "$ipaddr" >/dev/null 2>&1 || true
                done

                for ipaddr in "${ips[@]}"
                do
                        ping -c2 "$ipaddr" >/dev/null 2>&1 &
                done
                wait

                sleep 2

                all_neighbors="$(get_neighbors)"
                P=()
                MAC_IN_USE=

                for mac in $CP_MAC_ADDRS $WKR_MAC_ADDRS
                do
                        # checking $mac ...
                        # Re-check after re-probe, but only count "active" states as truly in-use
                        mapfile -t re_matches < <(echo "$all_neighbors" | grep -i " lladdr $mac\b" || true)

                        if ((${#re_matches[@]} > 0)); then
                                active_hit=
                                while IFS= read -r st; do
                                        is_active_state "$st" && { active_hit=1; break; }
                                done < <(printf '%s\n' "${re_matches[@]}" | awk '{print $NF}')

                                if [ "$active_hit" ]; then
                                        P+=("$mac")
                                        MAC_IN_USE=1
                                fi
                        fi
                done

                if [ "$MAC_IN_USE" ]; then
                        aba_abort \
                                "One or more mac addresses are *currently in use*: ${P[*]}" \
                                "Consider Changing 'mac_prefix' in cluster.conf and try again." \
                                "If you're running multiple OpenShift clusters, ensure no mac/ip addresses overlap!"
                fi
        fi
fi

if [ "$IN_ARP_CACHE" ]; then
        aba_warning \
                "Mac address conflicts may cause the OpenShift installation to fail!" \
                "Consider changing 'mac_prefix' in cluster.conf and try again." \
                "After clearing the neighbor cache & pinging IPs, no more mac address conflicts detected!"
fi

echo
exit 0
