#!/bin/bash
# =============================================================================
# Show DNS records served by E2E test bastions
# =============================================================================
# Each connected bastion (conN) runs dnsmasq to serve cluster DNS for its pool.
# This is set up automatically by _vm_setup_dnsmasq in pool-lifecycle.sh.
#
# This script is informational only -- it shows what each bastion will serve.
# No manual DNS server changes are needed.
#
# Usage: ./dns-records.sh [NUM_POOLS]
# Default: 4 pools
# =============================================================================

cd "$(dirname "$0")" || exit 1
source config.env 2>/dev/null || true

NUM_POOLS="${1:-4}"

echo "# ========================================================================="
echo "# DNS records auto-configured on each connected bastion (conN)"
echo "#"
echo "# Each conN runs dnsmasq serving its pool's cluster records."
echo "# Non-cluster queries are forwarded to upstream: ${DNS_UPSTREAM:-10.0.1.8}"
echo "# No manual DNS setup required -- this is fully automated."
echo "# ========================================================================="

for p in $(seq 1 "$NUM_POOLS"); do
    base=$((p * 10))
    con_ip="${POOL_SUBNET:-10.0.2}.${base}"
    local_domain="${POOL_DOMAIN[$p]:-p${p}.example.com}"
    local_node="${POOL_NODE_IP[$p]:-${POOL_SUBNET:-10.0.2}.$((base + 2))}"
    local_api="${POOL_API_VIP[$p]:-${POOL_SUBNET:-10.0.2}.$((base + 3))}"
    local_apps="${POOL_APPS_VIP[$p]:-${POOL_SUBNET:-10.0.2}.$((base + 4))}"

    echo ""
    echo "# === Pool $p: con${p} (${con_ip}) serves DNS for ${local_domain} ==="
    echo "#     Cluster nodes use dns_servers=${con_ip} in aba.conf"
    echo "#"
    echo "#  SNO (api + apps -> node IP):"
    echo "address=/api.sno.${local_domain}/${local_node}"
    echo "address=/.apps.sno.${local_domain}/${local_node}"
    echo "#  Compact/Standard (api -> API VIP, apps -> APPS VIP):"
    for ctype in compact standard; do
        echo "address=/api.${ctype}.${local_domain}/${local_api}"
        echo "address=/.apps.${ctype}.${local_domain}/${local_apps}"
    done
    echo "#  Upstream forwarding: server=${DNS_UPSTREAM:-10.0.1.8}"
done

echo ""
echo "# --- Summary ---"
echo "# Pool layout in ${POOL_SUBNET:-10.0.2}.0/24 (one cluster at a time per pool):"
for p in $(seq 1 "$NUM_POOLS"); do
    base=$((p * 10))
    echo "#   Pool $p: .${base}=con${p}(dns)  .$((base+1))=dis${p}  .$((base+2))=node  .$((base+3))=api-vip  .$((base+4))=apps-vip"
done
